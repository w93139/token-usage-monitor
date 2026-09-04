#!/usr/bin/env python3
"""Local Codex token and rate-limit monitor.

Only usage metadata is persisted. Prompt and response text are never requested or stored.
"""

from __future__ import annotations

import json
import os
import platform
import queue
import shutil
import sqlite3
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable


PLUGIN_VERSION = "0.1.0"


def _now() -> int:
    return int(time.time())


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def default_data_dir() -> Path:
    override = os.environ.get("TOKEN_USAGE_MONITOR_HOME")
    if override:
        return Path(override).expanduser().resolve()
    if platform.system() == "Darwin":
        return Path.home() / "Library" / "Application Support" / "Token Usage Monitor"
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "token-usage-monitor"


def find_codex_binary() -> str | None:
    override = os.environ.get("CODEX_BINARY")
    if override and Path(override).expanduser().is_file():
        return str(Path(override).expanduser())
    found = shutil.which("codex")
    if found:
        return found
    candidates = list((Path.home() / ".nvm" / "versions" / "node").glob("*/bin/codex"))
    candidates += [Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex")]
    existing = [path for path in candidates if path.is_file()]
    return str(sorted(existing)[-1]) if existing else None


class UsageStore:
    def __init__(self, data_dir: Path | None = None) -> None:
        self.data_dir = data_dir or default_data_dir()
        self.data_dir.mkdir(parents=True, exist_ok=True)
        try:
            self.data_dir.chmod(0o700)
        except OSError:
            pass
        self.db_path = self.data_dir / "usage.sqlite3"
        self.log_path = self.data_dir / "monitor.log"
        self._lock = threading.RLock()
        self._init_db()
        for path in (self.db_path, self.log_path):
            if path.exists():
                try:
                    path.chmod(0o600)
                except OSError:
                    pass

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _init_db(self) -> None:
        schema = """
        CREATE TABLE IF NOT EXISTS usage_snapshots (
            captured_at INTEGER PRIMARY KEY,
            lifetime_tokens INTEGER,
            peak_daily_tokens INTEGER,
            longest_running_turn_sec INTEGER,
            current_streak_days INTEGER,
            longest_streak_days INTEGER,
            raw_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS daily_usage (
            start_date TEXT PRIMARY KEY,
            tokens INTEGER NOT NULL,
            captured_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rate_limit_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at INTEGER NOT NULL,
            limit_id TEXT NOT NULL,
            window_name TEXT NOT NULL,
            used_percent REAL,
            window_duration_mins INTEGER,
            resets_at INTEGER,
            raw_json TEXT NOT NULL,
            UNIQUE(captured_at, limit_id, window_name)
        );
        CREATE TABLE IF NOT EXISTS reset_credits (
            credit_id TEXT PRIMARY KEY,
            status TEXT,
            granted_at INTEGER,
            expires_at INTEGER,
            title TEXT,
            description TEXT,
            last_seen_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS thread_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at INTEGER NOT NULL,
            thread_id TEXT,
            input_tokens INTEGER,
            cached_input_tokens INTEGER,
            output_tokens INTEGER,
            reasoning_tokens INTEGER,
            total_tokens INTEGER,
            raw_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS api_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at INTEGER NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            task_name TEXT,
            request_id TEXT,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            cached_input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'response',
            UNIQUE(provider, request_id)
        );
        CREATE INDEX IF NOT EXISTS idx_api_usage_captured_at ON api_usage(captured_at DESC);
        CREATE INDEX IF NOT EXISTS idx_api_usage_provider_model ON api_usage(provider, model);
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            captured_at INTEGER NOT NULL,
            event_type TEXT NOT NULL,
            message TEXT NOT NULL,
            raw_json TEXT
        );
        CREATE TABLE IF NOT EXISTS state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        with self._lock, self._connect() as conn:
            conn.executescript(schema)

    def log(self, message: str) -> None:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with self._lock:
            with self.log_path.open("a", encoding="utf-8") as handle:
                handle.write(f"{stamp} {message}\n")

    def get_state(self, key: str, default: str | None = None) -> str | None:
        with self._lock, self._connect() as conn:
            row = conn.execute("SELECT value FROM state WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default

    def set_state(self, key: str, value: Any) -> None:
        rendered = value if isinstance(value, str) else _json(value)
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO state(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, rendered),
            )

    def swap_state(self, key: str, value: Any, default: str | None = None) -> str | None:
        """Atomically replace shared state and return its previous value."""
        rendered = value if isinstance(value, str) else _json(value)
        with self._lock, self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT value FROM state WHERE key = ?", (key,)).fetchone()
            previous = row["value"] if row else default
            conn.execute(
                "INSERT INTO state(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, rendered),
            )
        return previous

    def add_event(self, event_type: str, message: str, raw: Any = None) -> None:
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO events(captured_at, event_type, message, raw_json) VALUES(?, ?, ?, ?)",
                (_now(), event_type, message, _json(raw) if raw is not None else None),
            )

    def save_usage(self, result: dict[str, Any]) -> None:
        captured = _now()
        summary = result.get("summary") or {}
        buckets = result.get("dailyUsageBuckets") or []
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO usage_snapshots VALUES(?, ?, ?, ?, ?, ?, ?)",
                (
                    captured,
                    summary.get("lifetimeTokens"),
                    summary.get("peakDailyTokens"),
                    summary.get("longestRunningTurnSec"),
                    summary.get("currentStreakDays"),
                    summary.get("longestStreakDays"),
                    _json(result),
                ),
            )
            for bucket in buckets:
                if bucket.get("startDate") and bucket.get("tokens") is not None:
                    conn.execute(
                        "INSERT INTO daily_usage(start_date, tokens, captured_at) VALUES(?, ?, ?) "
                        "ON CONFLICT(start_date) DO UPDATE SET tokens = excluded.tokens, captured_at = excluded.captured_at",
                        (bucket["startDate"], int(bucket["tokens"]), captured),
                    )

    @staticmethod
    def flatten_rate_limits(result: dict[str, Any]) -> list[dict[str, Any]]:
        groups = result.get("rateLimitsByLimitId")
        if not groups:
            single = result.get("rateLimits")
            groups = {str((single or {}).get("limitId") or "codex"): single} if single else {}
        rows: list[dict[str, Any]] = []
        for limit_id, payload in groups.items():
            if not payload:
                continue
            for window_name in ("primary", "secondary"):
                window = payload.get(window_name)
                if not window:
                    continue
                rows.append(
                    {
                        "limitId": str(payload.get("limitId") or limit_id),
                        "limitName": payload.get("limitName"),
                        "windowName": window_name,
                        "usedPercent": window.get("usedPercent"),
                        "windowDurationMins": window.get("windowDurationMins"),
                        "resetsAt": window.get("resetsAt"),
                        "rateLimitReachedType": payload.get("rateLimitReachedType"),
                    }
                )
        return rows

    def save_rate_limits(self, result: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
        captured = _now()
        rows = self.flatten_rate_limits(result)
        credit_info = result.get("rateLimitResetCredits") or {}
        credits = credit_info.get("credits") or []
        with self._lock, self._connect() as conn:
            for row in rows:
                conn.execute(
                    "INSERT OR REPLACE INTO rate_limit_snapshots "
                    "(captured_at, limit_id, window_name, used_percent, window_duration_mins, resets_at, raw_json) "
                    "VALUES(?, ?, ?, ?, ?, ?, ?)",
                    (
                        captured,
                        row["limitId"],
                        row["windowName"],
                        row["usedPercent"],
                        row["windowDurationMins"],
                        row["resetsAt"],
                        _json(row),
                    ),
                )
            for credit in credits:
                credit_id = credit.get("id")
                if not credit_id:
                    continue
                conn.execute(
                    "INSERT INTO reset_credits VALUES(?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(credit_id) DO UPDATE SET status=excluded.status, expires_at=excluded.expires_at, last_seen_at=excluded.last_seen_at",
                    (
                        credit_id,
                        credit.get("status"),
                        credit.get("grantedAt"),
                        credit.get("expiresAt"),
                        credit.get("title"),
                        credit.get("description"),
                        captured,
                    ),
                )
        return rows, credits

    def save_thread_usage(self, params: dict[str, Any]) -> None:
        usage = params.get("usage") if isinstance(params.get("usage"), dict) else params
        values = {
            "input": usage.get("inputTokens", usage.get("input_tokens")),
            "cached": usage.get("cachedInputTokens", usage.get("cached_input_tokens")),
            "output": usage.get("outputTokens", usage.get("output_tokens")),
            "reasoning": usage.get("reasoningTokens", usage.get("reasoning_tokens")),
            "total": usage.get("totalTokens", usage.get("total_tokens")),
        }
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO thread_usage(captured_at, thread_id, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, total_tokens, raw_json) "
                "VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    _now(),
                    params.get("threadId") or params.get("thread_id"),
                    values["input"], values["cached"], values["output"], values["reasoning"], values["total"],
                    _json(params),
                ),
            )

    def save_api_usage(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Persist token counts from an API response without storing request/response text."""
        usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else payload
        provider = str(payload.get("provider") or "custom").strip().lower()[:64]
        model = str(payload.get("model") or usage.get("model") or "unknown").strip()[:128]
        task_name_raw = payload.get("taskName", payload.get("task_name"))
        task_name = str(task_name_raw).strip()[:280] if task_name_raw else None
        request_id_raw = payload.get("requestId", payload.get("request_id", payload.get("id")))
        request_id = str(request_id_raw).strip()[:200] if request_id_raw else None

        input_details = usage.get("input_tokens_details") or usage.get("prompt_tokens_details") or {}
        output_details = usage.get("output_tokens_details") or usage.get("completion_tokens_details") or {}
        input_tokens = int(usage.get("input_tokens", usage.get("prompt_tokens", 0)) or 0)
        cached_tokens = int(
            usage.get("cached_input_tokens", usage.get("prompt_cache_hit_tokens", input_details.get("cached_tokens", 0))) or 0
        )
        output_tokens = int(usage.get("output_tokens", usage.get("completion_tokens", 0)) or 0)
        reasoning_tokens = int(
            usage.get("reasoning_tokens", output_details.get("reasoning_tokens", output_details.get("reasoning_output_tokens", 0))) or 0
        )
        total_tokens = int(usage.get("total_tokens", usage.get("totalTokens", input_tokens + output_tokens)) or 0)
        values = [input_tokens, cached_tokens, output_tokens, reasoning_tokens, total_tokens]
        if any(value < 0 for value in values):
            raise ValueError("Token counts must be non-negative")
        if total_tokens == 0 and input_tokens == 0 and output_tokens == 0:
            raise ValueError("At least one token count is required")

        captured_at = int(payload.get("capturedAt", payload.get("captured_at", _now())) or _now())
        source = str(payload.get("source") or "response").strip()[:64]
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT OR IGNORE INTO api_usage "
                "(captured_at, provider, model, task_name, request_id, input_tokens, cached_input_tokens, "
                "output_tokens, reasoning_tokens, total_tokens, source) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    captured_at, provider, model, task_name, request_id, input_tokens, cached_tokens,
                    output_tokens, reasoning_tokens, total_tokens, source,
                ),
            )
            inserted = cursor.rowcount > 0
        return {
            "recorded": inserted,
            "provider": provider,
            "model": model,
            "taskName": task_name,
            "requestId": request_id,
            "inputTokens": input_tokens,
            "cachedInputTokens": cached_tokens,
            "outputTokens": output_tokens,
            "reasoningTokens": reasoning_tokens,
            "totalTokens": total_tokens,
            "capturedAt": captured_at,
        }

    def api_usage_history(self, days: int = 30, limit: int = 200) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                "SELECT id, captured_at, provider, model, task_name, request_id, input_tokens, "
                "cached_input_tokens, output_tokens, reasoning_tokens, total_tokens, source "
                "FROM api_usage WHERE captured_at >= strftime('%s', 'now', ?) "
                "ORDER BY captured_at DESC, id DESC LIMIT ?",
                (f"-{max(0, days - 1)} days", max(1, min(2000, limit))),
            ).fetchall()
        return [dict(row) for row in rows]

    def codex_task_history(self, limit: int = 100) -> list[dict[str, Any]]:
        override = os.environ.get("CODEX_STATE_DB")
        if override:
            database = Path(override).expanduser()
        else:
            candidates = sorted((Path.home() / ".codex").glob("state_*.sqlite"), reverse=True)
            if not candidates:
                return []
            database = candidates[0]
        if not database.is_file():
            return []
        query = """
            SELECT id,
                   SUBSTR(COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(title), ''), '未命名任务'), 1, 280) AS title,
                   tokens_used AS tokens,
                   created_at,
                   updated_at,
                   NULLIF(model, '') AS model,
                   archived
            FROM threads
            WHERE tokens_used > 0
              AND thread_source = 'user'
              AND agent_role IS NULL
              AND id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)
            ORDER BY updated_at DESC
            LIMIT ?
        """
        connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=5)
        connection.row_factory = sqlite3.Row
        try:
            rows = connection.execute(query, (max(1, min(1000, limit)),)).fetchall()
        finally:
            connection.close()
        return [dict(row) for row in rows]

    def summary(self) -> dict[str, Any]:
        with self._lock, self._connect() as conn:
            usage = conn.execute("SELECT * FROM usage_snapshots ORDER BY captured_at DESC LIMIT 1").fetchone()
            latest_rate_time = conn.execute("SELECT MAX(captured_at) AS value FROM rate_limit_snapshots").fetchone()["value"]
            rates = []
            if latest_rate_time is not None:
                rates = conn.execute(
                    "SELECT limit_id, window_name, used_percent, window_duration_mins, resets_at "
                    "FROM rate_limit_snapshots WHERE captured_at = ? ORDER BY limit_id, window_name",
                    (latest_rate_time,),
                ).fetchall()
            credits = conn.execute(
                "SELECT credit_id, status, granted_at, expires_at, title, description "
                "FROM reset_credits WHERE status IS NULL OR status = 'available' ORDER BY granted_at DESC"
            ).fetchall()
            thread = conn.execute(
                "SELECT captured_at, thread_id, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, total_tokens "
                "FROM thread_usage ORDER BY captured_at DESC LIMIT 1"
            ).fetchone()
        return {
            "capturedAt": usage["captured_at"] if usage else None,
            "accountUsage": {
                "lifetimeTokens": usage["lifetime_tokens"],
                "peakDailyTokens": usage["peak_daily_tokens"],
                "longestRunningTurnSec": usage["longest_running_turn_sec"],
                "currentStreakDays": usage["current_streak_days"],
                "longestStreakDays": usage["longest_streak_days"],
            } if usage else None,
            "rateLimits": [dict(row) for row in rates],
            "availableResetCredits": [dict(row) for row in credits],
            "latestThreadUsage": dict(thread) if thread else None,
        }

    def history(self, days: int) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                "SELECT start_date, tokens, captured_at FROM daily_usage "
                "WHERE start_date >= date('now', ?) ORDER BY start_date",
                (f"-{max(0, days - 1)} days",),
            ).fetchall()
        return [dict(row) for row in rows]

    def recent_events(self, limit: int = 20) -> list[dict[str, Any]]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                "SELECT captured_at, event_type, message FROM events ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]


