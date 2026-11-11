#!/usr/bin/env python3
"""Private POSIX tmux lifecycle owner. Python stdlib only; never imports agents.

The short-lived manager takes one JSON request on stdin. The pane owner runs
independently of Emacs, owns one foreground process group, and authenticates
inspect/finish over a private Unix socket. Credentials are not tmux arguments.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import uuid
import select
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

LIMIT = 1024 * 1024
TERMINAL = {"finished", "exited", "failed"}


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")


def private_dir(path, create=False):
    if create:
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("Runtime directories must be owned by you, non-symlink and mode 0700")


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe runtime file permissions")
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError("Runtime record too large")
    return json.loads(data)


def write_json(path, value):
    data = encode(value)
    if len(data) > LIMIT:
        raise ValueError("Runtime record too large")
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextlib.contextmanager
def lock(path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe lock file")
        deadline = time.monotonic() + 6
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("Runtime operation already in progress")
                time.sleep(0.03)
        yield
    finally:
        os.close(fd)


def alive(pid, group=False):
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        (os.killpg if group else os.kill)(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def native_json(path):
    """Read bounded native-provider data, never executing or rewriting it."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                return None, None
            data = stream.read(LIMIT + 1)
        if len(data) > LIMIT:
            return None, None
        return json.loads(data), (info.st_dev, info.st_ino, hashlib.sha256(data).hexdigest())
    except (OSError, ValueError, RecursionError):
        return None, None


def native_id(value, is_uuid=False):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,199}", value):
        return None
    if value in {"latest", "last", "default", "recent"}:
        return None
    if is_uuid:
        if not re.fullmatch(r"[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}", value):
            return None
        try:
            uuid.UUID(value)
        except ValueError:
            return None
    return value


def hermes_entries(home, pid):
    data, _ = native_json(home / "runtime" / "active_sessions.json")
    entries = data.get("entries", []) if isinstance(data, dict) else []
    return [entry for entry in entries if isinstance(entry, dict) and type(entry.get("pid")) is int
            and entry["pid"] == pid and entry.get("surface") == "cli"] if isinstance(entries, list) else []


def identity_baseline(kind, home, pid, tty):
    """Capture stale native data while the freshly forked child is still gated."""
    if kind == "claude":
        return dict(record=native_json(home / "sessions" / (str(pid) + ".json"))[1])
    if kind == "hermes":
        terminal = "tty-" + re.sub(r"[^A-Za-z0-9._-]", "-", tty.strip().strip("/"))[:120]
        path = home / "terminal-sessions" / terminal
        return dict(entries=hermes_entries(home, pid), breadcrumb=native_json(path)[1], path=path)
    return {}


def probe_command(argv, deadline, limit=262144):
    """Bound OS-query output/time; a killed query is NOT a killed backend."""
    if time.monotonic() >= deadline:
        return None
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    data = bytearray()
    try:
        while time.monotonic() < deadline:
            if select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                block = os.read(process.stdout.fileno(), min(65536, limit + 1 - len(data)))
                if not block:
                    process.wait(timeout=max(.01, deadline - time.monotonic()))
                    return data.decode("utf-8", "replace") if process.returncode in (0, 1) else None
                data.extend(block)
                if len(data) > limit:
                    return None
        return None
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        process.stdout.close()


