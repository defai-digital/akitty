#!/usr/bin/env python3
"""One approved command and one separately observed file effect; never retry dispatch."""
import argparse
import hashlib
import json
import pathlib
import secrets
import shlex
import subprocess
import sys
import tempfile
import time


def run_demo(cli, pane, socket=None, expect='approved', effect_timeout=5, invoke=subprocess.run):
    report = dict(schema=1, requested=True, dispatch='unknown', effect='not_observed',
                  completion='unverified', reclaim_required=True, automatically_retried=False)
    with tempfile.TemporaryDirectory(prefix='akitty-agent-demo-') as directory:
        marker = pathlib.Path(directory) / 'effect.txt'
        nonce = secrets.token_hex(24)
        command = 'printf %s ' + shlex.quote(nonce) + ' > ' + shlex.quote(str(marker))
        report['command_sha256'] = hashlib.sha256(command.encode()).hexdigest()
        args = [str(cli)] + (['--socket', str(socket)] if socket else []) + ['request', pane, command]
        try:
            result = invoke(args, capture_output=True, text=True, timeout=135)
            if len(result.stdout.encode()) > 16384:
                raise ValueError('response exceeded the local protocol limit')
            response = json.loads(result.stdout)
            if not isinstance(response, dict) or type(response.get('version')) is not int or response['version'] != 1:
                raise ValueError('invalid response version')
            if response.get('ok') is False and response.get('error') == 'Command execution denied.' and result.returncode != 0:
                report.update(dispatch='denied', reclaim_required=False)
                report['effect'] = 'unexpected_marker' if marker.exists() else 'not_observed'
                return report, 0 if expect == 'denied' and not marker.exists() else 1
            data = response.get('data')
            if (response.get('ok') is not True or result.returncode != 0 or not isinstance(data, dict)
                    or data.get('accepted') is not True or data.get('completion_untrusted') is not True
                    or data.get('input_remains_leased') is not True
                    or type(data.get('after_command_id')) is not int or not 0 <= data['after_command_id'] < 2**64
                    or not isinstance(data.get('event_session'), str) or not data['event_session']):
                raise ValueError('no valid dispatch receipt; inspect the terminal before trying anything else')
            report.update(dispatch='queued', event_session=data['event_session'], after_command_id=data['after_command_id'])
            deadline = time.monotonic() + effect_timeout
            while time.monotonic() < deadline:
                if marker.exists():
                    with marker.open('rb') as effect:
                        observed = effect.read(len(nonce) + 1)
                    report['effect'] = 'expected_marker_observed' if observed == nonce.encode() else 'unexpected_marker'
                    if report['effect'] == 'expected_marker_observed':
                        break
                time.sleep(.02)
            return report, 0 if expect == 'approved' and report['effect'] == 'expected_marker_observed' else 1
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            report['error'] = str(error)[:512]
            return report, 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=pathlib.Path, required=True, help='Path to the bundled akitty-agent companion')
    parser.add_argument('--pane', required=True, help='Explicit pane ID from akitty-agent list')
    parser.add_argument('--socket', type=pathlib.Path)
    parser.add_argument('--expect', choices=['approved', 'denied'], default='approved')
    parser.add_argument('--effect-timeout', type=float, default=5)
    args = parser.parse_args()
    if not 0 < args.effect_timeout <= 60:
        parser.error('effect timeout must be greater than zero and at most 60 seconds')
    print('Review the generated command in AkiTTY. After approval, reclaim terminal control explicitly. Do not retry an unknown outcome.', file=sys.stderr)
    report, status = run_demo(args.cli, args.pane, args.socket, args.expect, args.effect_timeout)
    print(json.dumps(report, sort_keys=True))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
