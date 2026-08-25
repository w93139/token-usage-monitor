import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))
os.environ["TOKEN_USAGE_MONITOR_DISABLE_NOTIFICATIONS"] = "1"

from api_usage_server import UsageHTTPServer  # noqa: E402
from token_monitor import UsageStore  # noqa: E402


class APIUsageServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.server = UsageHTTPServer(("127.0.0.1", 0), UsageStore(Path(self.temp.name)))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def read_json(self, request):
        with urlopen(request, timeout=2) as response:
            return response.status, json.load(response)

    def test_health_ingestion_history_and_deduplication(self):
        status, health = self.read_json(f"{self.base_url}/health")
        self.assertEqual(status, 200)
        self.assertEqual(health, {"ok": True, "service": "token-usage-monitor"})

        payload = {
            "provider": "openai",
            "model": "gpt-test",
            "task_name": "HTTP integration test",
            "request_id": "http-test-1",
            "usage": {"input_tokens": 12, "output_tokens": 3, "total_tokens": 15},
        }
        request = Request(
            f"{self.base_url}/v1/usage",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        status, saved = self.read_json(request)
        self.assertEqual(status, 201)
        self.assertTrue(saved["recorded"])

        status, duplicate = self.read_json(request)
        self.assertEqual(status, 201)
        self.assertFalse(duplicate["recorded"])

        status, history = self.read_json(f"{self.base_url}/v1/usage?days=30&limit=10")
        self.assertEqual(status, 200)
        self.assertEqual(len(history["data"]), 1)
        self.assertEqual(history["data"][0]["total_tokens"], 15)

    def test_browser_cross_origin_preflight_is_rejected(self):
        request = Request(f"{self.base_url}/v1/usage", method="OPTIONS")
        with self.assertRaises(HTTPError) as caught:
            urlopen(request, timeout=2)
        self.assertEqual(caught.exception.code, 403)


if __name__ == "__main__":
    unittest.main()