def writable_files(pid, deadline):
    """Return writable descriptor targets, or None when coverage is unknown."""
    proc = Path("/proc") / str(pid)
    if (proc / "fd").is_dir():
        paths = []
        try:
            for fd in (proc / "fd").iterdir():
                if time.monotonic() >= deadline:
                    return None
                try:
                    flags = (proc / "fdinfo" / fd.name).read_text()[:4096]
                    match = re.search(r"^flags:\s*([0-7]+)", flags, re.M)
                    if match and int(match[1], 8) & os.O_ACCMODE in (os.O_WRONLY, os.O_RDWR):
                        filename = os.readlink(fd)
                        info = fd.stat()
                        paths.append((filename, info.st_dev, info.st_ino))
                except FileNotFoundError:
                    continue
            return paths
        except OSError:
            return None
    lsof = shutil.which("lsof") or ("/usr/sbin/lsof" if os.access("/usr/sbin/lsof", os.X_OK) else None)
    if not lsof:
        return None
    text = probe_command([lsof, "-nP", "-a", "-p", str(pid), "-FfaniD"], deadline)
    if text is None:
        return None
    paths, fields = [], {}
    def collect():
        filename = fields.get("n", "")
        if (fields.get("f", "").isdigit() and fields.get("a") in ("w", "u")
                and filename.endswith(".jsonl") and os.path.basename(filename).startswith("rollout-")):
            if "D" not in fields or "i" not in fields:
                raise ValueError("Descriptor identity unavailable")
            paths.append((fields["n"], int(fields["D"], 0), int(fields["i"])))
    try:
        for line in text.splitlines():
            if line.startswith("f"):
                collect()
                fields = {}
            if line and line[0] in "faniD":
                fields[line[0]] = line[1:]
        collect()
        return paths
    except ValueError:
        return None


def executable_name(pid, deadline):
    try:
        return os.path.basename(os.readlink("/proc/%d/exe" % pid))
    except OSError:
        text = probe_command(["/bin/ps", "-p", str(pid), "-o", "comm="], deadline, 16384)
        return os.path.basename(text.strip()) if text else None


def codex_writer_id(pid, home, deadline):
    paths = writable_files(pid, deadline)
    if paths is None:
        return None, "pending"
    ids = set()
    for filename, device, inode in paths:
        if not filename.endswith(".jsonl") or not os.path.basename(filename).startswith("rollout-"):
            continue
        path = Path(os.path.realpath(filename))
        if not path.is_relative_to(home / "sessions"):
            continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or (info.st_dev, info.st_ino) != (device, inode)):
                    return None, "ambiguous"
                line = stream.readline(LIMIT + 1)
            if len(line) > LIMIT:
                return None, "ambiguous"
            data = json.loads(line)
            value = native_id(data.get("payload", {}).get("id"), True) if isinstance(data, dict) and data.get("type") == "session_meta" else None
            if not value or not path.name.endswith("-" + value + ".jsonl"):
                return None, "ambiguous"
            ids.add(value)
        except (OSError, ValueError, AttributeError, RecursionError):
            return None, "ambiguous"
    return (next(iter(ids)), "verified") if len(ids) == 1 else (None, "ambiguous" if ids else "empty")


def codex_identity(pid, home, program):
    if not (home / "sessions").is_dir():
        return None, "pending"
    deadline = time.monotonic() + .6
    value, certainty = codex_writer_id(pid, home, deadline)
    if certainty != "empty":
        return value, certainty
    # Only follow the documented npm launcher topology, never arbitrary tool
    # descendants/subagents. Native binaries are inspected directly above.
    if not os.path.realpath(program).endswith("/@openai/codex/bin/codex.js"):
        return None, "pending"
    if executable_name(pid, deadline) not in {"node", "nodejs", "bun"}:
        return None, "pending"
    children_path = Path("/proc/%d/task/%d/children" % (pid, pid))
    try:
        children = [int(value) for value in children_path.read_text()[:4096].split()]
    except OSError:
        text = probe_command(["/bin/ps", "-axo", "pid=,ppid=,pgid="], deadline)
        if text is None:
            return None, "pending"
        children = [int(fields[0]) for line in text.splitlines() if len(fields := line.split()) == 3
                    and fields[1] == str(pid) and fields[2] == str(pid)]
    if len(children) != 1:
        return None, "ambiguous" if children else "pending"
    child = children[0]
    try:
        if os.getpgid(child) != pid or executable_name(child, deadline) != "codex":
            return None, "pending"
    except OSError:
        return None, "pending"
    return codex_writer_id(child, home, deadline)


