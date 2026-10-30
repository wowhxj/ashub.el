#!/usr/bin/env python3
"""Full, read-only summary input. Never execute tools or load agent code.

Unlike reference export, this path retains tool calls/results and does not
truncate dialogue. Stdout is one JSON object; partial/malformed reads fail.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import sys


def content(value):
    """Render textual content and tool evidence, not hidden reasoning."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(filter(None, (content(part) for part in value)))
    if not isinstance(value, dict):
        return ""
    kind = value.get("type", "")
    if kind in ("thinking", "reasoning", "redacted_thinking"):
        return ""
    if kind in ("tool_use", "toolCall", "tool_call", "function_call",
                "custom_tool_call"):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    if kind in ("tool_result", "toolResult", "function_call_output",
                "custom_tool_call_output"):
        evidence = dict(value)
        field = "content" if "content" in evidence else "output"
        evidence[field] = content(evidence.get(field, ""))
        return json.dumps(evidence, ensure_ascii=False, sort_keys=True)
    if isinstance(value.get("text"), str):
        return value["text"]
    if "content" in value:
        return content(value["content"])
    return ""


def turn(message):
    role = message.get("role")
    if role not in ("user", "assistant", "tool", "toolResult", "function"):
        return None
    raw_content = message.get("content", message.get("text", ""))
    if role == "user" and isinstance(raw_content, list) and raw_content and all(
            isinstance(part, dict) and part.get("type") == "tool_result" for part in raw_content):
        role = "tool"
    text = content(raw_content)
    calls = message.get("tool_calls")
    if calls:
        text += "\n" + json.dumps(calls, ensure_ascii=False, sort_keys=True)
    if not text.strip():
        return None
    result = {"role": role, "text": text}
    for key in ("name", "toolName", "tool_call_id", "toolCallId", "isError"):
        if key in message:
            result[key] = message[key]
    return result


def log_records(path, root):
    if not path or path.is_symlink() or not path.is_file():
        raise ValueError("Session log is missing, not regular, or a symlink")
    path.resolve().relative_to(root.resolve())
    before = path.stat()
    with path.open(encoding="utf-8") as stream:
        records = [json.loads(line) for line in stream if line.strip()]
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError("Session changed during read")
    if not all(isinstance(row, dict) for row in records):
        raise ValueError("Session contains a non-object record")
    return records


def pi_branch(records, session_id):
    headers = [row for row in records if row.get("type") == "session"]
    if not headers or headers[0].get("id") != session_id:
        raise ValueError("Pi session identity does not match")
    entries = [row for row in records if row.get("id") and row.get("type") != "session"]
    index = {row["id"]: row for row in entries}
    if len(index) != len(entries):
        raise ValueError("Duplicate Pi entry ID")
    result, seen = [], set()
    current = entries[-1]["id"] if entries else None
    while current:
        if current in seen or current not in index:
            raise ValueError("Broken or cyclic Pi branch")
        seen.add(current)
        row = index[current]
        result.append(row)
        current = row.get("parentId")
    return list(reversed(result))


def file_turns(agent, records, session_id):
    result = []
    if agent == "pi":
        records = pi_branch(records, session_id)
    if agent == "claude":
        ids = {r["sessionId"] for r in records if r.get("sessionId")}
        if ids != {session_id}:
            raise ValueError("Claude session identity does not match")
    if agent == "codex":
        ids = {r.get("payload", {}).get("id") for r in records
               if r.get("type") == "session_meta"}
        if ids != {session_id}:
            raise ValueError("Codex session identity does not match")
    codex_response_roles = {r.get("payload", {}).get("role") for r in records
                            if r.get("type") == "response_item" and
                            r.get("payload", {}).get("type") == "message"}
    for row in records:
        message = None
        if agent in ("pi", "claude"):
            message = row.get("message")
            if not isinstance(message, dict) and row.get("type") in ("user", "assistant"):
                message = {"role": row["type"], "content": row.get("content")}
        elif agent == "codex":
            payload = row.get("payload", {})
            if row.get("type") == "response_item":
                kind = payload.get("type", "")
                if kind == "message":
                    message = payload
                elif kind in ("function_call", "function_call_output",
                              "custom_tool_call", "custom_tool_call_output"):
                    message = {"role": "tool" if kind.endswith("output") else "assistant",
                               "content": content(payload)}
            elif row.get("type") == "event_msg":
                kind = payload.get("type")
                if kind in ("user_message", "agent_message"):
                    role = "user" if kind == "user_message" else "assistant"
                    if role not in codex_response_roles:
                        message = {"role": role, "content": payload.get("message", "")}
        if isinstance(message, dict):
            item = turn(message)
            if item:
                result.append(item)
    return result


