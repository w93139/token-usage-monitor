import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ['TOKEN_USAGE_MONITOR_DISABLE_NOTIFICATIONS'] = '1'
from token_monitor import UsageStore
from reset_credit_worker import ResetCreditWorker, POLICY_KEY, STATUS_KEY, policy, read_status, worker_lock


class FakeClient:
    def __init__(self, payload, outcomes=None):
        self.payload = payload
        self.outcomes = list(outcomes or [{"outcome": "reset"}])
        self.calls = []
        self.on_read = None

    def request(self, method, params=None):
        self.calls.append((method, params))
        if method == 'account/rateLimits/read':
            if self.on_read:
                self.on_read()
            return self.payload
        value = self.outcomes.pop(0)
        if isinstance(value, Exception):
            raise value
        return value

    @property
    def consumptions(self):
        return [p for m,p in self.calls if m.endswith('/consume')]


class ResetCreditWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = UsageStore(Path(self.temp.name))
        self.now = 2000000000
        self.config = {'enabled': True, 'accountId': 'account-a', 'leadMinutes': 30}
        self.store.set_state(POLICY_KEY, self.config)
        self.payload = {
            'accountId': 'account-a',
            'rateLimits': {'limitId': 'codex', 'primary': {'usedPercent': 25, 'windowDurationMins': 10080, 'resetsAt': self.now+10000}},
            'rateLimitResetCredits': {'availableCount': 1, 'credits': [self.credit()]}}
        self.client = FakeClient(self.payload)
        self.notifier = Mock()
        self.worker = ResetCreditWorker(self.store, self.client, lambda: self.now, self.notifier)

    def credit(self, ident='card-a', offset=1800, **changes):
        return dict({'id': ident, 'status': 'available', 'resetType': 'codexRateLimits', 'expiresAt': self.now+offset}, **changes)

    def test_disabled_and_invalid_policy_never_reads_or_consumes(self):
        for raw in ['{}', 'invalid', '[]', json.dumps(dict(self.config, enabled='true')), json.dumps(dict(self.config, leadMinutes=True))]:
            self.store.set_state(POLICY_KEY, raw)
            self.assertEqual(self.worker.tick()['state'], 'disabled')
        self.assertEqual(self.client.calls, [])

    def test_exact_lead_boundary_is_due_and_records_success(self):
        self.assertEqual(self.worker.tick()['state'], 'reset')
        self.assertEqual(self.client.consumptions[0]['creditId'], 'card-a')
        self.assertTrue(self.client.consumptions[0]['idempotencyKey'])
        events = self.store.recent_events()
        self.assertEqual(events[0]['event_type'], 'auto_reset_succeeded')
        self.assertEqual(self.worker.tick()['state'], 'waitingRetry')
        self.assertEqual(len(self.client.consumptions), 1)

    def test_before_lead_boundary_and_expired_never_consumes(self):
        for offset in [1801, 0, -1]:
            self.payload['rateLimitResetCredits']['credits'] = [self.credit(offset=offset)]
            self.assertEqual(self.worker.tick()['state'], 'waiting')
        self.assertEqual(self.client.consumptions, [])

    def test_invalid_or_unavailable_cards_never_consumed(self):
        for changes in [{'status': 'used'}, {'status': 'expired'}, {'resetType': 'other'}, {'expiresAt': True}, {'expiresAt': None}, {'id': ''}]:
            self.payload['rateLimitResetCredits']['credits'] = [self.credit(**changes)]
            self.worker.tick()
        self.assertEqual(self.client.consumptions, [])

    def test_missing_metadata_is_not_replaced_by_cached_card(self):
        self.store.save_rate_limits(self.payload)
        self.payload.pop('rateLimitResetCredits')
        self.assertEqual(self.worker.tick()["state"], "creditDetailsUnavailable")
        self.assertEqual(self.client.consumptions, [])

    def test_other_account_never_consumes(self):
        self.payload['accountId'] = 'account-b'
        self.assertEqual(self.worker.tick()['state'], 'accountMismatch')
        self.assertEqual(self.client.consumptions, [])

    def test_dry_run_is_fresh_and_never_consumes_or_allocates_attempt(self):
        result = self.worker.tick(dry_run=True)
        self.assertEqual(result['state'], 'dryRun')
        self.assertEqual(result['plans'][0]['scheduledAt'], self.now)
        self.assertEqual(self.client.consumptions, [])
        self.assertIsNone(self.store.get_state(self.worker._ledger_key('account-a', 'card-a')))

    def test_future_card_is_automatically_included_and_one_card_per_tick(self):
        self.payload['rateLimitResetCredits']['credits'] += [self.credit('new-card', 500)]
        self.payload['rateLimitResetCredits']['availableCount'] = 2
        self.worker.tick()
        self.assertEqual(self.client.consumptions[0]['creditId'], 'new-card')
        self.assertEqual(len(self.client.consumptions), 1)

    def test_no_used_window_never_consumes(self):
        for change in [0, None]:
            self.payload['rateLimits']['primary']['usedPercent'] = change
            self.assertEqual(self.worker.tick()['state'], 'nothingToReset')
        self.assertEqual(self.client.consumptions, [])

    def test_timeout_then_restart_reuses_key_until_confirmed(self):
        self.client.outcomes = [TimeoutError('SECRET'), {'outcome': 'alreadyRedeemed'}]
        self.assertEqual(self.worker.tick()['state'], 'error')
        original = self.client.consumptions[0]['idempotencyKey']
        self.assertEqual(self.worker.tick()['state'], 'waitingRetry')
        self.assertEqual(len(self.client.consumptions), 1)
        self.now += 60
        restarted = ResetCreditWorker(self.store, self.client, lambda: self.now, self.notifier)
        self.assertEqual(restarted.tick()['state'], 'alreadyRedeemed')
        self.assertEqual(self.client.consumptions[1]['idempotencyKey'], original)
        with self.store._connect() as c:
            dump = str(list(c.iterdump()))
        self.assertNotIn('SECRET', dump)

    def test_definitive_non_success_retry_uses_new_logical_key(self):
        for outcome in ['nothingToReset', 'noCredit']:
            with self.subTest(outcome=outcome):
                ident = 'card-' + outcome
                self.payload['rateLimitResetCredits']['credits'] = [self.credit(ident)]
                self.client.outcomes = [{'outcome': outcome}, {'outcome': 'reset'}]
                self.assertEqual(self.worker.tick()['state'], outcome)
                previous = self.client.consumptions[-1]['idempotencyKey']
                self.now += 60
                self.assertEqual(self.worker.tick()['state'], 'reset')
                self.assertNotEqual(previous, self.client.consumptions[-1]['idempotencyKey'])

    def test_unknown_result_does_not_record_success_and_reuses_key(self):
        self.client.outcomes = [{'outcome': 'unexpected'}, {'outcome': 'reset'}]
        self.assertEqual(self.worker.tick()['state'], 'error')
        original = self.client.consumptions[0]['idempotencyKey']
        self.now += 60
        self.assertEqual(self.worker.tick()['state'], 'reset')
        self.assertEqual(original, self.client.consumptions[1]['idempotencyKey'])

    def test_policy_disable_during_read_prevents_consume(self):
        self.client.on_read = lambda: self.store.set_state(POLICY_KEY, {'enabled': False})
        self.assertEqual(self.worker.tick()['state'], 'policyChanged')
        self.assertEqual(self.client.consumptions, [])

    def test_corrupt_ledger_fails_closed(self):
        self.store.set_state(self.worker._ledger_key('account-a', 'card-a'), 'invalid')
        self.assertEqual(self.worker.safe_tick()['state'], 'error')
        self.assertEqual(self.client.consumptions, [])

    def test_file_lock_prevents_multiple_workers(self):
        with worker_lock(self.store) as first:
            self.assertTrue(first)
            with worker_lock(self.store) as second:
                self.assertFalse(second)
        with worker_lock(self.store) as third:
            self.assertTrue(third)

    def test_status_lists_account_bound_attempt_metadata(self):
        self.worker.tick()
        result = read_status(self.store)
        self.assertEqual(result["attempts"][0]["outcome"], "reset")
        self.assertEqual(result["attempts"][0]["accountId"], "account-a")
        self.assertEqual(result["lastCheckAt"], self.now)
        self.store.set_state(POLICY_KEY, dict(self.config, accountId="other-account"))
        self.assertEqual(read_status(self.store)["attempts"], [])

    def test_dry_run_does_not_replace_daemon_status(self):
        self.store.set_state(STATUS_KEY, {"state": "waiting", "checkedAt": 123})
        self.worker.tick(dry_run=True)
        self.assertEqual(read_status(self.store)["lastCheckAt"], 123)

    def test_notification_failure_does_not_erase_confirmed_success(self):
        self.notifier.send.side_effect = RuntimeError("notification unavailable")
        self.assertEqual(self.worker.safe_tick()["state"], "reset")
        self.assertEqual(read_status(self.store)["attempts"][0]["outcome"], "reset")
        self.assertEqual(len(self.client.consumptions), 1)

    def test_expiry_during_read_never_consumes(self):
        self.client.on_read = lambda: setattr(self, "now", self.now + 1800)
        self.worker.tick()
        self.assertEqual(self.client.consumptions, [])

    def test_exhausted_quota_outside_expiry_window_never_consumes(self):
        self.payload["rateLimits"]["primary"]["usedPercent"] = 100
        self.payload["rateLimitResetCredits"]["credits"] = [self.credit(offset=1801)]
        self.assertEqual(self.worker.tick()["state"], "waiting")
        self.assertEqual(self.client.consumptions, [])

    def test_account_mismatch_notification_is_not_repeated(self):
        self.payload["accountId"] = "other-account"
        self.worker.tick()
        self.worker.tick()
        self.assertEqual(self.notifier.send.call_count, 1)

    def test_timeout_then_disappears_and_usage_zero_replays_exact_operation(self):
        self.client.outcomes = [TimeoutError("lost response"), {"outcome": "alreadyRedeemed"}]
        self.worker.tick()
        original = dict(self.client.consumptions[0])
        self.payload["rateLimitResetCredits"] = {"availableCount": 0, "credits": []}
        self.payload["rateLimits"]["primary"]["usedPercent"] = 0
        self.now += 60
        restarted = ResetCreditWorker(self.store, self.client, lambda: self.now, self.notifier)
        self.assertEqual(restarted.tick()["state"], "alreadyRedeemed")
        self.assertEqual(self.client.consumptions, [original, original])
        self.assertEqual(read_status(self.store)["attempts"][0]["outcome"], "alreadyRedeemed")

    def test_unknown_attempt_after_expiry_stays_unconfirmed_without_rpc(self):
        self.client.outcomes = [TimeoutError("lost response")]
        self.worker.tick()
        self.payload["rateLimitResetCredits"] = {"availableCount": 0, "credits": []}
        self.now += 1800
        result = self.worker.tick()
        self.assertEqual(result["state"], "outcomeUnconfirmed")
        self.assertEqual(result["unconfirmedCreditIds"], ["card-a"])
        self.assertEqual(len(self.client.consumptions), 1)
        self.assertEqual(read_status(self.store)["attempts"][0]["outcome"], "outcomeUnconfirmed")
        self.worker.tick()
        self.assertEqual(len(self.client.consumptions), 1)

    def test_missing_details_is_distinct_and_alerted_once(self):
        self.payload.pop("rateLimitResetCredits")
        for _ in range(2):
            result = self.worker.tick()
            self.assertEqual(result["state"], "creditDetailsUnavailable")
            self.assertFalse(result["creditDetailsAvailable"])
        self.assertEqual(self.notifier.send.call_count, 1)
        self.assertEqual(self.client.consumptions, [])

    def test_incomplete_details_count_is_not_normal_waiting(self):
        self.payload["rateLimitResetCredits"] = {"availableCount": 1, "credits": []}
        self.assertEqual(self.worker.tick()["state"], "creditDetailsUnavailable")
        self.assertEqual(self.client.consumptions, [])

    def test_missing_card_without_previous_attempt_never_uses_any_credit(self):
        self.payload["rateLimitResetCredits"] = {"availableCount": 0, "credits": []}
        self.assertEqual(self.worker.tick()["state"], "waiting")
        self.assertEqual(self.client.consumptions, [])

    def test_unknown_attempt_with_damaged_window_proof_never_replayed(self):
        self.client.outcomes = [TimeoutError("lost response")]
        self.worker.tick()
        key = self.worker._ledger_key("account-a", "card-a")
        saved = json.loads(self.store.get_state(key))
        saved.pop("scheduledAt")
        self.store.set_state(key, saved)
        self.payload["rateLimitResetCredits"] = {"availableCount": 0, "credits": []}
        self.now += 60
        self.assertEqual(self.worker.tick()["state"], "outcomeUnconfirmed")
        self.assertEqual(len(self.client.consumptions), 1)

    def test_replay_obeys_current_shorter_policy_window(self):
        self.client.outcomes = [TimeoutError("lost response"), {"outcome": "alreadyRedeemed"}]
        self.worker.tick()
        original = dict(self.client.consumptions[0])
        self.payload["rateLimitResetCredits"] = {"availableCount": 0, "credits": []}
        self.store.set_state(POLICY_KEY, dict(self.config, leadMinutes=5))
        self.now += 60
        self.assertEqual(self.worker.tick()["state"], "waiting")
        self.assertEqual(len(self.client.consumptions), 1)
        self.now += 1440
        self.assertEqual(self.worker.tick()["state"], "alreadyRedeemed")
        self.assertEqual(self.client.consumptions[-1], original)

    def test_clock_retreat_before_original_window_does_not_replay(self):
        self.client.outcomes = [TimeoutError("lost response")]
        self.worker.tick()
        self.payload["rateLimitResetCredits"] = {"availableCount": 0, "credits": []}
        self.now -= 1
        self.assertEqual(self.worker.tick()["state"], "waiting")
        self.assertEqual(len(self.client.consumptions), 1)

    def test_clock_retreat_immediately_before_consume_does_not_call(self):
        real = self.worker._load_attempt
        def retreat(key):
            result = real(key)
            self.now -= 1
            return result
        self.worker._load_attempt = retreat
        self.worker.tick()
        self.assertEqual(self.client.consumptions, [])

    def test_missing_details_does_not_block_proven_unknown_operation_replay(self):
        self.client.outcomes = [TimeoutError("lost response"), {"outcome": "alreadyRedeemed"}]
        self.worker.tick()
        original = dict(self.client.consumptions[0])
        self.payload.pop("rateLimitResetCredits")
        self.payload["rateLimits"]["primary"]["usedPercent"] = 0
        self.now += 60
        result = self.worker.tick()
        self.assertEqual(result["state"], "alreadyRedeemed")
        self.assertFalse(result["creditDetailsAvailable"])
        self.assertEqual(self.client.consumptions, [original, original])

    def test_explicit_zero_count_without_details_is_authoritative(self):
        self.payload["rateLimitResetCredits"] = {"availableCount": 0}
        result = self.worker.tick()
        self.assertEqual(result["state"], "waiting")
        self.assertTrue(result["creditDetailsAvailable"])
        self.assertEqual(self.notifier.send.call_count, 0)
        self.assertEqual(self.client.consumptions, [])

    def test_contradictory_details_never_authorizes_new_redemption(self):
        cases = [
            {"availableCount": 0, "credits": [self.credit()]},
            {"availableCount": 1, "credits": [self.credit(status="used")]},
            {"availableCount": 1, "credits": ["invalid"]},
            {"availableCount": True, "credits": [self.credit()]},
        ]
        for info in cases:
            with self.subTest(info=info):
                self.payload["rateLimitResetCredits"] = info
                self.assertEqual(self.worker.tick()["state"], "creditDetailsUnavailable")
        self.assertEqual(self.client.consumptions, [])

    def test_dry_run_reports_missing_details_on_pending_replay(self):
        self.client.outcomes = [TimeoutError("lost response")]
        self.worker.tick()
        self.payload.pop("rateLimitResetCredits")
        self.now += 60
        result = self.worker.tick(dry_run=True)
        self.assertEqual(result["state"], "dryRun")
        self.assertFalse(result["creditDetailsAvailable"])
        self.assertTrue(result["due"][0]["replay"])
        self.assertEqual(len(self.client.consumptions), 1)


if __name__ == '__main__':
    unittest.main()