def discover_identity(kind, home, pid, baseline, program):
    """Native data supplies IDs; owned child/descriptor evidence supplies scope."""
    if kind == "claude":
        data, signature = native_json(home / "sessions" / (str(pid) + ".json"))
        if signature == baseline.get("record") or not isinstance(data, dict) or type(data.get("pid")) is not int or data.get("pid") != pid:
            return None, "pending"
        value = native_id(data.get("sessionId"), True)
        return value, "verified" if value else "pending"
    if kind == "hermes":
        entries = hermes_entries(home, pid)
        if not entries or entries == baseline.get("entries"):
            return None, "pending"
        if len(entries) != 1:
            return None, "ambiguous"
        value = native_id((entries[0].get("metadata") or {}).get("live_session_id") or entries[0].get("session_id"))
        data, signature = native_json(baseline["path"])
        crumb = native_id(data.get("session_id")) if isinstance(data, dict) else None
        if not value or not crumb or signature == baseline.get("breadcrumb"):
            return None, "pending"
        return (value, "verified") if value == crumb else (None, "ambiguous")
    if kind == "codex":
        return codex_identity(pid, home, program)
    return None, "pending"


def public(state):
    result = {key: value for key, value in state.items()
              if key not in {"token", "configuration", "diagnostic", "lease"}}
    lease = state.get("lease", {})
    result["controllerPid"] = lease.get("pid") if alive(lease.get("pid")) else None
    return result


def tmux_call(tmux, root, *args, missing=False):
    result = subprocess.run([tmux, "-S", str(root / "tmux.sock"), "-f", "/dev/null", *args],
                            stdin=subprocess.DEVNULL, capture_output=True, timeout=4)
    if missing and b"server exited unexpectedly" in result.stderr.lower():
        # A read-only query can race the last pane/server exiting. Only the
        # subsequent positive absence result is allowed to authorize recovery.
        result = subprocess.run([tmux, "-S", str(root / "tmux.sock"), "-f", "/dev/null", *args],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=4)
    text = result.stdout.decode("utf-8", "replace").strip()
    if result.returncode:
        error = result.stderr.decode("utf-8", "replace")
        # Only positively identified absence permits history recovery.
        if missing and any(reason in error.lower() for reason in
                           ("no server running", "no sessions", "no such file or directory", "can't find session", "connection refused")):
            return None
        raise ValueError("tmux operation failed: " + error.strip()[:300])
    return text


def session_exists(tmux, root, name):
    # An exact inventory avoids tmux target resolution during teardown:
    # has-session can report 'no current target' while the last client exits.
    names = tmux_call(tmux, root, "list-sessions", "-F", "#{session_name}", missing=True)
    return names is not None and name in names.splitlines()


def pane(tmux, root, state):
    if not session_exists(tmux, root, state["name"]):
        return None
    try:
        value = tmux_call(tmux, root, "display-message", "-p", "-t", "=" + state["name"] + ":",
                          "#{session_name}\t#{@ashub-generation}\t#{@ashub-owner}\t#{pane_pid}",
                          missing=True)
    except ValueError:
        if not session_exists(tmux, root, state["name"]):
            return None
        raise
    if value is None:
        return None
    fields = value.split("\t")
    if len(fields) != 4 or fields[:3] != [state["name"], state["generation"], state["token"]]:
        # display-message may silently use an empty/default context if its
        # target exited between these two tmux commands. Re-prove absence.
        if not session_exists(tmux, root, state["name"]):
            return None
        raise ValueError("tmux instance ownership is unknown; refusing to attach or finish")
    if int(fields[3]) != state.get("ownerPid"):
        raise ValueError("tmux pane owner changed; refusing to attach or finish")
    return fields