def database_turns(agent, root, session_id):
    """Read full stored messages where no rollout log is available."""
    if agent == "hermes":
        path = root / "state.db"
        table, key, ordering = "messages", "session_id", "timestamp, rowid"
    elif agent == "codex":
        paths = [p for p in root.glob("thread_history_*.sqlite")
                 if p.stem.rsplit("_", 1)[1].isdigit()]
        if not paths:
            raise ValueError("Codex session has no readable rollout or message database")
        path = max(paths, key=lambda p: int(p.stem.rsplit("_", 1)[1]))
        table, key, ordering = "thread_items", "thread_id", None
    else:
        raise ValueError("No readable log for session")
    if path.is_symlink() or not path.is_file():
        raise ValueError("Message database is missing or a symlink")
    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as db:
        db.execute("PRAGMA query_only=ON")
        db.row_factory = sqlite3.Row
        if agent == "codex":
            columns = {r[1] for r in db.execute("PRAGMA table_info(thread_items)")}
            ordinal = "rollout_ordinal" if "rollout_ordinal" in columns else "ordinal"
            rows = db.execute(f"""SELECT i.*, t.rollout_ordinal AS _turn_ordinal FROM thread_items i
                LEFT JOIN thread_turns t ON i.thread_id=t.thread_id AND i.turn_id=t.turn_id
                WHERE i.thread_id=? ORDER BY t.rollout_ordinal, i.{ordinal}""",
                              (session_id,)).fetchall()
        else:
            rows = db.execute(f"SELECT * FROM {table} WHERE {key}=? ORDER BY {ordering}",
                              (session_id,)).fetchall()
    result = []
    for row in rows:
        message = dict(row)
        if agent == "codex":
            if message["_turn_ordinal"] is None:
                raise ValueError("Cannot establish complete Codex turn order")
            kind = message["item_type"]
            item = json.loads(message["item_json"])
            if not isinstance(item, dict):
                raise ValueError("Codex history item is not structured dialogue")
            if kind in ("reasoning", "compaction"):
                continue
            if kind in ("userMessage", "agentMessage"):
                message = {"role": "user" if kind == "userMessage" else "assistant",
                           "content": item.get("content", item.get("text", item.get("message", "")))}
            else:
                message = {"role": "tool", "content": json.dumps(item, ensure_ascii=False, sort_keys=True)}
        else:
            if message.get("display_kind") or message.get("_compressed_summary"):
                continue
            if message.get("active") == 0 and message.get("compacted") == 0:
                continue
            if isinstance(message.get("content"), str):
                try:
                    message["content"] = json.loads(message["content"])
                except ValueError:
                    pass
        if message.get("tool_calls") and isinstance(message["tool_calls"], str):
            message["tool_calls"] = json.loads(message["tool_calls"])
        item = turn(message)
        if item:
            result.append(item)
    return result


def read_session(agent, root, session_id, path=None):
    root = Path(root).expanduser()
    path = Path(path) if path else None
    if agent == "codex":
        # Desktop's full thread history is preferred over an older rollout.
        # If the CLI has since appended additional user turns, use the log.
        history = database_turns(agent, root, session_id) if any(root.glob("thread_history_*.sqlite")) else []
        rollout = file_turns(agent, log_records(path, root), session_id) if path and path.is_file() else []
        history_users = [t["text"] for t in history if t["role"] == "user"]
        rollout_users = [t["text"] for t in rollout if t["role"] == "user"]
        if rollout_users and (not history_users or
                              (len(rollout_users) > len(history_users) and
                               rollout_users[:len(history_users)] == history_users)):
            turns = rollout
        else:
            turns = history
    elif path and path.is_file() and agent in ("claude", "pi"):
        turns = file_turns(agent, log_records(path, root), session_id)
    else:
        turns = database_turns(agent, root, session_id)
    if not any(item["role"] == "user" for item in turns):
        raise ValueError("Session contains no readable user dialogue")
    # No title, mtime, cwd or message timestamps: metadata-only changes do not
    # trigger another model request. Ordering and tool evidence remain intact.
    return json.dumps(turns, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agent", choices=("claude", "pi", "codex", "hermes"))
    parser.add_argument("root")
    parser.add_argument("session_id")
    parser.add_argument("--path")
    args = parser.parse_args()
    try:
        print(json.dumps({"text": read_session(args.agent, args.root, args.session_id, args.path)},
                         ensure_ascii=True))
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
