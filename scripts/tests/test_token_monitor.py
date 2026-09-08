import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
os.environ["TOKEN_USAGE_MONITOR_DISABLE_NOTIFICATIONS"] = "1"

from token_monitor import UsageMonitor, UsageStore  # noqa: E402


class UsageStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = UsageStore(Path(self.temp.name))

    def tearDown(self):
        self.temp.cleanup()

    def test_usage_and_history_round_trip(self):
        self.store.save_usage(
            {
                "summary": {
                    "lifetimeTokens": 1234,
                    "peakDailyTokens": 800,
                    "longestRunningTurnSec": 42,
                    "currentStreakDays": 3,
                    "longestStreakDays": 5,
                },
                "dailyUsageBuckets": [{"startDate": "2099-01-01", "tokens": 321}],
            }
        )
        summary = self.store.summary()
        self.assertEqual(summary["accountUsage"]["lifetimeTokens"], 1234)

    def test_rate_limit_flatten_and_credit_round_trip(self):
        payload = {
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 2000000000},
                    "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 2000100000},
                }
            },
            "rateLimitResetCredits": {
                "availableCount": 1,
                "credits": [{"id": "reset-1", "status": "available", "grantedAt": 1, "expiresAt": 2}],
            },
        }
        rows, credits = self.store.save_rate_limits(payload)
        self.assertEqual(len(rows), 2)
        self.assertEqual(len(credits), 1)
        summary = self.store.summary()
        self.assertEqual(len(summary["rateLimits"]), 2)
        self.assertEqual(summary["availableResetCredits"][0]["credit_id"], "reset-1")

    def test_thread_usage_never_stores_message_text(self):
        payload = {"threadId": "thr_test", "usage": {"inputTokens": 10, "outputTokens": 5, "totalTokens": 15}}
        self.store.save_thread_usage(payload)
        rendered = json.dumps(self.store.summary(), ensure_ascii=False)
        self.assertIn("thr_test", rendered)
        self.assertNotIn("prompt", rendered.lower())

    def test_multi_provider_api_usage_round_trip_and_deduplication(self):
        result = self.store.save_api_usage(
            {
                "provider": "deepseek",
                "model": "deepseek-chat",
                "task_name": "测试 API 任务",
                "request_id": "req-1",
                "usage": {
                    "prompt_tokens": 120,
                    "prompt_cache_hit_tokens": 40,
                    "completion_tokens": 30,
                    "total_tokens": 150,
                },
            }
        )
        self.assertTrue(result["recorded"])
        self.assertEqual(result["cachedInputTokens"], 40)
        duplicate = self.store.save_api_usage(
            {
                "provider": "deepseek",
                "model": "deepseek-chat",
                "request_id": "req-1",
                "usage": {"prompt_tokens": 120, "completion_tokens": 30, "total_tokens": 150},
            }
        )
        self.assertFalse(duplicate["recorded"])
        rows = self.store.api_usage_history(30, 10)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["task_name"], "测试 API 任务")
        self.assertEqual(rows[0]["total_tokens"], 150)


    def test_current_thread_protocol_whitelists_metadata_and_preserves_missing(self):
        self.store.save_thread_usage({
            "threadId": "current", "prompt": "PRIVATE PROMPT", "response": "PRIVATE RESPONSE",
            "tokenUsage": {
                "total": {"inputTokens": 900, "cachedInputTokens": 700, "outputTokens": 100,
                          "reasoningOutputTokens": 30, "totalTokens": 1000, "text": "PRIVATE TEXT"},
                "last": {"inputTokens": 90, "outputTokens": 10, "totalTokens": 100},
                "modelContextWindow": 200000}})
        with self.store._connect() as conn:
            row = dict(conn.execute("SELECT * FROM thread_usage").fetchone())
        self.assertEqual(row["total_tokens"], 1000)
        self.assertEqual(row["reasoning_tokens"], 30)
        metadata = json.loads(row["raw_json"])
        self.assertEqual(metadata["last"]["total"], 100)
        self.assertIsNone(metadata["last"]["cached"])
        self.assertEqual(metadata["modelContextWindow"], 200000)
        self.assertNotIn("PRIVATE", row["raw_json"])
        self.store.save_thread_usage({"threadId": "empty", "tokenUsage": {"total": None, "last": None}})
        with self.store._connect() as conn:
            row = conn.execute("SELECT * FROM thread_usage WHERE thread_id='empty'").fetchone()
        self.assertIsNone(row["total_tokens"])
        self.assertIsNone(row["input_tokens"])

    def test_legacy_thread_flat_and_invalid_counts(self):
        self.store.save_thread_usage({"thread_id": "legacy", "input_tokens": 5,
                                     "output_tokens": True, "total_tokens": -1,
                                     "reasoning_output_tokens": 2})
        with self.store._connect() as conn:
            row = conn.execute("SELECT * FROM thread_usage").fetchone()
        self.assertEqual(row["input_tokens"], 5)
        self.assertEqual(row["reasoning_tokens"], 2)
        self.assertIsNone(row["output_tokens"])
        self.assertIsNone(row["total_tokens"])

    def test_api_stream_final_subsets_and_channel_deduplication(self):
        payload = {"provider": "relay-a", "request_id": "same", "source": "stream_final",
                   "usage": {"input_tokens": 100, "output_tokens": 20,
                             "input_tokens_details": {"cached_tokens": 80},
                             "output_tokens_details": {"reasoning_tokens": 10}}}
        saved = self.store.save_api_usage(payload)
        self.assertEqual(saved["totalTokens"], 120)
        self.assertEqual(saved["source"], "stream_final")
        self.assertFalse(self.store.save_api_usage(payload)["recorded"])
        self.assertTrue(self.store.save_api_usage(dict(payload, provider="relay-b"))["recorded"])
        self.assertEqual(len(self.store.api_usage_history()), 2)

    def test_api_missing_final_usage_and_invalid_metadata_never_write(self):
        base = {"provider": "relay-a", "request_id": "req", "source": "stream_final"}
        cases = [dict(base, usage=None), dict(base, usage={}),
                 dict(base, usage={"input_tokens": 10}),
                 dict(base, usage={"input_tokens": 10, "output_tokens": True}),
                 dict(base, usage={"total_tokens": 1.2}),
                 dict(base, usage={"total_tokens": 2**64}),
                 dict(base, usage={"total_tokens": 10, "input_tokens_details": []}),
                 dict(base, source="estimated", usage={"total_tokens": 10}),
                 dict(base, model={"text": "secret"}, usage={"total_tokens": 10}),
                 dict(base, capturedAt="today", usage={"total_tokens": 10}),
                 dict(base, request_id=None, usage={"total_tokens": 10}),
                 dict(base, usage={"input_tokens": 10, "output_tokens": 2,
                                   "cached_input_tokens": 11}),
                 dict(base, usage={"input_tokens": 10, "output_tokens": 2,
                                   "reasoning_tokens": 3}),
                 dict(base, usage={"input_tokens": 10, "output_tokens": 2, "total_tokens": 5})]
        for payload in cases:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.store.save_api_usage(payload)
        self.assertEqual(self.store.api_usage_history(), [])

    def test_api_stores_only_whitelisted_metadata(self):
        self.store.save_api_usage({"usage": {"total_tokens": 10, "text": "PRIVATE"},
                                   "prompt": "PRIVATE", "api_key": "PRIVATE"})
        with self.store._connect() as conn:
            rows = [dict(row) for row in conn.execute("SELECT * FROM api_usage")]
        self.assertNotIn("PRIVATE", json.dumps(rows))


class TaskHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.store = UsageStore(self.home / "monitor")

    def make_database(self, name, thread_id, display_name=None):
        path = self.home / name
        with sqlite3.connect(path) as conn:
            conn.execute("""CREATE TABLE threads(id TEXT, name TEXT, title TEXT, tokens_used INTEGER,
                         created_at INTEGER, updated_at INTEGER, model TEXT, archived INTEGER,
                         thread_source TEXT, agent_role TEXT)""")
            conn.execute("CREATE TABLE thread_spawn_edges(child_thread_id TEXT)")
            conn.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)",
                         (thread_id, display_name, "PRIVATE INITIAL PROMPT BODY", 100, 1, 2, "model", 0, "user", None))
        return path

    def test_custom_home_uses_numeric_state_version(self):
        self.make_database("state_9.sqlite", "old-task", "Old")
        self.make_database("state_10.sqlite", "new-task", "New")
        self.make_database("state_other.sqlite", "invalid-task", "Ignore")
        with patch.dict(os.environ, {"CODEX_HOME": str(self.home), "CODEX_STATE_DB": ""}):
            rows = self.store.codex_task_history()
        self.assertEqual([row["id"] for row in rows], ["new-task"])
        self.assertEqual(rows[0]["title"], "New")

    def test_state_override_wins_and_read_preserves_source(self):
        explicit = self.make_database("explicit # source.sqlite", "explicit-task", "Chosen")
        self.make_database("state_10.sqlite", "other-task", "Other")
        before = explicit.read_bytes()
        with patch.dict(os.environ, {"CODEX_HOME": str(self.home), "CODEX_STATE_DB": str(explicit)}):
            rows = self.store.codex_task_history()
        self.assertEqual(rows[0]["id"], "explicit-task")
        self.assertEqual(before, explicit.read_bytes())

    def test_missing_name_never_returns_initial_prompt_title(self):
        database = self.make_database("state_10.sqlite", "12345678-rest")
        with sqlite3.connect(database) as conn:
            conn.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?)",
                         ("abcdefgh-rest", "   ", "ANOTHER PRIVATE PROMPT", 200, 1, 3, "", 0, "user", None))
        with patch.dict(os.environ, {"CODEX_HOME": str(self.home), "CODEX_STATE_DB": ""}):
            rows = self.store.codex_task_history()
        self.assertEqual([row["title"] for row in rows], ["未命名任务 abcdefgh", "未命名任务 12345678"])
        self.assertNotIn("PRIVATE", json.dumps(rows))


