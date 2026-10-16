#!/usr/bin/env python3
"""Read-only, dependency-free local history scanner for ashub (Python 3.9+).

One source per invocation. Stdout is an NDJSON protocol; stderr is diagnostic.
Never import or invoke an agent. SQLite connections use mode=ro and query_only.
"""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import sqlite3
import sys


UNKNOWN = "unknown"


def emit(kind, **values):
    print(json.dumps(dict(kind=kind, **values), ensure_ascii=True), flush=True)


def diagnostic(path, message):
    emit("diagnostic", path=str(path), message=str(message))


def timestamp(value):
    """Normalize a producer timestamp, never substitute filesystem mtime."""
    try:
        if isinstance(value, str):
            try:
                value = float(value)
            except ValueError:
                parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    return None
                value = parsed.timestamp()
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            return None
        if value > 100_000_000_000:
            value /= 1000
        return value if math.isfinite(value) and 0 < value < 100_000_000_000 else None
    except (ValueError, OverflowError, OSError):
        return None


def content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = [p.get("text", "") for p in content
                 if isinstance(p, dict) and p.get("type") in
                 ("text", "input_text", "output_text")]
        return "\n".join(t for t in texts if isinstance(t, str)) or "[非文本用户消息]"
    return "[非文本用户消息]"


def record(session_id, path=None):
    return dict(id=session_id, path=str(path) if path else None, cwd=None,
                first_message=None, last_active=None, time_source=None,
                internal=UNKNOWN, empty=UNKNOWN, archived=UNKNOWN,
                origin=None, title=None)


class Messages:
    def __init__(self):
        self.first = None
        self.last = None
        self.users = 0
        self.complete = True
        self.time_source = "message"

    def add(self, role, content, time):
        if role not in ("user", "assistant"):
            return
        if role == "user":
            if not self.users and self.complete:
                self.first = content_text(content)
            self.users += 1
        time = timestamp(time)
        if time:
            self.last = max(self.last or time, time)

    def apply(self, item):
        item.update(first_message=self.first, last_active=self.last,
                    time_source=self.time_source if self.last else None,
                    empty=False if self.users else (True if self.complete else UNKNOWN))


def json_lines(path, messages):
    """Read only the initial extent; flag malformed or concurrently truncated logs."""
    try:
        if path.is_symlink():
            raise ValueError("Symlink log skipped")
        with path.open("rb") as stream:
            size = os.fstat(stream.fileno()).st_size
            position = 0
            while position < size:
                line = stream.readline(size - position)
                if not line:
                    messages.complete = False
                    diagnostic(path, "Log truncated during scan")
                    break
                position += len(line)
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise ValueError("JSON record is not an object")
                    yield value
                except (ValueError, UnicodeError) as error:
                    messages.complete = False
                    diagnostic(path, f"Invalid JSON record at byte {position}: {error}")
    except (OSError, ValueError) as error:
        messages.complete = False
        diagnostic(path, error)


def claude(root):
    projects = root / "projects"
    if not projects.is_dir():
        raise FileNotFoundError(f"Missing projects directory: {projects}")
    with os.scandir(projects) as entries:
        folders = sorted((Path(e.path) for e in entries if e.is_dir(follow_symlinks=False)))
    for folder in folders:
        try:
            with os.scandir(folder) as entries:
                paths = sorted(Path(e.path) for e in entries if e.name.endswith(".jsonl"))
            for path in paths:
                messages = Messages()
                item = record(None, path)
                for event in json_lines(path, messages):
                    session_id = event.get("sessionId")
                    if session_id:
                        if item["id"] and item["id"] != session_id:
                            messages.complete = False
                            diagnostic(path, "Conflicting session IDs; record rejected")
                            item["id"] = None
                            break
                        item["id"] = session_id
                    if isinstance(event.get("cwd"), str):
                        item["cwd"] = event["cwd"]
                    if event.get("isSidechain") is True:
                        item["internal"] = True
                    elif event.get("isSidechain") is False and item["internal"] != True:
                        item["internal"] = False
                    if event.get("isMeta") or event.get("type") not in ("user", "assistant"):
                        continue
                    message = event.get("message") or {}
                    if not isinstance(message, dict):
                        messages.complete = False
                        diagnostic(path, "Invalid Claude message object")
                        continue
                    content = message.get("content")
                    if message.get("role") == "user" or event.get("type") == "user":
                        # Tool replies are protocol messages, not user-originated turns.
                        if isinstance(content, list) and content and all(
                                isinstance(p, dict) and p.get("type") == "tool_result"
                                for p in content):
                            continue
                    messages.add(event["type"], content, event.get("timestamp"))
                if item["id"]:
                    messages.apply(item)
                    item["origin"] = "Claude history (entry point unknown)"
                    emit("item", item=item)
                else:
                    diagnostic(path, "No unambiguous session ID")
        except OSError as error:
            diagnostic(folder, error)


