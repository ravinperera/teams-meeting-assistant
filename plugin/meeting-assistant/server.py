#!/usr/bin/env python3
"""Read a local Meeting Assistant snapshot over MCP stdio.

This process has no audio capture, Teams access, or write operations.
"""

from __future__ import annotations

import json
import os
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SERVER_VERSION = "0.1.1"
PROTOCOL_VERSION = "2025-11-25"
SUPPORTED_VERSIONS = {"2025-03-26", "2025-06-18", PROTOCOL_VERSION}
MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024
MAX_RETAINED_SEGMENTS = 1000
DEFAULT_LIMIT = 20
MAX_LIMIT = 100
MAX_TEXT_LENGTH = 4000
STALE_AFTER_SECONDS = 20
SNAPSHOT_ENV = "MEETING_ASSISTANT_SNAPSHOT"

TOOLS = [
    {
        "name": "get_status",
        "description": "Read local meeting capture status and transcript cursor.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "get_recent_transcript",
        "description": (
            "Read finalized local transcript lines and current partial speech. "
            "With after_seq, return the oldest available lines after that cursor; "
            "without it, return the newest lines."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "after_seq": {
                    "type": "integer",
                    "minimum": 0,
                    "description": "Last finalized sequence number already seen.",
                },
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_LIMIT,
                    "default": DEFAULT_LIMIT,
                    "description": "Maximum finalized lines to return.",
                },
            },
            "additionalProperties": False,
        },
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
]


class SnapshotError(Exception):
    """Snapshot is unreadable or does not match the local data contract."""


def _snapshot_path() -> Path:
    configured = os.environ.get(SNAPSHOT_ENV)
    if configured:
        return Path(configured).expanduser()
    return Path.home() / "Library/Application Support/MeetingAssistant/live.json"


def _read_snapshot() -> dict[str, Any]:
    path = _snapshot_path()
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return {
            "version": 1,
            "active": False,
            "started_at": None,
            "updated_at": None,
            "segments": [],
            "partials": {},
        }
    except OSError as error:
        raise SnapshotError("snapshot_unreadable") from error

    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_size > MAX_SNAPSHOT_BYTES:
            raise SnapshotError("snapshot_invalid")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            raw = handle.read(MAX_SNAPSHOT_BYTES + 1)
        if len(raw) > MAX_SNAPSHOT_BYTES:
            raise SnapshotError("snapshot_invalid")
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    try:
        snapshot = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SnapshotError("snapshot_invalid") from error
    if not isinstance(snapshot, dict) or snapshot.get("version") != 1:
        raise SnapshotError("snapshot_invalid")
    if type(snapshot.get("active")) is not bool:
        raise SnapshotError("snapshot_invalid")
    for field in ("started_at", "updated_at"):
        if snapshot.get(field) is not None and not isinstance(snapshot.get(field), str):
            raise SnapshotError("snapshot_invalid")
    segments = snapshot.get("segments")
    if not isinstance(segments, list):
        raise SnapshotError("snapshot_invalid")
    retained = segments[-MAX_RETAINED_SEGMENTS:]
    normalized = []
    previous_seq = -1
    for segment in retained:
        if not isinstance(segment, dict):
            raise SnapshotError("snapshot_invalid")
        seq = segment.get("seq")
        if type(seq) is not int or seq < 1 or seq <= previous_seq:
            raise SnapshotError("snapshot_invalid")
        previous_seq = seq
        timestamp = segment.get("timestamp")
        source = segment.get("source")
        utterance = segment.get("text")
        speaker = segment.get("speaker")
        if (
            not isinstance(timestamp, str)
            or source not in ("mic", "system")
            or not isinstance(utterance, str)
            or (speaker is not None and not isinstance(speaker, str))
        ):
            raise SnapshotError("snapshot_invalid")
        normalized.append(
            {
                "seq": seq,
                "timestamp": timestamp,
                "source": source,
                "text": utterance[:MAX_TEXT_LENGTH],
                "speaker": speaker,
            }
        )
    partials = snapshot.get("partials", {})
    if not isinstance(partials, dict):
        raise SnapshotError("snapshot_invalid")
    normalized_partials = {}
    for source in ("mic", "system"):
        value = partials.get(source)
        if isinstance(value, str) and value:
            normalized_partials[source] = value[:MAX_TEXT_LENGTH]
    return {
        "version": 1,
        "active": snapshot["active"],
        "started_at": snapshot.get("started_at"),
        "updated_at": snapshot.get("updated_at"),
        "segments": normalized,
        "partials": normalized_partials,
    }


