#!/usr/bin/env python3
"""Real, isolated tmux/PTY lifecycle checks; no agent or model invocation.

Run from any directory: python3 /path/to/ashub/test/terminal-owner-test.py
Requires POSIX, tmux >= 3.2 and Python >= 3.9. Uses only a private tmux socket.
"""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / "ashub-terminal.py"
TMUX = shutil.which("tmux")
spec = importlib.util.spec_from_file_location("owner", HELPER)
owner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owner)


@unittest.skipUnless(TMUX and os.name == "posix", "POSIX and tmux required")
class TerminalOwnerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ashub-tmux-", dir="/tmp")
        self.base = Path(self.temporary.name)
        self.root = self.base / "run"
        self.history = self.base / "history.json"
        self.fixture = self.base / "agent.py"
        self.fixture.write_text(
            "import json, os, signal, sys, time\n"
            "from pathlib import Path\n"
            "path=Path(os.environ['TEST_HISTORY'])\n"
            "temporary=path.with_name(path.name+'.'+str(os.getpid()))\n"
            "temporary.write_text(json.dumps(dict(pid=os.getpid(), args=sys.argv[1:], "
            "secret=os.environ['TEST_SECRET'], root=os.environ['CLAUDE_CONFIG_DIR'], "
            "tty=os.isatty(0), foreground=os.tcgetpgrp(0)==os.getpgrp())))\n"
            "temporary.replace(path)\n"
            """
kind = os.environ.get('TEST_NATIVE_KIND')
writers = []
first_id = os.environ.get('TEST_NATIVE_ID', '11111111-1111-4111-8111-111111111111')
if '--session-id' in sys.argv:
    first_id = sys.argv[sys.argv.index('--session-id') + 1]
def publish_native(sid, rotation=False):
    root = Path(os.environ[{'claude':'CLAUDE_CONFIG_DIR', 'codex':'CODEX_HOME', 'hermes':'HERMES_HOME'}[kind]])
    def put(target, value):
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + '.tmp')
        tmp.write_text(json.dumps(value))
        tmp.replace(target)
    pid = os.getpid() + (1 if os.environ.get('TEST_NATIVE_FOREIGN') else 0)
    if kind == 'claude':
        put(root / 'sessions' / (str(os.getpid()) + '.json'), dict(pid=pid, sessionId=sid))
    elif kind == 'hermes':
        import re
        terminal = 'tty-' + re.sub('[^A-Za-z0-9._-]', '-', os.ttyname(0).strip().strip('/'))[:120]
        put(root / 'terminal-sessions' / terminal, dict(session_id=sid))
        if not (rotation and os.environ.get('TEST_NATIVE_KEEP_LEASE')):
            put(root / 'runtime' / 'active_sessions.json', dict(entries=[dict(
                pid=pid, surface='cli', session_id=sid, metadata=dict(live_session_id=sid))]))
    elif kind == 'codex':
        directory = root / 'sessions'
        directory.mkdir(parents=True, exist_ok=True)
        if not os.environ.get('TEST_NATIVE_MULTIPLE'):
            for writer in writers: writer.close()
            writers.clear()
        target = directory / ('rollout-fixture-' + sid + '.jsonl')
        if os.environ.get('TEST_NATIVE_READONLY'):
            writers.append(target.open('r'))
        else:
            writer = target.open('w')
            writer.write(json.dumps(dict(type='session_meta', payload=dict(id=sid, source='cli'))) + '\\n')
            writer.flush()
            writers.append(writer)
if kind:
    publish_native(first_id)
    signal.signal(signal.SIGUSR2, lambda *args: publish_native('22222222-2222-4222-8222-222222222222', True))
print('READY', flush=True)
"""
            "def stop(*args):\n"
            "    path.with_suffix('.ended').write_text('terminated')\n"
            "    sys.exit(0)\n"
            "signal.signal(signal.SIGTERM, stop)\n"
            "signal.signal(signal.SIGUSR1, stop)\n"
            "if '--ignore-term' in sys.argv: signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "if '--natural' in sys.argv: time.sleep(.4); sys.exit(7)\n"
            "if '--ignore-int' in sys.argv: signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
            "while os.environ.get('TEST_GATE') and not Path(os.environ['TEST_GATE']).exists(): time.sleep(.04)\n"
            "if '--burst' in sys.argv: print('x'*1048576, flush=True)\n"
            "time.sleep(.3)\n"
            "path.with_suffix('.progress').write_text('work completed without clients')\n"
            "while True: time.sleep(.1)\n")
        self.request = dict(source=dict(agent="claude", root=str(self.base / "source"), profile=None),
                            sessionId="exact-id", directory=str(self.base),
                            program=sys.executable, args=[str(self.fixture), "literal ; $(touch BAD)", "多行\n参数"],
                            environment=dict(os.environ, TEST_HISTORY=str(self.history), TEST_SECRET="private-token-123",
                                             CLAUDE_CONFIG_DIR=str(self.base / "source")))

    def call(self, operation, request=None, check=True):
        if operation == "finish" and request and "generation" not in request:
            record = owner.read_json(self.root / ("i-" + request["runtimeId"]) / "state.json")
            request = dict(request, generation=record["generation"])
        result = subprocess.run([sys.executable, "-B", str(HELPER), operation,
                                 "--runtime-root", str(self.root), "--tmux", TMUX],
                                input=json.dumps(request or {}).encode(), capture_output=True, timeout=18)
        response = json.loads(result.stdout)
        if check:
            self.assertEqual(result.returncode, 0, response)
        return response

    def wait(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(.04)
        self.fail("Timed out waiting for isolated lifecycle condition")

    def start(self, request=None):
        state = self.call("ensure", request or self.request)
        self.assertEqual(state["status"], "running", state)
        self.wait(self.history.exists)
        return state

    def tearDown(self):
        # Cleanup only authenticated owners created by this test's private registry.
        if self.root.exists():
            for path in self.root.glob("i-*/state.json"):
                state = owner.read_json(path)
                if state["status"] not in owner.TERMINAL:
                    self.call("finish", dict(runtimeId=state["runtimeId"]), check=False)
            subprocess.run([TMUX, "-S", str(self.root / "tmux.sock"), "kill-server"],
                           capture_output=True, timeout=5)
        self.temporary.cleanup()

    def test_detached_owner_exact_attach_and_finish_preserve_history(self):
        state = self.start()
        observation = json.loads(self.history.read_text())
        self.assertTrue(observation["tty"])
        self.assertTrue(observation["foreground"])
        self.assertEqual(observation["args"], self.request["args"][1:])
        self.assertFalse((self.base / "BAD").exists())
        self.assertEqual(self.call("ensure", self.request)["childPid"], state["childPid"])
        self.assertEqual(self.call("inspect", dict(runtimeId=state["runtimeId"]))["generation"], state["generation"])
        subprocess.run([TMUX, "-S", str(self.root / "tmux.sock"), "send-keys", "-t", "=" + state["name"] + ":",
                        "-l", "ordinary detached output"], check=True)
        self.assertTrue(owner.alive(state["childPid"]))
        self.assertFalse(list(self.root.glob("i-*/launch.json")))
        for path in self.root.rglob("*.json"):
            self.assertNotIn("private-token-123", path.read_text())
        result = self.call("finish", dict(runtimeId=state["runtimeId"]))
        self.assertEqual(result["status"], "finished")
        self.wait(lambda: not owner.alive(state["childPid"]))
        self.assertTrue(self.history.exists())
        self.assertEqual(self.history.with_suffix(".ended").read_text(), "terminated")
        again = self.start()
        self.assertNotEqual(again["generation"], state["generation"])
        self.assertEqual(again["previousExit"]["generation"], state["generation"])
        self.assertEqual(again["previousExit"]["status"], "finished")

    def native_request(self, kind, **environment):
        return dict(self.request, sessionId=None, source=dict(self.request['source'], agent=kind),
                    environment=dict(self.request['environment'], TEST_NATIVE_KIND=kind, **environment))

    def native_state(self, state):
        return self.call('inspect', dict(runtimeId=state['runtimeId']))

    def test_claude_fresh_uuid_is_literal_and_verified_by_owned_pid_record(self):
        request = self.native_request('claude')
        alias = self.base / 'claude'
        alias.symlink_to(sys.executable)
        request['program'] = str(alias)
        first = self.start(request)
        linked = self.wait(lambda: (value := self.native_state(first)).get('identityVerified') and value)
        observation = json.loads(self.history.read_text())
        self.assertEqual(observation['args'][-2:], ['--session-id', linked['sessionId']])
        self.assertIsNotNone(owner.native_id(linked['sessionId'], True))
        resumed = self.call('ensure', dict(request, sessionId=linked['sessionId']))
        self.assertEqual(resumed['childPid'], first['childPid'])
        self.assertEqual(resumed['generation'], first['generation'])

    def test_codex_writable_rollout_descriptor_links_exact_native_id(self):
        request = self.native_request('codex')
        first = self.start(request)
        linked = self.wait(lambda: (value := self.native_state(first)).get('identityVerified') and value)
        self.assertEqual(linked['sessionId'], '11111111-1111-4111-8111-111111111111')
        self.assertEqual(self.call('ensure', dict(request, sessionId=linked['sessionId']))['childPid'], first['childPid'])

    def test_hermes_primary_pid_and_terminal_breadcrumb_link_id(self):
        request = self.native_request('hermes')
        first = self.start(request)
        linked = self.wait(lambda: (value := self.native_state(first)).get('identityVerified') and value)
        self.assertEqual(linked['sessionId'], '11111111-1111-4111-8111-111111111111')
        self.assertEqual(self.call('ensure', dict(request, sessionId=linked['sessionId']))['childPid'], first['childPid'])

    def test_foreign_pid_record_cannot_bind_this_owner(self):
        for kind in ('claude', 'hermes'):
            with self.subTest(kind=kind):
                request = self.native_request(kind, TEST_NATIVE_FOREIGN='1')
                first = self.start(request)
                time.sleep(.15)
                self.assertIsNone(self.native_state(first)['sessionId'])
                self.assertIn('Unindexed', self.call('ensure', dict(request, sessionId='foreign-id'), check=False)['error'])
                self.call('finish', dict(runtimeId=first['runtimeId']))

    def test_codex_readonly_rollout_is_not_a_writer_identity(self):
        request = self.native_request('codex', TEST_NATIVE_READONLY='1')
        directory = Path(request['source']['root']) / 'sessions'
        directory.mkdir(parents=True)
        sid = '11111111-1111-4111-8111-111111111111'
        (directory / ('rollout-fixture-' + sid + '.jsonl')).write_text(json.dumps(dict(type='session_meta', payload=dict(id=sid))) + '\n')
        first = self.start(request)
        time.sleep(.15)
        self.assertIsNone(self.native_state(first)['sessionId'])

    def test_codex_other_process_writable_rollout_does_not_bind_this_owner(self):
        request = dict(self.native_request('codex'))
        request['environment'].pop('TEST_NATIVE_KIND')
        directory = Path(request['source']['root']) / 'sessions'
        directory.mkdir(parents=True)
        sid = '11111111-1111-4111-8111-111111111111'
        with (directory / ('rollout-foreign-' + sid + '.jsonl')).open('w') as writer:
            writer.write(json.dumps(dict(type='session_meta', payload=dict(id=sid))) + '\n')
            writer.flush()
            first = self.start(request)
            time.sleep(.15)
            self.assertIsNone(self.native_state(first)['sessionId'])
            self.assertIn('Unindexed', self.call('ensure', dict(request, sessionId=sid), check=False)['error'])

    def test_codex_multiple_writable_ids_fail_closed(self):
        first = self.start(self.native_request('codex', TEST_NATIVE_MULTIPLE='1'))
        linked = self.wait(lambda: (value := self.native_state(first)).get('identityVerified') and value)
        os.kill(first['childPid'], signal.SIGUSR2)
        uncertain = self.wait(lambda: (value := self.native_state(first)).get('identityKind') == 'uncertain' and value)
        self.assertIsNone(uncertain['sessionId'])
        self.assertIn(linked['sessionId'], uncertain['previousSessionIds'])
        self.assertTrue(owner.alive(first['childPid']))

    def test_hermes_stale_lease_after_native_rotation_becomes_uncertain(self):
        request = self.native_request('hermes', TEST_NATIVE_KEEP_LEASE='1')
        first = self.start(request)
        linked = self.wait(lambda: (value := self.native_state(first)).get('identityVerified') and value)
        os.kill(first['childPid'], signal.SIGUSR2)
        uncertain = self.wait(lambda: (value := self.native_state(first)).get('identityKind') == 'uncertain' and value)
        self.assertIsNone(uncertain['sessionId'])
        self.assertIn('reserved', self.call('ensure', dict(request, sessionId=linked['sessionId']), check=False)['error'])
        self.assertTrue(owner.alive(first['childPid']))

    def test_native_rotation_keeps_instance_and_reserves_old_conversation(self):
        request = self.native_request('claude')
        first = self.start(request)
        linked = self.wait(lambda: (value := self.native_state(first)).get('identityVerified') and value)
        os.kill(first['childPid'], signal.SIGUSR2)
        changed = self.wait(lambda: (value := self.native_state(first)).get('sessionId') == '22222222-2222-4222-8222-222222222222' and value)
        self.assertEqual(changed['runtimeId'], first['runtimeId'])
        self.assertEqual(changed['generation'], first['generation'])
        self.assertIn('reserved', self.call('ensure', dict(request, sessionId=linked['sessionId']), check=False)['error'])
        self.assertEqual(self.call('ensure', dict(request, sessionId=changed['sessionId']))['childPid'], first['childPid'])
        self.call('finish', dict(runtimeId=first['runtimeId']))
        restored = self.start(dict(self.request, sessionId=linked['sessionId']))
        self.assertNotEqual(restored['runtimeId'], first['runtimeId'])

    def test_real_pty_client_sigkill_does_not_stop_backend(self):
        state = self.start()
        pid, descriptor = os.forkpty()
        if pid == 0:
            os.execvpe(TMUX, [TMUX, "-S", str(self.root / "tmux.sock"), "attach-session", "-E",
                             "-t", "=" + state["name"]], dict(os.environ, TERM="xterm-256color", TMUX=""))
        try:
            self.wait(lambda: owner.tmux_call(TMUX, self.root, "display-message", "-p", "-t",
                                             "=" + state["name"] + ":", "#{session_attached}") == "1")
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            pid = None
            self.wait(self.history.with_suffix(".progress").exists)
            self.assertEqual(self.call("ensure", self.request)["childPid"], state["childPid"])
            self.assertEqual(self.call("inspect", dict(runtimeId=state["runtimeId"]))["status"], "running")
        finally:
            if pid:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(descriptor)

    def test_detached_megabyte_output_is_drained(self):
        state = self.start(dict(self.request, args=[str(self.fixture), "--burst"]))
        self.wait(self.history.with_suffix(".progress").exists)
        self.assertEqual(self.call("inspect", dict(runtimeId=state["runtimeId"]))["status"], "running")

    def test_ctrl_c_targets_agent_not_owner(self):
        state = self.start(dict(self.request, args=[str(self.fixture), "--ignore-int"]))
        self.wait(self.history.with_suffix(".progress").exists)
        subprocess.run([TMUX, "-S", str(self.root / "tmux.sock"), "send-keys", "-t",
                        "=" + state["name"] + ":", "C-c"], check=True)
        self.assertEqual(self.call("inspect", dict(runtimeId=state["runtimeId"]))["status"], "running")

    def test_parallel_ensure_has_one_writer(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            states = list(pool.map(lambda _: self.call("ensure", self.request), range(4)))
        self.assertEqual(len({state["childPid"] for state in states}), 1)
        self.assertEqual(len({state["generation"] for state in states}), 1)

    def test_configuration_conflict_and_source_isolation(self):
        first = self.start()
        changed = dict(self.request, sourceArgs=["--changed"])
        self.assertIn("configuration changed", self.call("ensure", changed, check=False)["error"])
        changed = dict(self.request, source=dict(self.request["source"], profile="second"))
        self.assertIn("another profile", self.call("ensure", changed, check=False)["error"])
        changed = dict(changed, source=dict(changed["source"], root=str(self.base / "separate-home")))
        second = self.call("ensure", changed)
        self.assertNotEqual(first["childPid"], second["childPid"])
        self.wait(lambda: json.loads(self.history.read_text())["pid"] == second["childPid"])
        self.assertEqual(json.loads(self.history.read_text())["root"], second["source"]["root"])
        self.call("finish", dict(runtimeId=second["runtimeId"]))
        self.assertTrue(owner.alive(first["childPid"]))

    def test_natural_exit_releases_pane_and_keeps_status(self):
        state = self.start(dict(self.request, args=[str(self.fixture), "--natural"]))
        result = self.wait(lambda: next((item for item in self.call("list") if item["status"] == "exited"), None))
        self.assertEqual(result["exitCode"], 7)
        self.assertEqual(result["reason"], "natural-exit")
        self.assertIsNone(owner.pane(TMUX, self.root, owner.read_json(self.root / ("i-" + state["runtimeId"]) / "state.json")))

    def test_fresh_unindexed_instance_blocks_duplicate_history_writer(self):
        fresh = self.start(dict(self.request, sessionId=None))
        self.assertIsNone(fresh["sessionId"])
        self.assertIn("Unindexed live terminal", self.call("ensure", self.request, check=False)["error"])
        self.assertEqual(self.call("inspect", dict(runtimeId=fresh["runtimeId"]))["childPid"], fresh["childPid"])

    def test_unknown_owner_refuses_pid_signals_and_restart(self):
        state = self.start()
        subprocess.run([TMUX, "-S", str(self.root / "tmux.sock"), "set-option", "-t", state["name"],
                        "@ashub-generation", "wrong"], check=True)
        self.assertIn("ownership is unknown", self.call("finish", dict(runtimeId=state["runtimeId"]), check=False)["error"])
        self.assertIn("ownership is unknown", self.call("ensure", self.request, check=False)["error"])
        self.assertIn("ownership is unknown", self.call("ensure", dict(self.request, sessionId='possibly-rotated-id'), check=False)["error"])
        self.assertTrue(owner.alive(state["childPid"]))
        subprocess.run([TMUX, "-S", str(self.root / "tmux.sock"), "set-option", "-t", state["name"],
                        "@ashub-generation", state["generation"]], check=True)

    @unittest.skipUnless(os.environ.get("ASHUB_TMUX_NATIVE") == "1" and shutil.which("emacs"),
                         "Set ASHUB_TMUX_NATIVE=1 for independent real Emacs exit/SIGKILL tests")
    def test_independent_emacs_exit_sigkill_and_exact_reconnect(self):
        for mode in ("exit", "kill"):
            with self.subTest(mode=mode):
                gate = self.base / (mode + ".gate")
                output = self.base / (mode + ".json")
                args = [str(self.fixture), "--burst", "literal ; $(touch BAD)", "跨行\n参数"]
                environment = dict(self.request["environment"], TEST_GATE=str(gate),
                                   ASHUB_TEST_PYTHON=sys.executable, ASHUB_TEST_RUNTIME=str(self.root),
                                   ASHUB_TEST_SOURCE=self.request["source"]["root"],
                                   ASHUB_TEST_DIRECTORY=str(self.base), ASHUB_TEST_ARGS=json.dumps(args),
                                   ASHUB_TEST_OUTPUT=str(output), ASHUB_TEST_MODE=mode)
                command = [shutil.which("emacs"), "--batch", "-Q", "-L", str(HELPER.parent),
                           "--eval", "(setq load-prefer-newer t)",
                           "-l", str(Path(__file__).with_name("terminal-native-child.el"))]
                child = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.wait(lambda: output.exists() or child.poll() is not None)
                    if not output.exists():
                        self.fail("Independent Emacs failed: " + repr(child.communicate(timeout=2)))
                    first = json.loads(output.read_text())
                    if mode == "kill":
                        controller = self.call("inspect", dict(runtimeId=first["runtimeId"]))
                        self.assertEqual(controller["controllerPid"], child.pid)
                        denied = self.call("claim", dict(runtimeId=first["runtimeId"], generation=first["generation"],
                                                          clientPid=os.getpid(), clientNonce="e" * 32), check=False)
                        self.assertIn("already attached", denied["error"])
                        child.kill()
                    stdout, stderr = child.communicate(timeout=10)
                    self.assertEqual(child.returncode, -signal.SIGKILL if mode == "kill" else 0, stderr.decode())
                    progress = self.history.with_suffix(".progress")
                    if progress.exists():
                        progress.unlink()
                    gate.touch()  # Controlled fixture starts work only AFTER Emacs has gone.
                    self.wait(progress.exists)
                    current = self.call("inspect", dict(runtimeId=first["runtimeId"]))
                    self.assertEqual(current["childPid"], first["childPid"])
                    self.assertEqual(current["generation"], first["generation"])
                    recovered = self.base / (mode + ".recovered.json")
                    environment.update(ASHUB_TEST_MODE="finish", ASHUB_TEST_OUTPUT=str(recovered))
                    second = subprocess.run(command, env=environment, capture_output=True, timeout=20)
                    self.assertEqual(second.returncode, 0, second.stderr.decode())
                    state = json.loads(recovered.read_text())
                    self.assertEqual(state["childPid"], first["childPid"])
                    self.assertEqual(state["generation"], first["generation"])
                    self.wait(lambda: not owner.alive(first["childPid"]))
                    self.assertTrue(self.history.exists())
                    self.assertFalse((self.base / "BAD").exists())
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate(timeout=5)

    def test_controller_reservation_is_exclusive_and_nonce_qualified(self):
        state = self.start()
        first = dict(runtimeId=state["runtimeId"], generation=state["generation"],
                     clientPid=os.getpid(), clientNonce="a" * 32)
        second = dict(first, clientNonce="b" * 32)
        result = self.call("claim", first)
        self.assertEqual(result["controllerPid"], os.getpid())
        self.assertNotIn("lease", result)
        self.assertIn("already attached", self.call("claim", second, check=False)["error"])
        self.call("release", second)  # Wrong nonce cannot release the reservation.
        self.assertIn("already attached", self.call("claim", second, check=False)["error"])
        self.call("release", first)
        self.call("claim", second)
        self.assertIn("generation changed", self.call("release", dict(second, generation="old"), check=False)["error"])
        self.assertEqual(self.call("inspect", dict(runtimeId=state["runtimeId"]))["controllerPid"], os.getpid())
        self.call("release", second)

    def test_controller_cannot_be_reclaimed_while_a_pty_is_attached(self):
        state = self.start()
        first = dict(runtimeId=state["runtimeId"], generation=state["generation"],
                     clientPid=os.getpid(), clientNonce="c" * 32)
        self.call("claim", first)
        pid, descriptor = os.forkpty()
        if pid == 0:
            os.execvpe(TMUX, [TMUX, "-S", str(self.root / "tmux.sock"), "attach-session", "-E",
                             "-t", "=" + state["name"]], dict(os.environ, TERM="xterm-256color", TMUX=""))
        try:
            self.wait(lambda: owner.tmux_call(TMUX, self.root, "display-message", "-p", "-t",
                                             "=" + state["name"] + ":", "#{session_attached}") == "1")
            self.call("release", first)
            self.assertIn("still has an attached client", self.call("claim", dict(first, clientNonce="d" * 32), check=False)["error"])
        finally:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(descriptor)

    def test_stale_generation_cannot_finish_new_instance(self):
        first = self.start()
        self.call("finish", dict(runtimeId=first["runtimeId"]))
        second = self.start()
        result = self.call("finish", dict(runtimeId=second["runtimeId"], generation=first["generation"]), check=False)
        self.assertIn("Generation changed", result["error"])
        self.assertTrue(owner.alive(second["childPid"]))

    def test_teardown_target_error_needs_positive_inventory_absence(self):
        state = dict(name="ashub-test", generation="generation", token="token", ownerPid=os.getpid())
        for disappears in (True, False):
            calls = []
            def query(_tmux, _root, operation, *args, **kwargs):
                calls.append(operation)
                if operation == "list-sessions":
                    return "ashub-test" if len(calls) == 1 or not disappears else ""
                if operation == "display-message":
                    raise ValueError("tmux operation failed: no current target")
                self.fail("Must use exact inventory, not a current-target-dependent query")
            with patch.object(owner, "tmux_call", query):
                if disappears:
                    self.assertIsNone(owner.pane(TMUX, self.root, state))
                else:
                    with self.assertRaisesRegex(ValueError, "no current target"):
                        owner.pane(TMUX, self.root, state)

    def test_readonly_inspection_has_no_startup_side_effects(self):
        self.assertEqual(self.call("list"), [])
        self.assertEqual(self.call("inspect", dict(runtimeId="a" * 24)), {"status": "absent"})
        self.assertFalse(self.root.exists())

    def test_uncooperative_finish_is_pending_not_false_success(self):
        state = self.start(dict(self.request, args=[str(self.fixture), "--ignore-term"]))
        self.wait(self.history.with_suffix(".progress").exists)
        result = self.call("finish", dict(runtimeId=state["runtimeId"]), check=False)
        self.assertIn("Finish still pending", result["error"])
        self.assertTrue(owner.alive(state["childPid"]))
        current = self.call("inspect", dict(runtimeId=state["runtimeId"]))
        self.assertEqual(current["status"], "stopping")
        self.assertEqual(current["generation"], state["generation"])
        os.kill(state["childPid"], signal.SIGUSR1)  # Only our known test fixture handles this.
        self.wait(lambda: self.call("inspect", dict(runtimeId=state["runtimeId"]))["status"] == "finished")

    def test_lost_owner_only_recovers_after_every_owned_identity_is_gone(self):
        state = self.start()
        os.kill(state["ownerPid"], signal.SIGKILL)  # Isolated owner; never a real agent.
        self.wait(lambda: not any((owner.alive(state["ownerPid"]), owner.alive(state["childPid"]),
                                  owner.alive(state["childPid"], group=True))))
        current = self.call("inspect", dict(runtimeId=state["runtimeId"]))
        self.assertEqual(current["status"], "exited")
        self.assertEqual(current["reason"], "owner-lost-history-only")
        again = self.start()
        self.assertNotEqual(state["generation"], again["generation"])
        self.assertEqual(again["previousExit"]["reason"], "owner-lost-history-only")

    def test_unsafe_runtime_permissions_rejected(self):
        self.root.mkdir(mode=0o755)
        self.assertIn("0700", self.call("ensure", self.request, check=False)["error"])
        self.assertFalse(self.history.exists())
        self.root.chmod(0o700)


class NativeCodecTest(unittest.TestCase):
    def test_unchanged_preexec_pid_record_is_not_a_new_native_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            home, pid = Path(directory), os.getpid()
            path = home / 'sessions' / (str(pid) + '.json')
            path.parent.mkdir()
            first = '11111111-1111-4111-8111-111111111111'
            path.write_text(json.dumps(dict(pid=pid, sessionId=first)))
            baseline = owner.identity_baseline('claude', home, pid, '/dev/mock')
            self.assertEqual(owner.discover_identity('claude', home, pid, baseline, '/unused'), (None, 'pending'))
            second = '22222222-2222-4222-8222-222222222222'
            path.write_text(json.dumps(dict(pid=pid, sessionId=second)))
            self.assertEqual(owner.discover_identity('claude', home, pid, baseline, '/unused'), (second, 'verified'))

    def test_unrelated_hermes_registry_update_does_not_validate_stale_pid_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            home, pid = Path(directory), os.getpid()
            entry = dict(pid=pid, surface='cli', session_id='native-id', metadata=dict(live_session_id='native-id'))
            registry = home / 'runtime' / 'active_sessions.json'
            registry.parent.mkdir()
            registry.write_text(json.dumps(dict(entries=[entry])))
            crumb = home / 'terminal-sessions' / 'tty-dev-mock'
            crumb.parent.mkdir()
            crumb.write_text(json.dumps(dict(session_id='native-id')))
            baseline = owner.identity_baseline('hermes', home, pid, '/dev/mock')
            registry.write_text(json.dumps(dict(entries=[entry, dict(pid=pid + 1, surface='cli', session_id='other-id')])))
            self.assertEqual(owner.discover_identity('hermes', home, pid, baseline, '/unused'), (None, 'pending'))

    def test_native_metadata_symlink_and_noncanonical_uuid_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home / 'real.json'
            target.write_text('{}')
            alias = home / 'alias.json'
            alias.symlink_to(target)
            self.assertEqual(owner.native_json(alias), (None, None))
            self.assertIsNone(owner.native_id('11111111111141118111111111111111', True))
            self.assertIsNone(owner.native_id('latest'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
