#!/usr/bin/env python3
"""Dependency-free MCP server for Token Usage Monitor."""

from __future__ import annotations

import json
import atexit
import signal
import sys
import threading
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from token_monitor import UsageMonitor  # noqa: E402


TOOLS = [
    {
        "name": "get_token_usage_summary",
        "description": "Read the latest locally recorded Codex token summary, quota windows, reset credits, and latest thread token event. Never returns prompt or response text.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "get_rate_limits",
        "description": "Read current Codex rate-limit windows, used percentages, scheduled reset times, and earned reset credits.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "get_usage_history",
        "description": "Read daily token activity recorded by Codex services for a recent date range.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer", "minimum": 1, "maximum": 365, "default": 30}},
            "additionalProperties": False,
        },
    },
    {
        "name": "get_monitor_status",
        "description": "Check collector connection, freshness, privacy mode, local database path, and notification configuration.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "refresh_usage",
        "description": "Request an immediate read-only refresh from Codex account usage and rate-limit endpoints.",
        "inputSchema": {
            "type": "object",
            "properties": {"wait_seconds": {"type": "integer", "minimum": 0, "maximum": 30, "default": 15}},
            "additionalProperties": False,
        },
    },
    {
        "name": "configure_usage_alerts",
        "description": "Configure local operating-system notifications for usage thresholds and scheduled resets. This never sends email or external messages.",
        "inputSchema": {
            "type": "object",
            "required": ["enabled", "thresholds", "reset_warning_minutes"],
            "properties": {
                "enabled": {"type": "boolean"},
                "thresholds": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": 100}, "minItems": 1},
                "reset_warning_minutes": {"type": "integer", "minimum": 0, "maximum": 1440},
            },
            "additionalProperties": False,
        },
    },
]


class MCPServer:
    def __init__(self) -> None:
        self.monitor = UsageMonitor()
        self._write_lock = threading.Lock()
        self._closing = False
        atexit.register(self.close)
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

    def _handle_signal(self, _signum: int, _frame: Any) -> None:
        self.close()
        raise SystemExit(0)

    def close(self) -> None:
        if self._closing:
            return
        self._closing = True
        self.monitor.close()

    def send(self, payload: dict[str, Any]) -> None:
        with self._write_lock:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    def result(self, request_id: Any, value: Any) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "result": value})

    def error(self, request_id: Any, code: int, message: str) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})

    def tool_result(self, request_id: Any, data: Any) -> None:
        self.result(
            request_id,
            {
                "content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False, indent=2)}],
                "structuredContent": data,
                "isError": False,
            },
        )

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        if name == "get_token_usage_summary":
            data = self.monitor.store.summary()
            data["monitor"] = self.monitor.status()
            return data
        if name == "get_rate_limits":
            summary = self.monitor.store.summary()
            return {
                "capturedAt": summary["capturedAt"],
                "rateLimits": summary["rateLimits"],
                "availableResetCredits": summary["availableResetCredits"],
                "recentEvents": self.monitor.store.recent_events(20),
            }
        if name == "get_usage_history":
            days = max(1, min(365, int(arguments.get("days", 30))))
            rows = self.monitor.store.history(days)
            return {"days": days, "dailyUsage": rows, "totalTokens": sum(row["tokens"] for row in rows)}
        if name == "get_monitor_status":
            status = self.monitor.status()
            status["recentEvents"] = self.monitor.store.recent_events(10)
            return status
        if name == "refresh_usage":
            wait_seconds = max(0, min(30, int(arguments.get("wait_seconds", 15))))
            status = self.monitor.refresh_now(wait_seconds)
            return {"status": status, "summary": self.monitor.store.summary()}
        if name == "configure_usage_alerts":
            return self.monitor.configure_alerts(
                bool(arguments["enabled"]),
                list(arguments["thresholds"]),
                int(arguments["reset_warning_minutes"]),
            )
        raise ValueError(f"Unknown tool: {name}")

    def handle(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            requested = (message.get("params") or {}).get("protocolVersion")
            self.result(
                request_id,
                {
                    "protocolVersion": requested or "2024-11-05",
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "token-usage-monitor", "version": "0.1.0"},
                    "instructions": "Read-only local Codex token and rate-limit monitoring. Never consumes reset credits.",
                },
            )
        elif method in ("notifications/initialized", "initialized"):
            return
        elif method == "ping":
            self.result(request_id, {})
        elif method == "tools/list":
            self.result(request_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = message.get("params") or {}
            try:
                self.tool_result(request_id, self.call_tool(str(params.get("name")), params.get("arguments") or {}))
            except Exception as exc:
                self.result(
                    request_id,
                    {"content": [{"type": "text", "text": str(exc)}], "isError": True},
                )
        elif request_id is not None:
            self.error(request_id, -32601, f"Method not found: {method}")

    def run(self) -> None:
        try:
            for line in sys.stdin:
                if not line.strip():
                    continue
                try:
                    self.handle(json.loads(line))
                except json.JSONDecodeError:
                    self.error(None, -32700, "Parse error")
        finally:
            self.close()


if __name__ == "__main__":
    MCPServer().run()
