import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

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


class AlertConfigurationTests(unittest.TestCase):
    def test_configuration_is_validated(self):
        with tempfile.TemporaryDirectory() as temp:
            monitor = UsageMonitor(Path(temp), autostart=False)
            status = monitor.configure_alerts(True, [95, 80, 95], 15)
            self.assertEqual(status["thresholds"], [80, 95])
            self.assertEqual(status["resetWarningMinutes"], 15)
            with self.assertRaises(ValueError):
                monitor.configure_alerts(True, [], 15)


if __name__ == "__main__":
    unittest.main()