class LocalNotifier:
    def __init__(self, store: UsageStore) -> None:
        self.store = store

    def enabled(self) -> bool:
        env_disabled = os.environ.get("TOKEN_USAGE_MONITOR_DISABLE_NOTIFICATIONS") == "1"
        return not env_disabled and self.store.get_state("notifications.enabled", "true") == "true"

    def send(self, title: str, body: str) -> bool:
        if not self.enabled():
            return False
        try:
            if platform.system() == "Darwin" and shutil.which("osascript"):
                script = 'on run argv\n display notification (item 2 of argv) with title (item 1 of argv)\nend run'
                subprocess.run(["osascript", "-e", script, title[:80], body[:240]], timeout=5, check=False)
                return True
            if shutil.which("notify-send"):
                subprocess.run(["notify-send", title[:80], body[:240]], timeout=5, check=False)
                return True
        except Exception as exc:  # notification failure must never stop collection
            self.store.log(f"notification error: {exc}")
        return False


class AppServerClient:
    def __init__(self, store: UsageStore, on_notification: Callable[[dict[str, Any]], None]) -> None:
        self.store = store
        self.on_notification = on_notification
        self.process: subprocess.Popen[str] | None = None
        self._reader: threading.Thread | None = None
        self._pending: dict[int, queue.Queue[dict[str, Any]]] = {}
        self._pending_lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._next_id = 1
        self.mode: str | None = None
        self._log_handle: Any = None

    def start(self) -> None:
        binary = find_codex_binary()
        if not binary:
            raise RuntimeError("Codex CLI was not found; set CODEX_BINARY to its full path")
        errors: list[str] = []
        for mode, args in (("daemon-proxy", [binary, "app-server", "proxy"]), ("standalone", [binary, "app-server", "--stdio"])):
            try:
                self._spawn(args, mode)
                self.request(
                    "initialize",
                    {"clientInfo": {"name": "token_usage_monitor", "title": "Token监测", "version": PLUGIN_VERSION}},
                    timeout=12,
                )
                self.notify("initialized", {})
                self.mode = mode
                return
            except Exception as exc:
                errors.append(f"{mode}: {exc}")
                self.close()
        raise RuntimeError("; ".join(errors))

    def _spawn(self, args: list[str], mode: str) -> None:
        self._log_handle = self.store.log_path.open("a", encoding="utf-8")
        try:
            self.store.log_path.chmod(0o600)
        except OSError:
            pass
        self.process = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._log_handle,
            text=True,
            bufsize=1,
            env=os.environ.copy(),
        )
        self._reader = threading.Thread(target=self._read_loop, name=f"app-server-{mode}", daemon=True)
        self._reader.start()

    def _read_loop(self) -> None:
        process = self.process
        if not process or not process.stdout:
            return
        for line in process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.store.log("ignored non-JSON app-server output")
                continue
            request_id = message.get("id")
            if request_id is not None:
                with self._pending_lock:
                    waiter = self._pending.get(int(request_id))
                if waiter:
                    waiter.put(message)
                elif message.get("method"):
                    self._respond_unknown_request(message)
            elif message.get("method"):
                self.on_notification(message)

    def _respond_unknown_request(self, message: dict[str, Any]) -> None:
        self._send({"id": message["id"], "error": {"code": -32601, "message": "Client method not supported"}})

    def _send(self, message: dict[str, Any]) -> None:
        process = self.process
        if not process or process.poll() is not None or not process.stdin:
            raise RuntimeError("app-server is not running")
        with self._write_lock:
            process.stdin.write(_json(message) + "\n")
            process.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None, timeout: float = 15) -> dict[str, Any]:
        with self._pending_lock:
            request_id = self._next_id
            self._next_id += 1
            waiter: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=1)
            self._pending[request_id] = waiter
        try:
            payload: dict[str, Any] = {"method": method, "id": request_id}
            if params is not None:
                payload["params"] = params
            self._send(payload)
            response = waiter.get(timeout=timeout)
            if response.get("error"):
                error = response["error"]
                raise RuntimeError(str(error.get("message") or error))
            return response.get("result") or {}
        finally:
            with self._pending_lock:
                self._pending.pop(request_id, None)

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self._send({"method": method, "params": params})

    def close(self) -> None:
        process, self.process = self.process, None
        if not process:
            return
        try:
            if process.stdin:
                process.stdin.close()
            process.terminate()
            process.wait(timeout=2)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
        if self._log_handle:
            try:
                self._log_handle.close()
            except Exception:
                pass
            self._log_handle = None