def _activity(snapshot: dict[str, Any]) -> tuple[bool, bool]:
    if not snapshot["active"]:
        return False, False
    updated_at = snapshot["updated_at"]
    if not updated_at:
        return False, True
    try:
        updated = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
    except ValueError:
        return False, True
    if updated.tzinfo is None:
        return False, True
    stale = (datetime.now(timezone.utc) - updated).total_seconds() > STALE_AFTER_SECONDS
    return not stale, stale


def _status(snapshot: dict[str, Any]) -> dict[str, Any]:
    segments = snapshot["segments"]
    active, stale = _activity(snapshot)
    return {
        "active": active,
        "stale": stale,
        "started_at": snapshot["started_at"],
        "updated_at": snapshot["updated_at"],
        "oldest_seq": segments[0]["seq"] if segments else 0,
        "latest_seq": segments[-1]["seq"] if segments else 0,
        "retained_segment_count": len(segments),
    }


def _recent(snapshot: dict[str, Any], arguments: Any) -> dict[str, Any]:
    if not isinstance(arguments, dict) or set(arguments) - {"after_seq", "limit"}:
        raise ValueError("invalid_arguments")
    limit = arguments.get("limit", DEFAULT_LIMIT)
    after_seq = arguments.get("after_seq")
    if type(limit) is not int or not 1 <= limit <= MAX_LIMIT:
        raise ValueError("invalid_limit")
    if after_seq is not None and (type(after_seq) is not int or after_seq < 0):
        raise ValueError("invalid_after_seq")

    retained = snapshot["segments"]
    oldest_seq = retained[0]["seq"] if retained else 0
    latest_seq = retained[-1]["seq"] if retained else 0
    cursor_reset = after_seq is not None and after_seq > latest_seq
    if after_seq is None:
        selected = retained[-limit:]
        has_more = False
        omitted_older = max(0, len(retained) - limit)
    elif cursor_reset:
        selected = retained[:limit]
        has_more = len(retained) > limit
        omitted_older = 0
    else:
        newer = [segment for segment in retained if segment["seq"] > after_seq]
        selected = newer[:limit]
        has_more = len(newer) > limit
        omitted_older = 0
    active, stale = _activity(snapshot)
    return {
        "active": active,
        "stale": stale,
        "started_at": snapshot["started_at"],
        "updated_at": snapshot["updated_at"],
        "oldest_seq": oldest_seq,
        "latest_seq": latest_seq,
        "next_seq": selected[-1]["seq"] if selected else (0 if cursor_reset else (after_seq or latest_seq)),
        "has_more": has_more,
        "omitted_older": omitted_older,
        "cursor_reset": cursor_reset,
        "cursor_expired": after_seq is not None and oldest_seq > 0 and after_seq < oldest_seq - 1,
        "segments": selected,
        "partials": snapshot["partials"] if active else {},
    }


def _tool_result(payload: dict[str, Any], is_error: bool = False) -> dict[str, Any]:
    result: dict[str, Any] = {
        "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}],
        "structuredContent": payload,
    }
    if is_error:
        result["isError"] = True
    return result


def _dispatch(message: Any) -> dict[str, Any] | None:
    if not isinstance(message, dict):
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
    request_id = message.get("id")
    method = message.get("method")
    if not isinstance(method, str):
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32600, "message": "Invalid Request"}}
    if "id" not in message:
        return None  # Client notifications need no response.
    if method == "initialize":
        params = message.get("params", {})
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        negotiated = requested if isinstance(requested, str) and requested in SUPPORTED_VERSIONS else PROTOCOL_VERSION
        result = {
            "protocolVersion": negotiated,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "meeting-assistant-local", "version": SERVER_VERSION},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = message.get("params")
        if not isinstance(params, dict):
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Invalid params"}}
        name = params.get("name")
        try:
            snapshot = _read_snapshot()
            if name == "get_status":
                arguments = params.get("arguments", {})
                if arguments != {}:
                    raise ValueError("invalid_arguments")
                result = _tool_result(_status(snapshot))
            elif name == "get_recent_transcript":
                result = _tool_result(_recent(snapshot, params.get("arguments", {})))
            else:
                result = _tool_result({"error": "unknown_tool"}, is_error=True)
        except SnapshotError as error:
            result = _tool_result({"error": str(error)}, is_error=True)
        except ValueError as error:
            result = _tool_result({"error": str(error)}, is_error=True)
    else:
        return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}}
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def main() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
            response = _dispatch(message)
        except json.JSONDecodeError:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
