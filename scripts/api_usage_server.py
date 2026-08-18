#!/usr/bin/env python3
"""Loopback-only ingestion endpoint for API token usage metadata.

The server never proxies API requests and never receives or stores API keys,
prompts, or model responses. It accepts only usage counters emitted by a client.
"""

from __future__ import annotations

import argparse
import json
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from token_monitor import UsageStore


MAX_BODY_BYTES = 1_000_000


class UsageHandler(BaseHTTPRequestHandler):
    server_version = "TokenUsageMonitor/1.1"

    @property
    def store(self) -> UsageStore:
        return self.server.store  # type: ignore[attr-defined]

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send(self, status: int, value: object) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send(200, {"ok": True, "service": "token-usage-monitor"})
            return
        if parsed.path == "/v1/usage":
            query = parse_qs(parsed.query)
            days = max(1, min(365, int(query.get("days", ["30"])[0])))
            limit = max(1, min(2000, int(query.get("limit", ["200"])[0])))
            self._send(200, {"data": self.store.api_usage_history(days, limit)})
            return
        self._send(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        if urlparse(self.path).path not in ("/v1/usage", "/v1/ingest"):
            self._send(404, {"error": "not_found"})
            return
        if not (self.headers.get("Content-Type") or "").lower().startswith("application/json"):
            self._send(415, {"error": "content_type_must_be_application_json"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send(413, {"error": "invalid_body_size"})
            return
        try:
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("JSON body must be an object")
            self._send(201, self.store.save_api_usage(payload))
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self._send(400, {"error": str(exc)})

    def do_OPTIONS(self) -> None:  # noqa: N802
        # Deliberately omit CORS headers so arbitrary web pages cannot use the
        # loopback endpoint to read or write local usage records.
        self._send(403, {"error": "browser_cross_origin_access_disabled"})


class UsageHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], store: UsageStore) -> None:
        super().__init__(address, UsageHandler)
        self.store = store


def main() -> None:
    parser = argparse.ArgumentParser(description="Local API token-usage ingestion server")
    parser.add_argument("--port", type=int, default=47821)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("port must be between 1024 and 65535")

    server = UsageHTTPServer(("127.0.0.1", args.port), UsageStore())

    def stop(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