def connect(path):
    """No database creation, migration, journal-mode changes or write statements."""
    if not path.is_file():
        raise FileNotFoundError(path)
    # Refuse a WAL without its shared index: do not create sidecars to browse.
    wal = Path(str(path) + "-wal")
    if wal.exists() and wal.stat().st_size and not Path(str(path) + "-shm").exists():
        raise RuntimeError(f"WAL shared index missing for {path}; refusing sidecar creation")
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    connection.execute("BEGIN")
    return connection


def columns(connection, table):
    # Table identifiers here are constants, never source data.
    return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}


def codex_source(value):
    try:
        value = json.loads(value) if isinstance(value, str) else value
    except ValueError:
        pass
    internal = value == "subagent" or (isinstance(value, dict) and
                                      ("subagent" in value or "sub_agent" in value))
    return internal if internal else UNKNOWN, value


def codex_rollout(path):
    messages = Messages()
    for event in json_lines(path, messages):
        payload = event.get("payload") or {}
        if not isinstance(payload, dict):
            messages.complete = False
            diagnostic(path, "Invalid Codex rollout payload")
            continue
        if event.get("type") == "event_msg":
            kind = payload.get("type")
            if kind in ("user_message", "agent_message"):
                content = payload.get("message")
                if not content and (payload.get("images") or payload.get("local_images")):
                    content = []
                messages.add("user" if kind == "user_message" else "assistant",
                             content, event.get("timestamp"))
        elif event.get("type") == "response_item" and payload.get("role") == "assistant":
            messages.add("assistant", payload.get("content"), event.get("timestamp"))
    return messages


def history_messages(connection, session_id):
    """The current Codex thread history is complete across pages, unlike history.jsonl."""
    messages = Messages()
    messages.time_source = "thread-history item/turn"
    required = {"thread_id", "turn_id", "item_type", "item_json"}
    item_columns = columns(connection, "thread_items")
    turn_columns = columns(connection, "thread_turns")
    if not required <= item_columns:
        raise ValueError("Unsupported thread_items schema")
    ordinal = "rollout_ordinal" if "rollout_ordinal" in item_columns else "ordinal"
    if {"thread_id", "turn_id", "rollout_ordinal", "started_at", "completed_at"} <= turn_columns and ordinal in item_columns:
        # Current Desktop schema: rollout_ordinal is stable across independently loaded pages.
        query = f"""SELECT i.*, t.started_at AS turn_started, t.completed_at AS turn_completed
          FROM thread_items i LEFT JOIN thread_turns t
          ON i.thread_id=t.thread_id AND i.turn_id=t.turn_id
          WHERE i.thread_id=? AND i.item_type IN ('userMessage','agentMessage')
          ORDER BY t.rollout_ordinal, i.{ordinal}"""
    else:
        raise ValueError("Cannot establish history turn order")
    for row in connection.execute(query, (session_id,)):
        try:
            item = json.loads(row["item_json"])
            kind = row["item_type"]
            content = item.get("content", item.get("text", item.get("message")))
            row = dict(row)
            messages.add("user" if kind == "userMessage" else "assistant", content,
                         item.get("timestamp") or
                         (row.get("started_at_ms") or row["turn_started"] if kind == "userMessage"
                          else row.get("completed_at_ms") or row["turn_completed"]))
        except (ValueError, AttributeError) as error:
            messages.complete = False
            diagnostic(session_id, f"Invalid Codex history item: {error}")
    return messages