def ipc(directory, state, operation, fields=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(1)
        client.connect(str(directory / "ctl.sock"))
        request = dict(fields or {}, token=state["token"], generation=state["generation"], operation=operation)
        client.sendall(encode(request) + b"\n")
        data = b""
        while b"\n" not in data:
            block = client.recv(65536)
            if not block:
                raise ValueError("Owner disconnected; command outcome is unknown")
            data += block
            if len(data) > LIMIT:
                raise ValueError("Oversized owner response")
        reply = json.loads(data.split(b"\n", 1)[0])
        if reply.get("generation") != state["generation"]:
            raise ValueError("Runtime owner did not authenticate the requested generation")
        if reply.get("error"):
            raise ValueError(reply["error"])
        return reply


def inspect(root, tmux, directory):
    private_dir(directory)
    state = read_json(directory / "state.json")
    if state["status"] == "starting":
        return dict(public(state), status="unknown")
    owned_pane = pane(tmux, root, state)
    if owned_pane is not None:
        try:
            return ipc(directory, state, "inspect")
        except (OSError, ValueError):
            return dict(public(state), status="unknown")
    identities_gone = not any((alive(state.get("ownerPid")), alive(state.get("childPid")),
                               alive(state.get("childPid"), group=True)))
    if identities_gone:
        # The last owner may have committed its exit between our initial read
        # and tmux query. Re-read only after it can no longer write this record.
        latest = read_json(directory / "state.json")
        if latest["generation"] != state["generation"]:
            return dict(public(latest), status="unknown")
        state = latest
        if state["status"] in TERMINAL:
            return public(state)
        if state["status"] in {"unknown", "running", "stopping"} and state.get("ownerPid") and state.get("childPid"):
            return dict(public(state), status="exited", reason="owner-lost-history-only")
    return dict(public(state), status="unknown")


def source_identity(source):
    if source.get("agent") not in ("claude", "codex", "hermes"):
        raise ValueError("Unsupported terminal agent")
    root = source.get("root")
    if not isinstance(root, str) or not os.path.isabs(root):
        raise ValueError("Source root must be absolute")
    profile = source.get("profile")
    if profile is not None and not isinstance(profile, str):
        raise ValueError("Source profile must be a string or null")
    return dict(agent=source["agent"], root=os.path.realpath(root), profile=profile)


def state_paths(root):
    return sorted(root.glob("i-*/state.json")) if root.exists() else []


def ensure(root, tmux, request):
    source = source_identity(request["source"])
    session_id = request.get("sessionId")
    restoring = session_id is not None
    if session_id is not None and (not isinstance(session_id, str) or not session_id or session_id.startswith("-")):
        raise ValueError("Invalid exact history ID")
    directory = os.path.realpath(request["directory"])
    if not os.path.isdir(directory):
        raise ValueError("Selected project directory does not exist")
    program, args, environment = request["program"], request["args"], request["environment"]
    if not isinstance(program, str) or not os.path.isabs(program) or not os.access(program, os.X_OK):
        raise ValueError("Agent executable unavailable")
    if not isinstance(args, list) or not all(isinstance(arg, str) and "\0" not in arg for arg in args):
        raise ValueError("Arguments must be literal strings")
    adapter = source["agent"]
    preallocated = adapter == "claude" and os.path.basename(program) == "claude" and not restoring
    if preallocated:
        if any(arg.split("=", 1)[0] in {"--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"} for arg in args):
            raise ValueError("Fresh Claude lifecycle arguments are managed by ashub")
        session_id = str(uuid.uuid4())
        args = [*args, "--session-id", session_id]
    if adapter == "hermes" and any(arg.split("=", 1)[0] == "--profile" or (arg.startswith("-p") and not arg.startswith("--")) for arg in args):
        raise ValueError("Use an explicit HERMES_HOME source, not a CLI --profile redirect")
    if not isinstance(environment, dict) or not all(
            isinstance(key, str) and key and "=" not in key and "\0" not in key
            and isinstance(value, str) and "\0" not in value for key, value in environment.items()):
        raise ValueError("Environment must be a string map")
    home_variable = {"claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME", "hermes": "HERMES_HOME"}[source["agent"]]
    environment[home_variable] = source["root"]  # Storage identity is authoritative, not inherited shell state.
    configuration = hashlib.sha256(encode([program, request.get("sourceArgs", []),
                                           request.get("sourceEnvironment", [])])).hexdigest()
    private_dir(root, create=True)
    # ponytail: one launch lock per private server; split only if real contention warrants it.
    with lock(root / "launch.lock"):
        matches = []
        for path in state_paths(root):
            state = read_json(path)
            same_storage = (state["source"]["agent"] == source["agent"] and state["source"]["root"] == source["root"])
            if same_storage and restoring:
                # Native ID may have become known (or changed) since metadata
                # was written. Probe the authenticated owner before deciding.
                state = inspect(root, tmux, path.parent)
                if state["status"] == "unknown":
                    raise ValueError("Terminal ownership is unknown for this storage home; refusing history restore")
            if same_storage and restoring and state["status"] not in TERMINAL:
                if state.get("sessionId") != session_id and (state.get("identityOverflow") or session_id in state.get("previousSessionIds", [])):
                    raise ValueError("History is reserved by an earlier conversation of a live instance; attach its runtime row or finish it first")
            if same_storage and session_id and state.get("sessionId") == session_id:
                if state["source"] == source:
                    matches.append(path)
                elif inspect(root, tmux, path.parent)["status"] not in TERMINAL:
                    raise ValueError("History already owned by another profile sharing this storage home")
            elif same_storage and not state.get("sessionId") and restoring:
                current = inspect(root, tmux, path.parent)
                if current["status"] not in TERMINAL:
                    raise ValueError("Unindexed live terminal for this source: attach/finish it before restoring history")
        if len(matches) > 1:
            raise ValueError("Multiple owners claim this exact history; refusing duplicate writers")
        # Instance identity is opaque: a native /new or /resume can change the
        # conversation without changing this owner. Do not hash a mutable ID.
        runtime_id = matches[0].parent.name[2:] if matches else secrets.token_hex(12)
        instance = root / ("i-" + runtime_id)
        private_dir(instance, create=True)
        if len(os.fsencode(str(instance / "ctl.sock"))) >= 100:
            raise ValueError("Runtime path too long for Unix sockets; use a shorter private directory")
        record = instance / "state.json"
        if record.exists():
            old = read_json(record)
            deadline = time.monotonic() + 5
            while old["status"] == "starting" and time.monotonic() < deadline:
                time.sleep(0.04)
                old = read_json(record)
            current = inspect(root, tmux, instance)
            if current["status"] not in TERMINAL:
                if old["configuration"] != configuration:
                    raise ValueError("Active source configuration changed; not starting another writer")
                if current["status"] == "unknown":
                    raise ValueError("Existing owner unavailable; not starting another writer")
                return current
            control = instance / "ctl.sock"
            try:
                info = control.lstat()
            except FileNotFoundError:
                pass
            else:
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise ValueError("Unsafe stale control socket; refusing to replace it")
                control.unlink()  # Only after tmux and BOTH recorded processes/groups are absent.
        state = dict(version=1, runtimeId=runtime_id, name="ashub-" + runtime_id,
                     generation=secrets.token_hex(16), token=secrets.token_hex(32),
                     source=source, sessionId=session_id, requestedSessionId=session_id, directory=directory,
                     identityKind="preallocated" if preallocated else ("requested-id" if session_id else "pending"),
                     identityVerified=False,
                     configuration=configuration, status="starting", createdAt=time.time(),
                     ownerPid=None, childPid=None)
        if record.exists():
            previous = current
            state["previousExit"] = {key: previous[key] for key in
                                     ("generation", "status", "reason", "exitCode", "endedAt") if key in previous}
        if session_exists(tmux, root, state["name"]):
            raise ValueError("Unregistered tmux owner exists; refusing to adopt or overwrite it")
        write_json(record, state)
        launch = instance / "launch.json"
        write_json(launch, dict(state=state, program=program, args=args,
                               environment=environment, tmux=tmux, identityAdapter=adapter))
        try:
            tmux_call(tmux, root, "new-session", "-d", "-s", state["name"], "-c", directory,
                      "--", sys.executable, "-I", "-B", str(Path(__file__).resolve()), "run", str(launch))
        except Exception:
            # Do not declare failure/absence: tmux may have accepted the command.
            if launch.exists():
                launch.unlink()
            raise
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            current = read_json(record)
            if current["status"] != "starting":
                return public(current)
            time.sleep(0.03)
        raise ValueError("Launch outcome unknown; inspect before retrying")


def finish(root, tmux, directory, generation):
    state = read_json(directory / "state.json")
    if generation != state["generation"]:
        raise ValueError("Generation changed; refusing to finish another instance")
    current = inspect(root, tmux, directory)
    if current["status"] in TERMINAL:
        return current
    if current["status"] == "unknown":
        raise ValueError("Owner identity unknown; refusing to signal recorded PIDs")
    ipc(directory, state, "finish")
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        current = read_json(directory / "state.json")
        if current["generation"] != state["generation"]:
            raise ValueError("Generation changed while finishing")
        if current["status"] in TERMINAL and pane(tmux, root, current) is None:
            return public(current)
        time.sleep(0.04)
    raise ValueError("Finish still pending; UI must stay open. No automatic SIGKILL was sent")


def run_owner(launch):
    private_dir(launch.parent)
    packet = read_json(launch)
    launch.unlink()  # Full inherited environment never stays in a durable registry.
    state, tmux = packet["state"], packet["tmux"]
    directory, root = launch.parent, launch.parent.parent
    record = directory / "state.json"
    control = directory / "ctl.sock"
    state["ownerPid"] = os.getpid()
    child = None
    with lock(directory / "owner.lock"), socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        try:
            pid = tmux_call(tmux, root, "display-message", "-p", "-t", "=" + state["name"] + ":", "#{pane_pid}")
            if int(pid) != os.getpid():
                raise ValueError("Pane process identity mismatch")
            tmux_call(tmux, root, "set-option", "-t", state["name"], "@ashub-owner", state["token"])
            tmux_call(tmux, root, "set-option", "-t", state["name"], "@ashub-generation", state["generation"])
            tmux_call(tmux, root, "set-option", "-t", state["name"], "destroy-unattached", "off")
            tmux_call(tmux, root, "set-window-option", "-t", "=" + state["name"] + ":", "remain-on-exit", "off")
            server.bind(str(control))
            os.chmod(control, 0o600)
            server.listen(8)
            environment = packet["environment"]
            for name in ("TERM", "TMUX", "TMUX_PANE", "COLUMNS", "LINES"):
                if name in os.environ:
                    environment[name] = os.environ[name]
                else:
                    environment.pop(name, None)
            # The CLI, not this owner, must own the foreground tty for Ctrl-C,
            # raw input and SIGWINCH. Keep its process group distinct from ours.
            signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            read_fd, write_fd = os.pipe()
            gate_read, gate_write = os.pipe()
            write_json(record, state)
            child = os.fork()
            if child == 0:
                os.close(read_fd)
                os.close(gate_write)
                try:
                    os.setpgid(0, 0)
                    os.read(gate_read, 1)
                    os.close(gate_read)
                    for number in (signal.SIGTTOU, signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
                        signal.signal(number, signal.SIG_DFL)
                    os.execvpe(packet["program"], [packet["program"], *packet["args"]], environment)
                except BaseException as error:
                    diagnostic = "Agent exec failed: %s errno=%s" % (type(error).__name__, getattr(error, "errno", None))
                    os.write(write_fd, diagnostic.encode("ascii"))
                    os._exit(127)
            os.close(write_fd)
            os.close(gate_read)
            state["childPid"] = child
            write_json(record, state)
            try:
                os.setpgid(child, child)
            except PermissionError:
                pass  # Child already exec'd after setting its own group.
            os.tcsetpgrp(0, child)
            adapter = packet.get("identityAdapter")
            home = Path(state["source"]["root"])
            baseline = identity_baseline(adapter, home, child, os.ttyname(0)) if adapter else {}
            os.write(gate_write, b"1")
            os.close(gate_write)
            error = os.read(read_fd, 1024)
            os.close(read_fd)
            if error:
                raise ValueError(error.decode())
            state.update(childPid=child, status="running")
            write_json(record, state)
            requested, reaped = [False], False
            identity_seen, next_identity, last_identity = False, 0.0, 0.0

            def refresh_identity():
                nonlocal identity_seen, next_identity, last_identity
                if not adapter or reaped:
                    return
                if time.monotonic() < last_identity + .1:
                    return  # Coalesce immediately adjacent periodic/inspect probes.
                try:
                    value, certainty = discover_identity(adapter, home, child, baseline, packet["program"])
                except Exception:
                    value, certainty = None, "pending"  # Optional discovery must never kill a backend.
                last_identity = time.monotonic()
                before = (state.get("sessionId"), state.get("identityKind"), state.get("identityVerified"))
                if value and certainty == "verified":
                    state.update(sessionId=value, identityKind=adapter + "-native", identityVerified=True)
                    identity_seen = True
                elif identity_seen or certainty == "ambiguous":
                    state.update(sessionId=None, identityKind="uncertain", identityVerified=False)
                if before != (state.get("sessionId"), state.get("identityKind"), state.get("identityVerified")):
                    previous = before[0]
                    if previous and previous != state.get("sessionId"):
                        aliases = state.setdefault("previousSessionIds", [])
                        if previous not in aliases:
                            if len(aliases) < 32:
                                aliases.append(previous)
                            else:
                                state["identityOverflow"] = True
                    write_json(record, state)
                next_identity = last_identity + (5 if identity_seen else 1)

            def stop(_number=None, _frame=None):
                requested[0] = True
                state.update(status="stopping", reason="explicit-finish")
                write_json(record, state)
                if alive(child, group=True):
                    try:
                        os.killpg(child, signal.SIGTERM)
                    except ProcessLookupError:
                        pass

            signal.signal(signal.SIGHUP, stop)
            signal.signal(signal.SIGTERM, stop)
            while True:
                if not reaped:
                    result, status = os.waitpid(child, os.WNOHANG)
                    if result:
                        reaped = True
                        state["exitCode"] = os.waitstatus_to_exitcode(status)
                        # Release any background children in our exclusively owned group.
                        if alive(child, group=True):
                            if not requested[0]:
                                state.update(status="stopping", reason="natural-exit-cleanup")
                                write_json(record, state)
                            os.killpg(child, signal.SIGTERM)
                if reaped and not alive(child, group=True):
                    state.update(status="finished" if requested[0] else "exited",
                                 reason="explicit-finish" if requested[0] else "natural-exit", endedAt=time.time())
                    write_json(record, state)
                    break
                if not reaped and time.monotonic() >= next_identity:
                    refresh_identity()
                if not select.select([server], [], [], 0.04)[0]:
                    continue
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(0.15)
                    data = b""
                    try:
                        while b"\n" not in data and len(data) <= 65536:
                            block = connection.recv(4096)
                            if not block:
                                break
                            data += block
                        request = json.loads(data.split(b"\n", 1)[0])
                        if (request.get("generation") != state["generation"] or
                                not secrets.compare_digest(str(request.get("token", "")), state["token"])):
                            continue
                        operation = request.get("operation")
                        if operation == "inspect":
                            refresh_identity()
                        error = None
                        if operation == "finish":
                            stop()
                        elif operation in {"claim", "release"}:
                            pid, nonce = request.get("clientPid"), request.get("clientNonce")
                            lease = state.get("lease", {})
                            same = lease == dict(pid=pid, nonce=nonce)
                            if not isinstance(pid, int) or pid <= 1 or not isinstance(nonce, str) or not re.fullmatch(r"[a-f0-9]{32}", nonce):
                                error = "Invalid controller lease"
                            elif operation == "release":
                                if same:
                                    state.pop("lease", None)
                                    write_json(record, state)
                            elif not alive(pid):
                                error = "Controller is no longer alive"
                            elif not same and alive(lease.get("pid")):
                                error = "Terminal controller already attached in another buffer/Emacs"
                            elif tmux_call(tmux, root, "display-message", "-p", "-t", "=" + state["name"] + ":", "#{session_attached}") != "0":
                                error = "Terminal still has an attached client; detach it before reconnecting"
                            else:
                                state["lease"] = dict(pid=pid, nonce=nonce)
                                write_json(record, state)
                        elif operation != "inspect":
                            continue
                        reply = public(state)
                        if operation == "inspect":
                            reply["attachedClients"] = int(tmux_call(tmux, root, "display-message", "-p", "-t",
                                                                    "=" + state["name"] + ":", "#{session_attached}"))
                        if error:
                            reply["error"] = error
                        connection.sendall(encode(reply) + b"\n")
                    except (OSError, ValueError):
                        pass
        except BaseException as error:
            state["diagnostic"] = str(error)[:300]
            state["errorType"] = type(error).__name__
            # An owner failure with a possibly live child stays UNKNOWN, never
            # a restart invitation. Do not kill anything from stale registry PIDs.
            state.update(status="unknown" if child else "failed", reason="owner-error")
            write_json(record, state)
        finally:
            if control.exists():
                control.unlink()


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "run":
        run_owner(Path(sys.argv[2]))
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("ensure", "inspect", "list", "finish", "claim", "release"))
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--tmux", required=True)
    options = parser.parse_args()
    if os.name != "posix":
        raise ValueError("Persistent terminal ownership currently requires POSIX")
    root = Path(os.path.abspath(options.runtime_root))
    data = sys.stdin.buffer.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError("Request too large")
    request = json.loads(data or b"{}")
    if options.operation == "ensure":
        result = ensure(root, options.tmux, request)
    elif not root.exists():
        result = [] if options.operation == "list" else {"status": "absent"}
    else:
        private_dir(root)
        if options.operation == "list":
            source = source_identity(request["source"]) if request.get("source") else None
            result = [inspect(root, options.tmux, path.parent) for path in state_paths(root)
                      if source is None or read_json(path)["source"] == source]
        else:
            runtime_id = request["runtimeId"]
            if not isinstance(runtime_id, str) or not re.fullmatch(r"[a-f0-9]{24}", runtime_id):
                raise ValueError("Invalid runtime identity")
            directory = root / ("i-" + runtime_id)
            if not directory.exists():
                result = {"status": "absent"}
            elif options.operation == "finish":
                result = finish(root, options.tmux, directory, request.get("generation"))
            elif options.operation in {"claim", "release"}:
                state = read_json(directory / "state.json")
                if request.get("generation") != state["generation"]:
                    raise ValueError("Controller generation changed; refresh before attaching")
                current = inspect(root, options.tmux, directory)
                if current["status"] not in {"running", "stopping"}:
                    if options.operation == "release":
                        result = current
                    else:
                        raise ValueError("Cannot claim a terminal with unknown/absent ownership")
                else:
                    result = ipc(directory, state, options.operation,
                                 dict(clientPid=request.get("clientPid"), clientNonce=request.get("clientNonce")))
            else:
                result = inspect(root, options.tmux, directory)
    sys.stdout.buffer.write(encode(result) + b"\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No request/argv/environment reflection in public diagnostics.
        sys.stdout.buffer.write(encode({"error": str(error)[:400]}) + b"\n")
        sys.exit(1)
