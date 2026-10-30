#!/usr/bin/env python3
"""Check the exact Git index (or committed tree) before public publication."""
import argparse
import pathlib
import re
import subprocess
import sys

DENIED_DIRS = {'.internal', '.agents', '.agent', '.codex', '.claude', '.grok', '.muse', '.ax-code', '.ax-wiki', '.cursor', '.windsurf', 'node_modules', 'target', '.build'}
DENIED_FILES = {'agents.md', 'agent.md', 'claude.md', 'gemini.md', 'copilot-instructions.md', '.cursorrules', '.windsurfrules', '.ds_store', '.npmrc', '.netrc'}
DENIED_SUFFIXES = {'.pem', '.key', '.p12', '.mobileprovision', '.dylib', '.a', '.log', '.jsonl'}
PATTERNS = [
    re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{40,}'),
    re.compile(rb'\bAKIA[A-Z0-9]{16}\b'),
    re.compile(rb'\bsk-[A-Za-z0-9_-]{32,}\b'),
    re.compile(rb'[A-Za-z0-9._%+-]+@(?:icloud|gmail|hotmail|outlook)\.com', re.I),
]

def violations(name, data):
    path = pathlib.PurePosixPath(name)
    parts = [p.lower() for p in path.parts]
    errors = []
    if any(p in DENIED_DIRS for p in parts) or path.name.lower() in DENIED_FILES or path.suffix.lower() in DENIED_SUFFIXES or path.name.startswith('.env'):
        errors.append('excluded private/generated filename')
    if path.suffix in {'.zig', '.zon'}:
        errors.append('Zig source is prohibited')
    if any(pattern.search(data) for pattern in PATTERNS):
        errors.append('possible credential or private machine/account data')
    return errors

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision', help='scan committed tree instead of staged index')
    args = parser.parse_args()
    cmd = ['git', 'ls-tree', '-r', '--name-only', '-z', args.revision] if args.revision else ['git', 'ls-files', '--cached', '-z']
    files = subprocess.check_output(cmd).decode().split('\0')
    count = 0
    failed = False
    for name in filter(None, files):
        spec = f'{args.revision}:{name}' if args.revision else f':{name}'
        data = subprocess.check_output(['git', 'show', spec])
        for error in violations(name, data):
            print(f'{name}: {error}')
            failed = True
        count += 1
    if not count:
        print('No staged/tracked files to audit; refusing an empty publication check.')
        return 1
    print(f'Public-file audit: {count} files; {"FAILED" if failed else "passed"}.')
    return int(failed)
if __name__ == '__main__':
    sys.exit(main())
