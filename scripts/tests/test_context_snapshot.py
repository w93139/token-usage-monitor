import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from context_snapshot import read_snapshot


class ContextSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.db = self.home / 'state_5.sqlite'
        self.rollout = self.home / 'sessions' / 'rollout.jsonl'
        self.rollout.parent.mkdir()
        with sqlite3.connect(self.db) as conn:
            conn.execute('CREATE TABLE threads(id TEXT, rollout_path TEXT)')
            conn.execute('INSERT INTO threads VALUES (?,?)', ('task-a', str(self.rollout)))

    def tearDown(self):
        self.temp.cleanup()

    def event(self, info=None, kind='token_count'):
        return {'timestamp': '2026-09-08T12:00:00Z', 'type': 'event_msg',
                'payload': {'type': kind, 'info': info}}

    def usage(self, tokens=120, window=200000):
        return self.event({'last_token_usage': {'input_tokens': 100, 'output_tokens': 20,
                                               'cached_input_tokens': 70, 'reasoning_output_tokens': 10,
                                               'total_tokens': tokens},
                           'total_token_usage': {'total_tokens': 99999999},
                           'model_context_window': window})

    def write(self, *events):
        self.rollout.write_text(''.join(json.dumps(e) + '\n' for e in events))

    def read(self, **kwargs):
        return read_snapshot('task-a', self.home, self.db, **kwargs)

    def test_last_usage_not_cumulative_or_subsets(self):
        self.write(self.usage(110), self.usage())
        result = self.read()
        self.assertEqual(result['tokens'], 120)
        self.assertEqual(result['window'], 200000)
        self.assertEqual(result['capturedAt'], 1788868800)
        self.assertIsNone(result['error'])

    def test_missing_latest_usage_never_falls_back(self):
        self.write(self.usage(), self.event())
        self.assertEqual(self.read()['error'], 'usage_unavailable')
        self.assertIsNone(self.read()['tokens'])

    def test_compaction_and_rollback_invalidate_until_new_usage(self):
        for reset in ('context_compacted', 'context_cleared', 'context_reset', 'thread_rolled_back'):
            with self.subTest(reset=reset):
                self.write(self.usage(), self.event(kind=reset))
                self.assertEqual(self.read()['error'], 'context_reset')
                self.write(self.usage(), self.event(kind=reset), self.usage(140))
                self.assertEqual(self.read()['tokens'], 140)
        self.write(self.usage(), {'type': 'compacted', 'payload': {}})
        self.assertEqual(self.read()['error'], 'context_reset')

    def test_missing_or_invalid_window_and_counts_stay_unknown(self):
        for tokens, window in ((None, 200000), (120, None), (120, 0), (True, 200000), (-1, 200000)):
            self.write(self.usage(tokens, window))
            result = self.read()
            self.assertEqual(result['error'], 'incomplete_usage')
            self.assertIsNone(result['tokens'])
        event = self.usage()
        del event['payload']['info']['last_token_usage']['total_tokens']
        self.write(event)
        self.assertEqual(self.read()['tokens'], 120)

    def test_old_timestamp_is_preserved_not_replaced_with_poll_time(self):
        event = self.usage()
        event['timestamp'] = '2020-01-01T00:00:00Z'
        self.write(event)
        self.assertEqual(self.read()['capturedAt'], 1577836800)
        event['timestamp'] = 'invalid'
        self.write(event)
        self.assertEqual(self.read()['error'], 'invalid_timestamp')

    def test_tail_limit_unknown_and_later_usage_found(self):
        long_event = {'type': 'response_item', 'payload': {'text': 'PRIVATE' * 500}}
        self.write(self.usage(), long_event)
        self.assertEqual(self.read(max_tail_bytes=1000)['error'], 'usage_not_in_tail')
        self.write(long_event, self.usage())
        self.assertEqual(self.read(max_tail_bytes=1000)['tokens'], 120)
        self.assertNotIn('PRIVATE', json.dumps(self.read(max_tail_bytes=1000)))

    def test_partial_or_corrupt_tail_does_not_claim_previous_usage_current(self):
        self.write(self.usage())
        with self.rollout.open('a') as handle:
            handle.write('{"type":')
        self.assertEqual(self.read()['error'], 'rollout_incomplete')
        with self.rollout.open('a') as handle:
            handle.write('\n')
        self.assertEqual(self.read()['error'], 'rollout_invalid')

    def test_thread_lookup_and_path_guard(self):
        self.assertEqual(read_snapshot('missing', self.home, self.db)['error'], 'thread_not_found')
        with sqlite3.connect(self.db) as conn:
            conn.execute('UPDATE threads SET rollout_path=?', (str(self.home / 'outside.jsonl'),))
        self.assertEqual(self.read()['error'], 'rollout_outside_home')
        self.db.unlink()
        self.assertEqual(self.read()['error'], 'database_missing')

    def test_symlink_outside_home_rejected_and_database_read_only(self):
        outside = self.home / 'outside.jsonl'
        outside.write_text('{}\n')
        self.rollout.symlink_to(outside)
        before = self.db.read_bytes()
        self.assertEqual(self.read()['error'], 'rollout_outside_home')
        self.assertEqual(before, self.db.read_bytes())

    def test_state_version_selected_numerically_and_switch_thread(self):
        self.write(self.usage())
        newer = self.home / 'state_10.sqlite'
        with sqlite3.connect(newer) as conn:
            conn.execute('CREATE TABLE threads(id TEXT, rollout_path TEXT)')
            conn.execute('INSERT INTO threads VALUES (?,?)', ('task-b', str(self.rollout)))
        with patch.dict(os.environ, {'CODEX_STATE_DB': ''}):
            self.assertEqual(read_snapshot('task-b', self.home)['tokens'], 120)
            self.assertEqual(read_snapshot('task-a', self.home)['error'], 'thread_not_found')


if __name__ == '__main__':
    unittest.main()
