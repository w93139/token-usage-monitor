from contextlib import ExitStack
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mcp_server import MCPServer


class MCPContextTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        home = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        rollout = home / 'sessions' / 'usage.jsonl'
        rollout.parent.mkdir()
        rollout.write_text(json.dumps({
            'timestamp': '2026-09-08T12:00:00Z', 'type': 'event_msg',
            'payload': {'type': 'token_count', 'info': {
                'last_token_usage': {'total_tokens': 123},
                'total_token_usage': {'total_tokens': 9999999},
                'model_context_window': 258400}}}) + '\n')
        database = home / 'state_5.sqlite'
        with sqlite3.connect(database) as conn:
            conn.execute('CREATE TABLE threads(id TEXT, rollout_path TEXT)')
            conn.execute('INSERT INTO threads VALUES (?, ?)', ('task-test', str(rollout)))
        self.stack.enter_context(patch.dict(os.environ, {'CODEX_HOME': str(home), 'CODEX_STATE_DB': str(database)}))
        self.monitor_constructor = self.stack.enter_context(patch('mcp_server.UsageMonitor'))
        self.stack.enter_context(patch('mcp_server.atexit.register'))
        self.stack.enter_context(patch('mcp_server.signal.signal'))
        self.server = MCPServer()
        self.sent = []
        self.server.send = self.sent.append

    def assert_no_collection(self):
        self.monitor_constructor.assert_called_once_with()
        self.assertEqual(self.server.monitor.mock_calls, [])

    def test_context_tool_schema_lists_required_thread_id(self):
        self.server.handle({'id': 1, 'method': 'tools/list'})
        tool = next(t for t in self.sent[0]['result']['tools'] if t['name'] == 'get_task_context_usage')
        self.assertEqual(tool['inputSchema']['required'], ['thread_id'])
        self.assertFalse(tool['inputSchema']['additionalProperties'])
        self.assertIn('latest reported', tool['description'])
        self.assert_no_collection()

    def test_call_tool_reads_local_snapshot_without_network_collection(self):
        result = self.server.call_tool('get_task_context_usage', {'thread_id': 'task-test'})
        self.assertEqual(result, {'threadId': 'task-test', 'tokens': 123, 'window': 258400,
                                 'capturedAt': 1788868800, 'source': 'codex_rollout_last_usage', 'error': None})
        self.assert_no_collection()

    def test_handle_unknown_context_returns_structured_unknown(self):
        self.server.handle({'id': 2, 'method': 'tools/call', 'params': {
            'name': 'get_task_context_usage', 'arguments': {'thread_id': 'missing'}}})
        result = self.sent[0]['result']
        self.assertFalse(result['isError'])
        self.assertEqual(result['structuredContent']['error'], 'thread_not_found')
        self.assertIsNone(result['structuredContent']['tokens'])
        self.assertEqual(json.loads(result['content'][0]['text']), result['structuredContent'])
        self.assert_no_collection()

    def test_missing_or_invalid_thread_id_reports_tool_error(self):
        for arguments in ({}, {'thread_id': None}, {'thread_id': 42}, {'thread_id': ''}):
            with self.subTest(arguments=arguments):
                self.server.handle({'id': 3, 'method': 'tools/call', 'params': {
                    'name': 'get_task_context_usage', 'arguments': arguments}})
                self.assertTrue(self.sent[-1]['result']['isError'])
        self.assert_no_collection()


if __name__ == '__main__':
    unittest.main()
