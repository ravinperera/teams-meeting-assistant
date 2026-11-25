"""Wire-level smoke tests for the local, read-only MCP process."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


SERVER = Path(__file__).resolve().parents[2] / "plugin/meeting-assistant/server.py"


def request(request_id, method, params=None):
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    return message


def call(request_id, name, arguments=None):
    return request(request_id, "tools/call", {"name": name, "arguments": arguments or {}})


def exchange(snapshot_path, *messages):
    environment = dict(os.environ, MEETING_ASSISTANT_SNAPSHOT=str(snapshot_path))
    payload = "".join(json.dumps(message) + "\n" for message in messages)
    completed = subprocess.run(
        [sys.executable, str(SERVER)],
        input=payload,
        text=True,
        capture_output=True,
        timeout=5,
        env=environment,
        check=True,
    )
    return [json.loads(line) for line in completed.stdout.splitlines()]


class MeetingMCPTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.snapshot = Path(self.temporary_directory.name) / "live.json"

    def write_snapshot(self, segments, partials=None, updated_at=None):
        data = {
            "version": 1,
            "active": True,
            "started_at": "2026-11-25T15:00:00Z",
            "updated_at": updated_at or datetime.now(timezone.utc).isoformat(),
            "segments": segments,
        }
        if partials is not None:
            data["partials"] = partials
        self.snapshot.write_text(json.dumps(data), encoding="utf-8")

    @staticmethod
    def segment(seq):
        return {
            "seq": seq,
            "timestamp": "2026-11-25T15:01:00Z",
            "source": "system",
            "text": f"line {seq}",
            "speaker": None,
        }

    def test_missing_snapshot_is_inactive_and_tool_surface_is_read_only(self):
        responses = exchange(
            self.snapshot,
            request(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}),
            request(2, "tools/list"),
            call(3, "get_status"),
            call(4, "get_recent_transcript"),
        )
        self.assertEqual(responses[0]["result"]["protocolVersion"], "2025-11-25")
        tools = responses[1]["result"]["tools"]
        self.assertEqual([tool["name"] for tool in tools], ["get_status", "get_recent_transcript"])
        self.assertTrue(all(tool["annotations"]["readOnlyHint"] for tool in tools))
        self.assertFalse(responses[2]["result"]["structuredContent"]["active"])
        self.assertEqual(responses[3]["result"]["structuredContent"]["segments"], [])
        self.assertFalse(self.snapshot.exists())

    def test_recent_lines_cursor_and_partials(self):
        self.write_snapshot([self.segment(seq) for seq in range(1, 4)], {"mic": "Can we", "system": "One moment"})
        before = self.snapshot.read_bytes()
        responses = exchange(
            self.snapshot,
            call(1, "get_recent_transcript", {"limit": 2}),
            call(2, "get_recent_transcript", {"after_seq": 1, "limit": 1}),
            call(3, "get_status"),
        )
        newest = responses[0]["result"]["structuredContent"]
        self.assertEqual([line["seq"] for line in newest["segments"]], [2, 3])
        self.assertEqual(newest["partials"], {"mic": "Can we", "system": "One moment"})
        self.assertEqual(newest["omitted_older"], 1)
        self.assertFalse(newest["has_more"])
        after = responses[1]["result"]["structuredContent"]
        self.assertEqual([line["seq"] for line in after["segments"]], [2])
        self.assertTrue(after["has_more"])
        self.assertEqual(after["next_seq"], 2)
        self.assertEqual(responses[2]["result"]["structuredContent"]["latest_seq"], 3)
        self.assertTrue(responses[2]["result"]["structuredContent"]["active"])
        self.assertFalse(responses[2]["result"]["structuredContent"]["stale"])
        self.assertEqual(self.snapshot.read_bytes(), before)

    def test_stale_heartbeat_is_reported_inactive(self):
        old_timestamp = (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat()
        self.write_snapshot([self.segment(1)], partials={"system": "old unfinished words"}, updated_at=old_timestamp)
        responses = exchange(self.snapshot, call(1, "get_status"), call(2, "get_recent_transcript"))
        for response in responses:
            content = response["result"]["structuredContent"]
            self.assertFalse(content["active"])
            self.assertTrue(content["stale"])
        self.assertEqual(responses[1]["result"]["structuredContent"]["partials"], {})

    def test_old_meeting_cursor_resets_for_new_session(self):
        self.write_snapshot([self.segment(1), self.segment(2)])
        response = exchange(self.snapshot, call(1, "get_recent_transcript", {"after_seq": 58}))[0]
        content = response["result"]["structuredContent"]
        self.assertTrue(content["cursor_reset"])
        self.assertEqual([line["seq"] for line in content["segments"]], [1, 2])
        self.assertEqual(content["next_seq"], 2)
        self.assertEqual(content["started_at"], "2026-11-25T15:00:00Z")

    def test_old_cursor_reports_retention_gap(self):
        self.write_snapshot([self.segment(seq) for seq in range(1, 1006)])
        response = exchange(self.snapshot, call(1, "get_recent_transcript", {"after_seq": 1, "limit": 1}))[0]
        content = response["result"]["structuredContent"]
        self.assertEqual(content["oldest_seq"], 6)
        self.assertEqual(content["segments"][0]["seq"], 6)
        self.assertTrue(content["cursor_expired"])
        self.assertEqual(content["partials"], {})

    def test_invalid_snapshot_and_invalid_arguments_return_tool_errors(self):
        self.snapshot.write_text("{broken", encoding="utf-8")
        invalid_snapshot = exchange(self.snapshot, call(1, "get_status"))[0]
        self.assertTrue(invalid_snapshot["result"]["isError"])
        self.assertEqual(invalid_snapshot["result"]["structuredContent"], {"error": "snapshot_invalid"})
        self.write_snapshot([])
        invalid_args = exchange(self.snapshot, call(1, "get_recent_transcript", {"limit": 101}))[0]
        self.assertTrue(invalid_args["result"]["isError"])
        self.assertEqual(invalid_args["result"]["structuredContent"], {"error": "invalid_limit"})


if __name__ == "__main__":
    unittest.main()
