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
        return self.event({'last_token_usage': {'input_tokens': tokens - 20 if type(tokens) is int and tokens >= 20 else 100, 'output_tokens': 20,
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

    def test_post_compaction_estimate_unknown_until_measured_usage(self):
        before = self.usage(223644, 258400)
        reset = {'timestamp': '2026-09-08T16:21:34.976Z', 'type': 'compacted', 'payload': {}}
        estimate = self.event({'last_token_usage': {'input_tokens': 0, 'output_tokens': 0,
                                                  'total_tokens': 21277},
                               'model_context_window': 258400})
        estimate['timestamp'] = '2026-09-08T16:21:34.981Z'
        self.write(before, reset, estimate)
        result = self.read()
        self.assertEqual(result['error'], 'context_estimated')
        self.assertIsNone(result['tokens'])
        measured = self.usage(34698, 258400)
        measured['timestamp'] = '2026-09-08T16:21:42.968Z'
        record = {'timestamp': '2026-09-08T16:21:42.965Z', 'type': 'token_usage_record',
                  'payload': {'usage': measured['payload']['info']['last_token_usage']}}
        self.write(before, reset, estimate, record, measured)
        self.assertEqual(self.read()['tokens'], 34698)
        # Old clients reporting only consistent token_count events still work.
        self.write(before, reset, measured)
        self.assertEqual(self.read()['tokens'], 34698)

    def test_inconsistent_total_is_not_reported_as_measured_context(self):
        event = self.usage()
        event['payload']['info']['last_token_usage']['total_tokens'] = 125
        self.write(event)
        self.assertEqual(self.read()['error'], 'context_estimated')
        event['payload']['info']['last_token_usage'] = {'total_tokens': 125}
        self.write(event)
        self.assertEqual(self.read()['tokens'], 125)

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

    def test_exact_tail_boundary_keeps_complete_usage_and_reset(self):
        prefix = {'type': 'response_item', 'payload': {'text': 'PRIVATE' * 500}}
        for event, expected_error in ((self.usage(), None), (self.event(kind='context_compacted'), 'context_reset')):
            with self.subTest(expected_error=expected_error):
                self.write(prefix, event)
                length = len((json.dumps(event) + '\n').encode())
                snapshot = self.read(max_tail_bytes=length)
                self.assertEqual(snapshot['error'], expected_error)
                if expected_error is None:
                    self.assertEqual(snapshot['tokens'], 120)

    def test_paginated_task_in_old_directory_reads_appended_current_usage(self):
        old_directory = self.rollout.parent / '2026' / '09' / '08'
        old_directory.mkdir(parents=True)
        self.rollout = old_directory / 'rollout.jsonl'
        with sqlite3.connect(self.db) as conn:
            conn.execute('ALTER TABLE threads ADD COLUMN history_mode TEXT')
            conn.execute('UPDATE threads SET rollout_path=?, history_mode=?', (str(self.rollout), 'paginated'))
        self.write(self.usage(120))
        self.assertEqual(self.read()['capturedAt'], 1788868800)
        current = self.usage(150000, 475000)
        current['timestamp'] = '2026-10-22T21:13:42Z'
        with self.rollout.open('a') as handle:
            handle.write(json.dumps(self.event(kind='context_compacted')) + '\n')
        self.assertEqual(self.read()['error'], 'context_reset')
        with self.rollout.open('a') as handle:
            handle.write(json.dumps(current) + '\n')
        snapshot = self.read()
        self.assertEqual(snapshot['tokens'], 150000)
        self.assertEqual(snapshot['window'], 475000)
        self.assertEqual(snapshot['capturedAt'], 1792703622)

    def test_same_task_path_replacement_and_task_switch_do_not_reuse_snapshot(self):
        self.write(self.usage(120))
        self.assertEqual(self.read()['tokens'], 120)
        second = self.home / 'sessions' / 'replacement.jsonl'
        second.write_text(json.dumps(self.usage(240)) + '\n')
        with sqlite3.connect(self.db) as conn:
            conn.execute('UPDATE threads SET rollout_path=? WHERE id=?', (str(second), 'task-a'))
            conn.execute('INSERT INTO threads VALUES (?,?)', ('task-b', str(self.rollout)))
        self.assertEqual(self.read()['tokens'], 240)
        self.assertEqual(read_snapshot('task-b', self.home, self.db)['tokens'], 120)
        self.assertEqual(self.read()['tokens'], 240)

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