class UsageMonitor:
    def __init__(self, data_dir: Path | None = None, poll_interval: int | None = None, autostart: bool = True) -> None:
        self.store = UsageStore(data_dir)
        self.notifier = LocalNotifier(self.store)
        self.poll_interval = poll_interval or int(os.environ.get("TOKEN_USAGE_MONITOR_POLL_SECONDS", "60"))
        self.poll_interval = max(15, self.poll_interval)
        self.client: AppServerClient | None = None
        self._stop = threading.Event()
        self._refresh = threading.Event()
        self._refresh_done = threading.Event()
        self._thread: threading.Thread | None = None
        self.last_refresh: int | None = None
        self.last_error: str | None = None
        if autostart:
            self.start()

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, name="token-usage-collector", daemon=True)
        self._thread.start()

    def _connect(self) -> None:
        if self.client:
            self.client.close()
        self.client = AppServerClient(self.store, self._on_notification)
        self.client.start()
        self.store.add_event("collector_connected", f"Connected through {self.client.mode}")

    def _run(self) -> None:
        backoff = 5
        while not self._stop.is_set():
            try:
                if not self.client:
                    self._connect()
                self.collect_once()
                backoff = 5
                self._refresh_done.set()
                self._refresh.wait(self.poll_interval)
                self._refresh.clear()
                self._refresh_done.clear()
            except Exception as exc:
                self.last_error = str(exc)
                self.store.set_state("collector.last_error", self.last_error)
                self.store.log(f"collector error: {exc}")
                if self.client:
                    self.client.close()
                    self.client = None
                self._refresh_done.set()
                self._stop.wait(backoff)
                backoff = min(backoff * 2, 120)

    def _on_notification(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        params = message.get("params") or {}
        if method == "thread/tokenUsage/updated":
            self.store.save_thread_usage(params)
        elif method == "account/rateLimits/updated":
            self.store.add_event("rate_limits_changed", "Codex reported a rate-limit change", params)
            self._refresh.set()

    def collect_once(self) -> None:
        if not self.client:
            raise RuntimeError("collector is not connected")
        any_success = False
        try:
            usage = self.client.request("account/usage/read")
            self.store.save_usage(usage)
            any_success = True
        except Exception as exc:
            self.store.log(f"account usage unavailable: {exc}")
        try:
            limits = self.client.request("account/rateLimits/read")
            rows, credits = self.store.save_rate_limits(limits)
            self._evaluate_alerts(rows, credits, limits)
            any_success = True
        except Exception as exc:
            self.store.log(f"rate limits unavailable: {exc}")
        if not any_success:
            raise RuntimeError("Codex account usage and rate-limit endpoints are unavailable")
        self.last_refresh = _now()
        self.last_error = None
        self.store.set_state("collector.last_refresh", str(self.last_refresh))
        self.store.set_state("collector.last_error", "")

    def _thresholds(self) -> list[int]:
        raw = self.store.get_state("notifications.thresholds", "[80,95,100]") or "[80,95,100]"
        try:
            return sorted({int(value) for value in json.loads(raw) if 1 <= int(value) <= 100})
        except Exception:
            return [80, 95, 100]

    def _evaluate_alerts(self, rows: list[dict[str, Any]], credits: list[dict[str, Any]], raw: dict[str, Any]) -> None:
        now = _now()
        warning_minutes = int(self.store.get_state("notifications.reset_warning_minutes", "30") or 30)
        for row in rows:
            key = f"limit.{row['limitId']}.{row['windowName']}"
            previous_raw = self.store.get_state(key)
            previous = json.loads(previous_raw) if previous_raw else {}
            used = row.get("usedPercent")
            resets_at = row.get("resetsAt")
            previous_used = previous.get("usedPercent")
            previous_reset = previous.get("resetsAt")
            if used is not None:
                for threshold in self._thresholds():
                    if used >= threshold and (previous_used is None or previous_used < threshold):
                        body = f"{row['limitId']} {row['windowName']} 已使用 {used:.0f}%"
                        self.notifier.send("Codex 用量提醒", body)
                        self.store.add_event("threshold_crossed", body, row)
            if previous_reset and resets_at and resets_at > previous_reset and previous_used is not None and used is not None and used < previous_used:
                body = f"{row['limitId']} {row['windowName']} 额度已刷新"
                self.notifier.send("Codex 额度刷新", body)
                self.store.add_event("quota_reset", body, row)
            if resets_at and 0 < resets_at - now <= warning_minutes * 60:
                warning_key = f"warning.sent.{key}.{resets_at}"
                if not self.store.get_state(warning_key):
                    body = f"{row['limitId']} {row['windowName']} 将在约 {(resets_at - now + 59) // 60} 分钟后刷新"
                    self.notifier.send("Codex 刷新提醒", body)
                    self.store.add_event("reset_approaching", body, row)
                    self.store.set_state(warning_key, "true")
            self.store.set_state(key, row)

        credit_info = raw.get("rateLimitResetCredits")
        if not isinstance(credit_info, dict) or credit_info.get("availableCount") is None:
            # A successful rate-limit response may temporarily omit reset-credit
            # metadata. Preserve the last known count so the next complete
            # response is not mistaken for a newly granted credit.
            return
        available_count = int(credit_info["availableCount"])
        previous_count = int(self.store.swap_state("reset_credits.available_count", str(available_count), "0") or 0)
        if available_count > previous_count:
            body = f"检测到 {available_count - previous_count} 个新的额度重置机会；不会自动兑换"
            self.notifier.send("Codex 额外刷新可用", body)
            self.store.add_event("extra_reset_granted", body, credits)

    def refresh_now(self, wait_seconds: int = 15) -> dict[str, Any]:
        before = self.last_refresh
        self._refresh_done.clear()
        self._refresh.set()
        if wait_seconds > 0:
            deadline = time.monotonic() + min(wait_seconds, 30)
            while time.monotonic() < deadline:
                if self.last_refresh and self.last_refresh != before:
                    break
                if self._refresh_done.wait(0.25) and self.last_error:
                    break
        return self.status()

    def status(self) -> dict[str, Any]:
        stored_refresh = self.store.get_state("collector.last_refresh")
        stored_error = self.store.get_state("collector.last_error")
        return {
            "running": bool(self._thread and self._thread.is_alive()),
            "connected": bool(self.client and self.client.mode and self.client.process and self.client.process.poll() is None),
            "connectionMode": self.client.mode if self.client else None,
            "pollIntervalSeconds": self.poll_interval,
            "lastRefresh": self.last_refresh or (int(stored_refresh) if stored_refresh else None),
            "lastError": self.last_error or stored_error or None,
            "databasePath": str(self.store.db_path),
            "storesConversationText": False,
            "notificationsEnabled": self.notifier.enabled(),
            "thresholds": self._thresholds(),
            "resetWarningMinutes": int(self.store.get_state("notifications.reset_warning_minutes", "30") or 30),
        }

    def configure_alerts(self, enabled: bool, thresholds: list[int], reset_warning_minutes: int) -> dict[str, Any]:
        clean = sorted({int(value) for value in thresholds if 1 <= int(value) <= 100})
        if not clean:
            raise ValueError("thresholds must contain at least one integer from 1 to 100")
        if not 0 <= reset_warning_minutes <= 1440:
            raise ValueError("reset_warning_minutes must be between 0 and 1440")
        self.store.set_state("notifications.enabled", "true" if enabled else "false")
        self.store.set_state("notifications.thresholds", clean)
        self.store.set_state("notifications.reset_warning_minutes", str(reset_warning_minutes))
        return self.status()

    def close(self) -> None:
        self._stop.set()
        self._refresh.set()
        if self.client:
            self.client.close()
