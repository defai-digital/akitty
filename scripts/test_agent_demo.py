import importlib.util
import json
import pathlib
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('agent_demo', pathlib.Path(__file__).with_name('agent-demo.py'))
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)


class AgentDemoTests(unittest.TestCase):
    def test_valid_receipt_requires_a_separately_observed_effect(self):
        def invoke(args, **kwargs):
            subprocess.run(['/bin/sh', '-c', args[-1]], check=True)
            return subprocess.CompletedProcess(args, 0, json.dumps(dict(version=1, ok=True, data=dict(
                accepted=True, completion_untrusted=True, input_remains_leased=True, after_command_id=0, event_session='test'))))
        report, status = demo.run_demo('companion', 'pane', invoke=invoke)
        self.assertEqual(status, 0)
        self.assertEqual(report['dispatch'], 'queued')
        self.assertEqual(report['effect'], 'expected_marker_observed')
        self.assertEqual(report['completion'], 'unverified')
        self.assertTrue(report['reclaim_required'])

    def test_queued_input_without_the_expected_effect_is_not_success(self):
        response = dict(version=1, ok=True, data=dict(accepted=True, completion_untrusted=True,
                        input_remains_leased=True, after_command_id=0, event_session='test'))
        report, status = demo.run_demo('companion', 'pane', effect_timeout=.001,
            invoke=lambda args, **kwargs: subprocess.CompletedProcess(args, 0, json.dumps(response)))
        self.assertEqual(status, 1)
        self.assertEqual(report['dispatch'], 'queued')
        self.assertEqual(report['effect'], 'not_observed')

    def test_denial_is_distinct_from_an_uncertain_dispatch(self):
        response = dict(version=1, ok=False, error='Command execution denied.')
        report, status = demo.run_demo('companion', 'pane', expect='denied',
            invoke=lambda args, **kwargs: subprocess.CompletedProcess(args, 1, json.dumps(response)))
        self.assertEqual(status, 0)
        self.assertEqual(report['dispatch'], 'denied')
        self.assertFalse(report['reclaim_required'])

    def test_unknown_or_malformed_results_are_never_retried(self):
        for response in ['not json', json.dumps(dict(version=True, ok=True)),
                         json.dumps(dict(version=1, ok=False, error='Dispatch outcome is unknown.'))]:
            calls = []
            def invoke(args, **kwargs):
                calls.append(args)
                return subprocess.CompletedProcess(args, 1, response)
            report, status = demo.run_demo('companion', 'pane', invoke=invoke)
            self.assertEqual(status, 1)
            self.assertEqual(len(calls), 1)
            self.assertEqual(report['dispatch'], 'unknown')
            self.assertTrue(report['reclaim_required'])

    def test_response_timeout_leaves_an_unknown_outcome_without_retry(self):
        calls = []
        def invoke(args, **kwargs):
            calls.append(args)
            raise subprocess.TimeoutExpired(args, kwargs['timeout'])
        report, status = demo.run_demo('companion', 'pane', invoke=invoke)
        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(report['dispatch'], 'unknown')
        self.assertTrue(report['reclaim_required'])


if __name__ == '__main__':
    unittest.main()