class AlertConfigurationTests(unittest.TestCase):
    def test_configuration_is_validated(self):
        with tempfile.TemporaryDirectory() as temp:
            monitor = UsageMonitor(Path(temp), autostart=False)
            status = monitor.configure_alerts(True, [95, 80, 95], 15)
            self.assertEqual(status["thresholds"], [80, 95])
            self.assertEqual(status["resetWarningMinutes"], 15)
            with self.assertRaises(ValueError):
                monitor.configure_alerts(True, [], 15)

    def test_missing_reset_credit_metadata_does_not_repeat_grant_alert(self):
        with tempfile.TemporaryDirectory() as temp:
            monitor = UsageMonitor(Path(temp), autostart=False)
            monitor._evaluate_alerts(
                [],
                [{"id": "reset-1"}, {"id": "reset-2"}],
                {"rateLimitResetCredits": {"availableCount": 2}},
            )
            self.assertEqual(monitor.store.get_state("reset_credits.available_count"), "2")

            monitor._evaluate_alerts([], [], {})
            self.assertEqual(monitor.store.get_state("reset_credits.available_count"), "2")

            monitor._evaluate_alerts(
                [],
                [{"id": "reset-1"}, {"id": "reset-2"}],
                {"rateLimitResetCredits": {"availableCount": 2}},
            )
            events = monitor.store.recent_events(20)
            grant_events = [event for event in events if event["event_type"] == "extra_reset_granted"]
            self.assertEqual(len(grant_events), 1)

    def test_explicit_zero_reset_credit_count_is_recorded(self):
        with tempfile.TemporaryDirectory() as temp:
            monitor = UsageMonitor(Path(temp), autostart=False)
            monitor.store.set_state("reset_credits.available_count", "2")
            monitor._evaluate_alerts([], [], {"rateLimitResetCredits": {"availableCount": 0}})
            self.assertEqual(monitor.store.get_state("reset_credits.available_count"), "0")

    def test_shared_collectors_claim_reset_credit_alert_once(self):
        with tempfile.TemporaryDirectory() as temp:
            first = UsageMonitor(Path(temp), autostart=False)
            second = UsageMonitor(Path(temp), autostart=False)
            payload = {"rateLimitResetCredits": {"availableCount": 2}}

            first._evaluate_alerts([], [], payload)
            second._evaluate_alerts([], [], payload)

            events = first.store.recent_events(20)
            grant_events = [event for event in events if event["event_type"] == "extra_reset_granted"]
            self.assertEqual(len(grant_events), 1)


if __name__ == "__main__":
    unittest.main()
