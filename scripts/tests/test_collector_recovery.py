import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from token_monitor import UsageMonitor, find_codex_binary


class CollectorRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.monitor = UsageMonitor(Path(self.temp.name), autostart=False)
        self.monitor.client = Mock()
        self.limits = {'rateLimits': {'limitId': 'codex', 'primary': {'usedPercent': 25,
                        'windowDurationMins': 300, 'resetsAt': 2000000000}}}
        self.monitor._evaluate_alerts = Mock()

    def request_results(self, usage, limits):
        def request(method):
            value = usage if method == 'account/usage/read' else limits
            if isinstance(value, Exception):
                raise value
            return value
        self.monitor.client.request.side_effect = request

    def stored_quota(self):
        with self.monitor.store._connect() as conn:
            return [dict(row) for row in conn.execute('SELECT * FROM rate_limit_snapshots')]

    def test_partial_quota_failures_preserve_error_and_data_then_reconnect(self):
        self.monitor.store.save_rate_limits(self.limits)
        before = self.stored_quota()
        self.request_results({'summary': {'lifetimeTokens': 100}}, RuntimeError('unavailable PRIVATE_AUTH_HEADER'))
        for count in (1, 2):
            self.monitor.collect_once()
            self.assertEqual(self.monitor._rate_limit_failures, count)
            self.assertIn('quota is unavailable', self.monitor.last_error)
            self.assertEqual(self.monitor.store.get_state('collector.last_error'), self.monitor.last_error)
            self.assertEqual(self.stored_quota(), before)
        with self.assertRaisesRegex(RuntimeError, 'failed repeatedly'):
            self.monitor.collect_once()
        self.assertEqual(self.stored_quota(), before)
        self.assertNotIn('PRIVATE_AUTH_HEADER', self.monitor.store.log_path.read_text())
        self.assertNotIn('PRIVATE_AUTH_HEADER', self.monitor.last_error)

    def test_auth_failure_on_either_endpoint_immediately_requests_reconnect(self):
        for endpoint in ('usage', 'limits'):
            with self.subTest(endpoint=endpoint):
                failure = RuntimeError('401 Unauthorized: expired token PRIVATE_CREDENTIAL')
                self.request_results(failure if endpoint == 'usage' else {},
                                     failure if endpoint == 'limits' else self.limits)
                with self.assertRaisesRegex(RuntimeError, 'authentication.*reconnecting') as caught:
                    self.monitor.collect_once()
                self.assertNotIn('PRIVATE_CREDENTIAL', str(caught.exception))
                self.assertEqual(self.stored_quota(), [])

    def test_success_resets_failure_streak_and_clears_partial_error(self):
        self.request_results({}, RuntimeError('temporary failure'))
        self.monitor.collect_once()
        self.monitor.collect_once()
        self.request_results({}, self.limits)
        self.monitor.collect_once()
        self.assertEqual(self.monitor._rate_limit_failures, 0)
        self.assertIsNone(self.monitor.last_error)
        self.assertEqual(self.monitor.store.get_state('collector.last_error'), '')
        self.assertEqual(self.stored_quota()[0]['used_percent'], 25)
        self.request_results({}, RuntimeError('temporary failure'))
        self.monitor.collect_once()
        self.assertEqual(self.monitor._rate_limit_failures, 1)

    def test_empty_and_invalid_quota_never_overwrite_valid_quota(self):
        self.monitor.store.save_rate_limits(self.limits)
        before = self.stored_quota()
        invalid = [{}, {'rateLimitsByLimitId': []}]
        invalid.extend({'rateLimits': {'primary': {'usedPercent': value}}}
                       for value in (None, True, '30', -1, 101, 1e100, float('nan'), float('inf'), 10**1000))
        for payload in invalid:
            with self.subTest(payload=str(payload)[:100]):
                self.monitor._rate_limit_failures = 0
                self.request_results({}, payload)
                self.monitor.collect_once()
                self.assertIn('quota is unavailable', self.monitor.last_error)
                self.assertEqual(self.stored_quota(), before)
                self.monitor._evaluate_alerts.assert_not_called()

    def test_valid_window_with_unknown_secondary_only_saves_valid_window(self):
        payload = {'rateLimits': {'primary': {'usedPercent': 0}, 'secondary': {'usedPercent': None}}}
        self.request_results({}, payload)
        self.monitor.collect_once()
        self.assertIsNone(self.monitor.last_error)
        self.assertEqual(len(self.stored_quota()), 1)
        self.assertEqual(self.stored_quota()[0]['used_percent'], 0)

    def test_usage_failure_remains_visible_when_quota_succeeds(self):
        self.request_results(RuntimeError('not supported PRIVATE_BODY'), self.limits)
        self.monitor.collect_once()
        self.assertIn('account usage is unavailable', self.monitor.last_error)
        self.assertEqual(self.monitor._rate_limit_failures, 0)
        self.assertEqual(len(self.stored_quota()), 1)
        self.assertNotIn('PRIVATE_BODY', self.monitor.store.log_path.read_text())

    def test_run_closes_client_after_repeated_quota_failure(self):
        self.request_results({}, RuntimeError('unavailable'))
        self.monitor._rate_limit_failures = 2
        client = self.monitor.client
        with patch.object(self.monitor._stop, 'wait', side_effect=lambda _: self.monitor._stop.set()):
            self.monitor._run()
        client.close.assert_called_once_with()
        self.assertIsNone(self.monitor.client)
        self.assertIn('reconnecting', self.monitor.last_error)


class BinaryDiscoveryTests(unittest.TestCase):
    def test_current_desktop_cli_precedes_path_cli(self):
        binary = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'
        with patch.dict(os.environ, {'CODEX_BINARY': ''}), \
             patch.object(Path, 'is_file', lambda path: str(path) == binary), \
             patch('token_monitor.os.access', return_value=True), \
             patch('token_monitor.shutil.which', return_value='/other/codex') as which:
            self.assertEqual(find_codex_binary(), binary)
            which.assert_not_called()

    def test_explicit_override_remains_first(self):
        binary = '/custom/codex'
        with patch.dict(os.environ, {'CODEX_BINARY': binary}), \
             patch.object(Path, 'is_file', lambda path: str(path) == binary), \
             patch('token_monitor.shutil.which') as which:
            self.assertEqual(find_codex_binary(), binary)
            which.assert_not_called()

    def test_path_cli_fallback_when_desktop_binary_missing(self):
        with patch.dict(os.environ, {'CODEX_BINARY': ''}), \
             patch.object(Path, 'is_file', return_value=False), \
             patch('token_monitor.shutil.which', return_value='/other/codex'):
            self.assertEqual(find_codex_binary(), '/other/codex')


if __name__ == '__main__':
    unittest.main()
