import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "summary_read", Path(__file__).resolve().parents[1] / "ashub-summary-read.py")
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)


class SummaryReadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def log(self, records, name="session.jsonl"):
        path = self.root / name
        path.write_text("\n".join(json.dumps(row) for row in records), encoding="utf-8")
        return path

    def test_claude_full_text_tool_evidence_no_reasoning(self):
        middle = "中间推翻最初方案" * 30000
        path = self.log([
            {"sessionId": "s", "type": "user", "message": {"role": "user", "content": "修复恢复失败"}},
            {"sessionId": "s", "type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "hidden private reasoning"},
                {"type": "text", "text": middle},
                {"type": "tool_use", "id": "call1", "name": "bash", "input": {"command": "make check"}}]}},
            {"sessionId": "s", "type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "call1", "content": "115 tests passed"}]}},
        ])
        text = summary.read_session("claude", self.root, "s", path)
        self.assertIn(middle, text)
        self.assertIn("make check", text)
        self.assertIn("115 tests passed", text)
        self.assertNotIn("hidden private reasoning", text)
        self.assertGreater(len(text), 200000)

    def test_metadata_only_does_not_change_canonical_text(self):
        rows = [{"sessionId": "s", "timestamp": "old", "cwd": "/old",
                 "message": {"role": "user", "content": "主题"}}]
        path = self.log(rows)
        before = summary.read_session("claude", self.root, "s", path)
        rows[0].update(timestamp="new", cwd="/new")
        self.log(rows)
        self.assertEqual(before, summary.read_session("claude", self.root, "s", path))

    def test_pi_active_branch_and_tools(self):
        path = self.log([
            {"type": "session", "id": "s", "version": 3},
            {"type": "message", "id": "u", "parentId": None,
             "message": {"role": "user", "content": "修复问题"}},
            {"type": "message", "id": "abandoned", "parentId": "u",
             "message": {"role": "assistant", "content": "错误分支已经成功"}},
            {"type": "message", "id": "a", "parentId": "u",
             "message": {"role": "assistant", "content": "最终方案仍待测试"}},
            {"type": "message", "id": "tool", "parentId": "a",
             "message": {"role": "toolResult", "toolName": "bash", "isError": True,
                         "content": [{"type": "text", "text": "tests failed"}]}},
        ])
        text = summary.read_session("pi", self.root, "s", path)
        self.assertNotIn("错误分支", text)
        self.assertIn("最终方案", text)
        self.assertIn("tests failed", text)
        self.assertIn('"isError":true', text)

    def test_pi_broken_branch_fails_closed(self):
        path = self.log([{"type": "session", "id": "s"},
                         {"type": "message", "id": "m", "parentId": "missing",
                          "message": {"role": "user", "content": "hello"}}])
        with self.assertRaisesRegex(ValueError, "Broken"):
            summary.read_session("pi", self.root, "s", path)

    def test_codex_response_items_do_not_duplicate_event_messages(self):
        path = self.log([
            {"type": "session_meta", "payload": {"id": "s"}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "修复"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                     "content": [{"type": "input_text", "text": "修复"}]}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command",
                                                     "arguments": '{"cmd":"make test"}'}},
            {"type": "response_item", "payload": {"type": "function_call_output", "output": "passed"}},
            {"type": "response_item", "payload": {"type": "reasoning", "summary": "secret"}},
        ])
        text = summary.read_session("codex", self.root, "s", path)
        self.assertEqual(text.count("修复"), 1)
        self.assertIn("make test", text)
        self.assertIn("passed", text)
        self.assertNotIn("secret", text)

    def test_codex_database_keeps_tool_items(self):
        db = sqlite3.connect(self.root / "thread_history_1.sqlite")
        db.executescript("""
            CREATE TABLE thread_items(thread_id, turn_id, item_type, item_json, ordinal);
            CREATE TABLE thread_turns(thread_id, turn_id, rollout_ordinal);
            INSERT INTO thread_turns VALUES ('s', 't', 0);
        """)
        for i, (kind, item) in enumerate([
                ("userMessage", {"content": [{"type": "input_text", "text": "修复"}]}),
                ("commandExecution", {"command": "make check", "aggregatedOutput": "passed"}),
                ("agentMessage", {"text": "修复已通过测试"})]):
            db.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?, ?)",
                       ("s", "t", kind, json.dumps(item), i))
        db.commit()
        db.close()
        text = summary.read_session("codex", self.root, "s")
        self.assertIn("make check", text)
        self.assertIn("passed", text)

    def test_codex_event_user_is_kept_when_only_assistant_has_response_items(self):
        path = self.log([
            {"type": "session_meta", "payload": {"id": "s"}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "真实用户问题"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                     "content": [{"type": "output_text", "text": "仍待验证"}]}},
        ])
        text = summary.read_session("codex", self.root, "s", path)
        self.assertIn("真实用户问题", text)
        self.assertIn("仍待验证", text)

    def test_codex_prefers_full_db_but_detects_later_cli_turns(self):
        db = sqlite3.connect(self.root / "thread_history_1.sqlite")
        db.executescript("""
            CREATE TABLE thread_items(thread_id, turn_id, item_type, item_json, ordinal);
            CREATE TABLE thread_turns(thread_id, turn_id, rollout_ordinal);
            INSERT INTO thread_turns VALUES ('s', 't', 0);
        """)
        for i, (role, text) in enumerate([("userMessage", "q1"), ("agentMessage", "a1"),
                                          ("userMessage", "q2"), ("agentMessage", "fresh DB result")]):
            db.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?, ?)",
                       ("s", "t", role, json.dumps({"text": text}), i))
        db.commit()
        db.close()
        rows = [{"type": "session_meta", "payload": {"id": "s"}},
                {"type": "response_item", "payload": {"type": "message", "role": "user", "content": "q1"}}]
        path = self.log(rows)
        self.assertIn("fresh DB result", summary.read_session("codex", self.root, "s", path))
        rows.extend({"type": "response_item", "payload": {"type": "message", "role": role, "content": text}}
                    for role, text in [("assistant", "a1"), ("user", "q2"),
                                       ("assistant", "fresh DB result"), ("user", "q3"),
                                       ("assistant", "latest CLI result")])
        self.log(rows)
        self.assertIn("latest CLI result", summary.read_session("codex", self.root, "s", path))

    def test_database_revision_is_per_session_and_includes_tools(self):
        db = sqlite3.connect(self.root / "state.db")
        db.executescript("""
            CREATE TABLE sessions(id);
            INSERT INTO sessions VALUES ('a');
            INSERT INTO sessions VALUES ('b');
            CREATE TABLE messages(session_id, role, content, timestamp);
            INSERT INTO messages VALUES ('a', 'user', 'fix a', 1);
            INSERT INTO messages VALUES ('a', 'tool', 'failed', 2);
            INSERT INTO messages VALUES ('b', 'user', 'fix b', 1);
        """)
        db.commit()
        scanner = Path(__file__).resolve().parents[1] / "ashub-scan.py"

        def revisions():
            result = subprocess.run([sys.executable, "-B", str(scanner), "hermes", str(self.root)],
                                    check=True, capture_output=True, text=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            return {r["item"]["id"]: r["item"]["summary_revision"] for r in rows if r["kind"] == "item"}

        before = revisions()
        db.execute("UPDATE messages SET content='tests passed' WHERE session_id='a' AND role='tool'")
        db.commit()
        after = revisions()
        db.close()
        self.assertNotEqual(before["a"], after["a"])
        self.assertEqual(before["b"], after["b"])

    def test_hermes_full_messages_and_tool_results(self):
        db = sqlite3.connect(self.root / "state.db")
        db.executescript("CREATE TABLE messages(session_id, role, content, timestamp, tool_calls, active, compacted);")
        db.executemany("INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?, ?)", [
            ("s", "user", "修复", 1, None, 1, 0),
            ("s", "assistant", '[{"type":"text","text":"已调整代码"}]', 2,
             '[{"function":{"name":"bash","arguments":"make check"}}]', 1, 0),
            ("s", "tool", "tests passed", 3, None, 1, 0),
            ("s", "assistant", "abandoned branch", 4, None, 0, 0),
        ])
        db.commit()
        db.close()
        text = summary.read_session("hermes", self.root, "s")
        self.assertIn("make check", text)
        self.assertIn("tests passed", text)
        self.assertIn("已调整代码", text)
        self.assertNotIn("abandoned branch", text)

    def test_reject_malformed_identity_symlink_and_escape(self):
        path = self.log([{"sessionId": "other", "message": {"role": "user", "content": "hi"}}])
        with self.assertRaisesRegex(ValueError, "identity"):
            summary.read_session("claude", self.root, "s", path)
        path.write_text('{"sessionId":', encoding="utf-8")
        with self.assertRaises(ValueError):
            summary.read_session("claude", self.root, "s", path)
        link = self.root / "link.jsonl"
        link.symlink_to(path)
        with self.assertRaises(ValueError):
            summary.read_session("claude", self.root, "s", link)
        with tempfile.TemporaryDirectory() as other:
            outside = Path(other) / "out.jsonl"
            outside.write_text('{}\n', encoding="utf-8")
            with self.assertRaises(ValueError):
                summary.read_session("claude", self.root, "s", outside)


if __name__ == "__main__":
    unittest.main()
