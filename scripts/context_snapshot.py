#!/usr/bin/env python3
"""Read the most recent observable Codex context usage, without persisting text.

A bounded tail avoids rescanning growing transcripts every five seconds. If the
last usage is outside that tail, return unknown; never substitute cumulative
usage. capturedAt is the event time, not the poll time. Even a successful result
is a last-call snapshot, not a measurement of subsequent unsent context changes.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import sqlite3
import stat

MAX_TAIL_BYTES = 4 * 1024 * 1024
SOURCE = "codex_rollout_last_usage"
RESET_TYPES = {"context_compacted", "context_cleared", "context_reset", "thread_rolled_back"}


def counter(value: object) -> int | None:
    return value if type(value) is int and 0 <= value <= 2**63 - 1 else None


def event_time(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return int(dt.timestamp()) if dt.tzinfo is not None else None
    except (ValueError, OverflowError, OSError):
        return None


def resolve_database(home: Path | None = None, database: Path | None = None) -> Path | None:
    """Choose the same read-only state source for task totals and context usage."""
    if database is not None:
        return database.expanduser().resolve()
    override = os.environ.get("CODEX_STATE_DB")
    if override:
        return Path(override).expanduser().resolve()
    home = (home or Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))).expanduser().resolve()
    candidates = [path for path in home.glob("state_*.sqlite") if path.stem[6:].isdigit()]
    return max(candidates, key=lambda path: int(path.stem[6:])) if candidates else None


def read_snapshot(thread_id: str, codex_home: Path | None = None,
                  database: Path | None = None, max_tail_bytes: int = MAX_TAIL_BYTES) -> dict:
    result = {"threadId": thread_id, "tokens": None, "window": None,
              "capturedAt": None, "source": SOURCE, "error": None}

    def unknown(reason: str) -> dict:
        result["error"] = reason
        return result

    if not thread_id or len(thread_id) > 200 or any(ord(c) < 32 for c in thread_id):
        return unknown("invalid_thread_id")
    home = (codex_home or Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))).expanduser().resolve()
    database = resolve_database(home, database)
    if database is None or not database.is_file():
        return unknown("database_missing")
    try:
        conn = sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)
        try:
            row = conn.execute("SELECT rollout_path FROM threads WHERE id = ?", (thread_id,)).fetchone()
        finally:
            conn.close()
    except (sqlite3.Error, OSError):
        return unknown("database_unavailable")
    if row is None:
        return unknown("thread_not_found")
    if not isinstance(row[0], str) or not row[0]:
        return unknown("rollout_missing")
    try:
        path = Path(row[0]).expanduser().resolve()
        allowed = [(home / folder).resolve() for folder in ("sessions", "archived_sessions")]
        if not any(path.is_relative_to(folder) for folder in allowed):
            return unknown("rollout_outside_home")
        # Do not open devices, FIFOs or other non-regular files from database paths.
        if not stat.S_ISREG(path.stat().st_mode):
            return unknown("rollout_not_regular")
        with path.open("rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            start = max(0, size - max_tail_bytes)
            handle.seek(start)
            data = handle.read(max_tail_bytes)
    except (OSError, ValueError):
        return unknown("rollout_unavailable")
    if data and not data.endswith(b"\n"):
        return unknown("rollout_incomplete")
    lines = data.splitlines()
    if start:
        lines = lines[1:]  # first line may be a truncated JSON object
    for line in reversed(lines):
        try:
            event = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            return unknown("rollout_invalid")
        if not isinstance(event, dict):
            continue
        payload = event.get("payload")
        kind = event.get("type")
        payload_type = payload.get("type") if isinstance(payload, dict) else None
        if kind == "compacted" or (kind == "event_msg" and payload_type in RESET_TYPES):
            result["capturedAt"] = event_time(event.get("timestamp"))
            return unknown("context_reset")
        if kind != "event_msg" or payload_type != "token_count":
            continue
        result["capturedAt"] = event_time(event.get("timestamp"))
        info = payload.get("info")
        if not isinstance(info, dict) or not isinstance(info.get("last_token_usage"), dict):
            return unknown("usage_unavailable")
        last = info["last_token_usage"]
        tokens = counter(last.get("total_tokens"))
        if tokens is None and "total_tokens" not in last:
            inp, out = counter(last.get("input_tokens")), counter(last.get("output_tokens"))
            if inp is not None and out is not None:
                tokens = counter(inp + out)
        window = counter(info.get("model_context_window"))
        if tokens is None or window is None or window == 0:
            return unknown("incomplete_usage")
        if result["capturedAt"] is None:
            return unknown("invalid_timestamp")
        result.update(tokens=tokens, window=window)
        return result
    return unknown("usage_not_in_tail" if start else "usage_not_found")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-id", required=True)
    args = parser.parse_args()
    print(json.dumps(read_snapshot(args.thread_id), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
