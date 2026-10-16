"""Synthetic-store acceptance tests. No installed agent or user history is used."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("ashub_scan", Path(__file__).parents[1] / "ashub-scan.py")
scan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scan)


class ScannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def capture(self, function):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            function(self.root)
        events = [json.loads(line) for line in out.getvalue().splitlines()]
        return [x["item"] for x in events if x["kind"] == "item"], [x for x in events if x["kind"] == "diagnostic"]

    def log(self, path, events):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in events) + "\n")

    def claude_event(self, role="user", content="first", **extra):
        return dict(type=role, sessionId="session-a", cwd="/project", isSidechain=False,
                    message=dict(role=role, content=content), timestamp="2026-01-01T00:00:00Z", **extra)

    def test_claude_uses_message_time_and_full_first_message(self):
        path = self.root / "projects/project/session-a.jsonl"
        text = "汉字" * 6000 + " needle-at-end"
        self.log(path, [self.claude_event(content=text),
                        dict(self.claude_event("assistant"), timestamp="2026-01-02T00:00:00Z"),
                        dict(type="progress", timestamp="2099-01-01T00:00:00Z")])
        items, errors = self.capture(scan.claude)
        self.assertFalse(errors)
        self.assertEqual(items[0]["first_message"], text)
        self.assertEqual(items[0]["last_active"], scan.timestamp("2026-01-02T00:00:00Z"))
        self.assertFalse(items[0]["empty"])

    def test_claude_image_first_not_replaced_and_tools_not_user(self):
        self.log(self.root / "projects/p/a.jsonl", [
            self.claude_event(content=[dict(type="tool_result", content="tool")]),
            self.claude_event(content=[dict(type="image", source={})]),
            self.claude_event(content="later")])
        items, _ = self.capture(scan.claude)
        self.assertEqual(items[0]["first_message"], "[非文本用户消息]")
        self.assertFalse(items[0]["empty"])

    def test_claude_metadata_not_user_and_internal_explicit(self):
        event = self.claude_event(isMeta=True)
        event["isSidechain"] = True
        self.log(self.root / "projects/p/a.jsonl", [event])
        items, _ = self.capture(scan.claude)
        self.assertTrue(items[0]["internal"])
        self.assertTrue(items[0]["empty"])

    def test_claude_invalid_json_is_not_empty(self):
        path = self.root / "projects/p/a.jsonl"
        self.log(path, [dict(type="system", sessionId="session-a")])
        with path.open("a") as stream:
            stream.write('{"incomplete":')
        items, errors = self.capture(scan.claude)
        self.assertTrue(errors)
        self.assertEqual(items[0]["empty"], "unknown")
        self.assertTrue(all(error["category"] == "read" for error in errors))

    def test_claude_conflicting_ids_rejected(self):
        self.log(self.root / "projects/p/a.jsonl", [self.claude_event(),
                  dict(self.claude_event(), sessionId="another")])
        items, errors = self.capture(scan.claude)
        self.assertFalse(items)
        self.assertTrue(errors)

    def test_claude_symlink_is_diagnostic(self):
        outside = self.root / "other.jsonl"
        self.log(outside, [self.claude_event()])
        folder = self.root / "projects/p"
        folder.mkdir(parents=True)
        (folder / "alias.jsonl").symlink_to(outside)
        items, errors = self.capture(scan.claude)
        self.assertFalse(items)
        self.assertTrue(errors)

    def codex_db(self, session_id="codex-session", rollout=None, source='"cli"', archived=0):
        connection = sqlite3.connect(self.root / "state_5.sqlite")
        connection.executescript("""CREATE TABLE threads
          (id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT, title TEXT,
           first_user_message TEXT, source TEXT, archived INTEGER);""")
        connection.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?)",
                           (session_id, "/codex-project", str(rollout) if rollout else None,
                            "generated title", None, source, archived))
        connection.commit()
        connection.close()

    def codex_history(self):
        connection = sqlite3.connect(self.root / "thread_history_1.sqlite")
        connection.executescript("""
          CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER,
            item_type TEXT, item_json TEXT);
          CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER,
            started_at INTEGER, completed_at INTEGER);
          INSERT INTO thread_turns VALUES('codex-session','first',0,1767225600,1767225605);
          INSERT INTO thread_turns VALUES('codex-session','last',5,1767225700,1767225705);
        """)
        # Deliberately insert the later page first. Restore full chronological order.
        for turn, ordinal, typ, item in [
            ("last", 20, "agentMessage", dict(text="last reply")),
            ("last", 18, "userMessage", dict(content=[dict(type="text", text="later")])),
            ("first", 2, "userMessage", dict(content=[dict(type="text", text="Desktop first")]))]:
            connection.execute("INSERT INTO thread_items VALUES(?,?,?,?,?)",
                               ("codex-session", turn, ordinal, typ, json.dumps(item)))
        connection.commit()
        connection.close()

    def test_codex_reads_all_desktop_pages_in_order(self):
        self.codex_db()
        self.codex_history()
        items, errors = self.capture(scan.codex)
        self.assertFalse(errors)
        self.assertEqual(items[0]["first_message"], "Desktop first")
        self.assertEqual(items[0]["last_active"], 1767225705)
        self.assertFalse(items[0]["empty"])

    def test_codex_rollout_does_not_misread_injected_user_context(self):
        rollout = self.root / "sessions/a.jsonl"
        self.log(rollout, [
            dict(type="response_item", timestamp="2099-01-01T00:00:00Z",
                 payload=dict(role="user", content=[dict(type="input_text", text="<environment_context>")])),
            dict(type="event_msg", timestamp="2026-01-01T00:00:00Z",
                 payload=dict(type="user_message", message="actual user")),
            dict(type="event_msg", timestamp="2026-01-01T00:01:00Z",
                 payload=dict(type="agent_message", message="reply"))])
        self.codex_db(rollout=rollout, source='{"subagent":{"parent_thread_id":"x"}}')
        items, _ = self.capture(scan.codex)
        self.assertTrue(items[0]["internal"])
        self.assertEqual(items[0]["first_message"], "actual user")
        self.assertEqual(items[0]["last_active"], scan.timestamp("2026-01-01T00:01:00Z"))

    def test_codex_image_event_not_empty(self):
        rollout = self.root / "sessions/a.jsonl"
        self.log(rollout, [dict(type="event_msg", payload=dict(type="user_message", message="", images=["x"]))])
        self.codex_db(rollout=rollout)
        items, _ = self.capture(scan.codex)
        self.assertFalse(items[0]["empty"])
        self.assertEqual(items[0]["first_message"], "[非文本用户消息]")
        self.assertIsNone(items[0]["last_active"])

    def test_codex_metadata_only_does_not_fake_title_as_prompt(self):
        self.codex_db(archived=1)
        items, errors = self.capture(scan.codex)
        self.assertTrue(errors)
        self.assertIsNone(items[0]["first_message"])
        self.assertIsNone(items[0]["last_active"])
        self.assertEqual(items[0]["empty"], "unknown")
        self.assertTrue(items[0]["archived"])
        self.assertTrue(all(error["category"] == "metadata" for error in errors))

    def hermes_db(self, content, cwd=None, source="telegram", config="{}"):
        connection = sqlite3.connect(self.root / "state.db")
        connection.executescript("""
          CREATE TABLE sessions(id TEXT PRIMARY KEY, cwd TEXT, source TEXT, model_config TEXT,
                                archived INTEGER);
          CREATE TABLE messages(id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            timestamp REAL, active INTEGER, compacted INTEGER, display_kind TEXT, _compressed_summary INTEGER);
        """)
        connection.execute("INSERT INTO sessions VALUES('hermes-session',?,?,?,0)", (cwd, source, config))
        for index, (role, value, time, display, summary, active, compacted) in enumerate(content):
            connection.execute("INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?)",
                               (index, "hermes-session", role, json.dumps(value), time,
                                active, compacted, display, summary))
        connection.commit()
        connection.close()

    def test_hermes_ignores_bookkeeping_and_keeps_compacted_real_turn(self):
        self.hermes_db([
            ("user", "status", 1, "status", 0, 1, 0),
            ("user", "[CONTEXT SUMMARY]: handoff", 2, None, 0, 1, 0),
            ("user", "real first", 3, None, 0, 0, 1),
            ("user", "rewound", 100, None, 0, 0, 0),
            ("assistant", "reply", 4, None, 0, 1, 0),
            ("user", "compressed", 200, None, 1, 1, 0)])
        items, _ = self.capture(scan.hermes)
        self.assertEqual(items[0]["first_message"], "real first")
        self.assertEqual(items[0]["last_active"], 4)
        self.assertIsNone(items[0]["cwd"])
        self.assertEqual(items[0]["origin"], "telegram")

    def test_hermes_delegate_detected_but_branch_not_assumed_internal(self):
        self.hermes_db([], config='{"_delegate_from":"parent"}')
        items, _ = self.capture(scan.hermes)
        self.assertTrue(items[0]["internal"])
        connection = sqlite3.connect(self.root / "state.db")
        connection.execute("UPDATE sessions SET model_config=?", ('{"_branched_from":"parent"}',))
        connection.commit()
        connection.close()
        items, _ = self.capture(scan.hermes)
        self.assertEqual(items[0]["internal"], "unknown")

    def test_hermes_image_first_and_empty_are_distinct(self):
        self.hermes_db([("user", [dict(type="image_url", image_url={})], 5, None, 0, 1, 0)])
        items, _ = self.capture(scan.hermes)
        self.assertFalse(items[0]["empty"])
        self.assertEqual(items[0]["first_message"], "[非文本用户消息]")

    def test_sqlite_connection_cannot_write_or_create(self):
        with self.assertRaises(FileNotFoundError):
            scan.connect(self.root / "missing.db")
        self.assertFalse((self.root / "missing.db").exists())
        self.hermes_db([])
        before = (self.root / "state.db").read_bytes()
        connection = scan.connect(self.root / "state.db")
        with self.assertRaises(sqlite3.OperationalError):
            connection.execute("DELETE FROM sessions")
        connection.close()
        self.capture(scan.hermes)
        self.assertEqual(before, (self.root / "state.db").read_bytes())

    def test_wal_without_shared_index_is_rejected_without_side_effect(self):
        self.hermes_db([])
        (self.root / "state.db-wal").write_bytes(b"unreadable")
        with self.assertRaises(RuntimeError):
            scan.connect(self.root / "state.db")
        self.assertFalse((self.root / "state.db-shm").exists())

    def test_timestamps_unknown_not_mtime_or_zero(self):
        for value in (None, "bad", "NaN", 1e100, 0, -1, "2026-01-01T00:00:00"):
            self.assertIsNone(scan.timestamp(value))
        self.assertEqual(scan.timestamp(1767225600000), 1767225600)

    def test_malformed_nested_claude_message_does_not_abort_source(self):
        self.log(self.root / "projects/p/a.jsonl", [
            dict(type="user", sessionId="session-a", message="invalid object"),
            self.claude_event(content="later")])
        items, errors = self.capture(scan.claude)
        self.assertEqual(len(items), 1)
        self.assertTrue(errors)
        self.assertIsNone(items[0]["first_message"])
        self.assertFalse(items[0]["empty"])

    def test_corruption_before_user_does_not_invent_first_message(self):
        path = self.root / "projects/p/a.jsonl"
        self.log(path, [self.claude_event(content="later user")])
        path.write_text("invalid first row\n" + path.read_text())
        items, errors = self.capture(scan.claude)
        self.assertTrue(errors)
        self.assertFalse(items[0]["empty"])
        self.assertIsNone(items[0]["first_message"])

    def test_missing_source_is_error_not_empty_success(self):
        with self.assertRaises(FileNotFoundError):
            self.capture(scan.claude)


if __name__ == "__main__":
    unittest.main()