def codex(root):
    versions = []
    for path in root.glob("state_*.sqlite"):
        suffix = path.stem.removeprefix("state_")
        if suffix.isdigit():
            versions.append((int(suffix), path))
    if not versions:
        raise FileNotFoundError(f"No state_N.sqlite in {root}")
    state = connect(max(versions)[1])
    history = None
    history_paths = list(root.glob("thread_history_*.sqlite"))
    try:
        if history_paths:
            try:
                history = connect(max(history_paths, key=lambda p: int(p.stem.rsplit("_", 1)[1])))
            except (OSError, ValueError, sqlite3.Error, RuntimeError) as error:
                diagnostic(root, f"Thread history unavailable: {error}")
        if not {"id", "cwd"} <= columns(state, "threads"):
            raise ValueError("Unsupported threads schema")
        for raw in state.execute("SELECT * FROM threads"):
            row = dict(raw)
            item = record(row["id"], row.get("rollout_path"))
            item.update(cwd=row.get("cwd"), archived=bool(row["archived"]) if
                        row.get("archived") is not None else UNKNOWN, title=row.get("title"))
            item["internal"], item["origin"] = codex_source(row.get("source"))
            messages = None
            if history:
                try:
                    candidate = history_messages(history, row["id"])
                    if candidate.users:
                        messages = candidate
                except (ValueError, sqlite3.Error) as error:
                    diagnostic(row["id"], error)
            path = Path(item["path"]) if item["path"] else None
            if path and path.is_file():
                rollout = codex_rollout(path)
                if messages is None:
                    messages = rollout
                elif rollout.last and rollout.last > (messages.last or 0):
                    messages.last = rollout.last
                    messages.time_source = "message"
            elif messages is None:
                diagnostic(row["id"], "No readable rollout or complete thread history; metadata only")
            if messages:
                messages.apply(item)
            # A state index's first_user_message is an explicit message field, not its generated title.
            if item["first_message"] is None and row.get("first_user_message"):
                item.update(first_message=row["first_user_message"], empty=False)
            emit("item", item=item)
    finally:
        state.close()
        if history:
            history.close()


def hermes(root):
    connection = connect(root / "state.db")
    try:
        if not {"id"} <= columns(connection, "sessions"):
            raise ValueError("Unsupported sessions schema")
        message_columns = columns(connection, "messages")
        if not {"session_id", "role", "content", "timestamp"} <= message_columns:
            raise ValueError("Unsupported messages schema")
        for raw in connection.execute("SELECT * FROM sessions"):
            row = dict(raw)
            item = record(row["id"])
            config = row.get("model_config") or "{}"
            try:
                config = json.loads(config)
            except (ValueError, TypeError):
                config = {}
                diagnostic(row["id"], "Invalid Hermes model_config")
            item.update(cwd=row.get("cwd"), origin=row.get("source"), title=row.get("title"),
                        internal=True if row.get("source") == "subagent" or
                        (isinstance(config, dict) and config.get("_delegate_from")) else UNKNOWN,
                        archived=bool(row["archived"]) if row.get("archived") is not None else UNKNOWN)
            messages = Messages()
            order = "timestamp, id" if "id" in message_columns else "timestamp, rowid"
            for raw_message in connection.execute(
                    f"SELECT * FROM messages WHERE session_id=? ORDER BY {order}", (row["id"],)):
                message = dict(raw_message)
                if message.get("display_kind") or message.get("_compressed_summary"):
                    continue
                if message.get("active") == 0 and message.get("compacted") == 0:
                    continue
                content = message["content"]
                if isinstance(content, str):
                    try:
                        content = json.loads(content)
                    except ValueError:
                        pass
                # Legacy compaction handoffs are not user messages.
                text = content_text(content)
                if text.lstrip().startswith(("[CONTEXT COMPACTION — REFERENCE ONLY]",
                                              "[CONTEXT SUMMARY]:")) or (
                        "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]" in text):
                    continue
                messages.add(message["role"], content, message["timestamp"])
            messages.apply(item)
            emit("item", item=item)
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agent", choices=("claude", "codex", "hermes"))
    parser.add_argument("root")
    args = parser.parse_args()
    try:
        root = Path(args.root).expanduser().resolve(strict=True)
        {"claude": claude, "codex": codex, "hermes": hermes}[args.agent](root)
        emit("done")
    except (OSError, ValueError, sqlite3.Error, RuntimeError) as error:
        emit("fatal", message=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
