#!/usr/bin/env python3
"""Black-box stdio protocol checks for the compiled companion; no AI service needed."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest


class Session:
    def __init__(self, executable):
        self.directory = tempfile.TemporaryDirectory(prefix='akitty-mcp-protocol-', dir='/tmp')
        path = str(Path(self.directory.name) / 'requests.sock')
        self.process = subprocess.Popen([executable, '--socket', path, 'mcp'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.pending = b''

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b'\n')
        self.process.stdin.flush()

    def request(self, method, params=None, ident=1):
        value = {'jsonrpc': '2.0', 'id': ident, 'method': method}
        if params is not None:
            value['params'] = params
        self.send(value)
        return self.read()

    def read(self):
        deadline = time.monotonic() + 5
        while b'\n' not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise AssertionError('MCP response timed out')
            block = os.read(self.process.stdout.fileno(), 4096)
            if not block:
                raise AssertionError('MCP closed before response')
            self.pending += block
        line, self.pending = self.pending.split(b'\n', 1)
        return json.loads(line)

    def initialize(self):
        response = self.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                               'clientInfo': {'name': 'akitty-protocol-test', 'version': '1'}})
        assert response['result']['protocolVersion'] == '2025-11-25', response
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        return response

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('MCP did not exit on EOF')
        finally:
            self.process.stdout.close()
            self.process.stderr.close()
            self.directory.cleanup()


class MCPProtocolTests(unittest.TestCase):
    executable = None

    def setUp(self):
        self.session = Session(self.executable)
        self.addCleanup(self.session.close)

    def test_handshake_required_and_exact_tool_surface(self):
        response = self.session.request('tools/list')
        self.assertIn('error', response)
        init = self.session.initialize()
        self.assertEqual(set(init['result']['capabilities']), {'tools'})
        tools = self.session.request('tools/list')['result']['tools']
        self.assertEqual([tool['name'] for tool in tools], ['list_panes', 'request_command'])
        self.assertTrue(tools[0]['annotations']['readOnlyHint'])
        self.assertFalse(tools[1]['annotations']['idempotentHint'])
        self.assertTrue(tools[1]['annotations']['destructiveHint'])
        self.assertIn('NOT command completion', tools[1]['description'])

    def test_invalid_arguments_and_unknown_authority_operations(self):
        self.session.initialize()
        invalid = [('control_reclaim', {}), ('request_command', {'pane': 'x', 'command': 'pwd', 'approve': True}),
                   ('request_command', {'pane': 'x', 'command': 'x\ny'}),
                   ('request_command', {'pane': 'x', 'command': '\u200b'}),
                   ('request_command', {'pane': 'x', 'command': '中' * 1366}),
                   ('request_command', {'pane': 'x'}), ('list_panes', {'offset': True}),
                   ('list_panes', {'offset': 65}), ('list_panes', {'offset': '16'}),
                   ('list_panes', {'anything': 'else'})]
        for name, arguments in invalid:
            with self.subTest(name=name, arguments=repr(arguments)[:90]):
                reply = self.session.request('tools/call', {'name': name, 'arguments': arguments})
                self.assertEqual(reply['error']['code'], -32602)

    def test_missing_service_returns_honest_error_and_server_stays_alive(self):
        self.session.initialize()
        reply = self.session.request('tools/call', {'name': 'request_command', 'arguments': {'pane': 'x', 'command': 'pwd'}})
        result = reply['result']
        self.assertTrue(result['isError'])
        self.assertFalse(result['structuredContent']['automatic_retry_allowed'])
        self.assertEqual(result['structuredContent']['completion'], 'unverified')
        self.assertIn('Enable Local Agent Requests', result['content'][0]['text'])
        self.assertIn('result', self.session.request('ping'))

    def test_malformed_json_does_not_dispatch_and_server_recovers(self):
        self.session.initialize()
        self.session.process.stdin.write(b'not-json\n')
        self.session.process.stdin.flush()
        self.assertIn('error', self.session.read())
        self.assertIn('result', self.session.request('ping'))

    def test_oversized_unterminated_input_exits_promptly(self):
        self.session.process.stdin.write(b'x' * 65_537)
        self.session.process.stdin.flush()
        self.session.process.wait(timeout=5)
        self.assertEqual(self.session.process.returncode, 0)

    def test_partial_message_is_not_executed_at_eof(self):
        self.session.initialize()
        self.session.process.stdin.write(b'{"jsonrpc":"2.0","id":99,"method":"tools/call"')
        self.session.process.stdin.close()
        self.session.process.wait(timeout=5)
        self.assertEqual(self.session.process.stdout.read(), b'')

    def test_concurrent_responses_remain_complete_json_frames(self):
        self.session.initialize()
        # Fill more than one pipe buffer with tool schemas to exercise partial writes.
        for ident in range(20):
            self.session.send({'jsonrpc': '2.0', 'id': ident, 'method': 'tools/list'})
        received = [self.session.read() for _ in range(20)]
        self.assertEqual({item['id'] for item in received}, set(range(20)))
        self.assertTrue(all(len(item['result']['tools']) == 2 for item in received))

    def test_eof_can_stop_server_with_backpressured_output(self):
        self.session.initialize()
        for ident in range(30):
            self.session.send({'jsonrpc': '2.0', 'id': ident, 'method': 'tools/list'})
        self.assertTrue(select.select([self.session.process.stdout], [], [], 5)[0])
        # Do not drain stdout: the reader and shutdown must run independently of writes.
        self.session.process.stdin.close()
        self.session.process.wait(timeout=2)
        self.assertEqual(self.session.process.returncode, 0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', required=True, help='compiled akitty-agent executable')
    args, remaining = parser.parse_known_args()
    MCPProtocolTests.executable = str(Path(args.cli).resolve(strict=True))
    unittest.main(argv=[__file__, *remaining])
