#!/usr/bin/env python3
"""Check the exact Git index (or committed tree) before public publication.

With --messages, check commit messages and author/committer identities instead:
history is published with the tree and is far harder to correct afterwards.
"""
import argparse
import getpass
import hashlib
import os
import pathlib
import re
import subprocess
import sys

DENIED_DIRS = {'.internal', '.agents', '.agent', '.codex', '.claude', '.grok', '.muse', '.ax-code', '.ax-wiki', '.cursor', '.windsurf', 'node_modules', 'target', '.build'}
DENIED_FILES = {'agents.md', 'agent.md', 'claude.md', 'gemini.md', 'copilot-instructions.md', '.cursorrules', '.windsurfrules', '.ds_store', '.npmrc', '.netrc', '.cf', '.zsh_history', '.bash_history'}
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

# Audited upstream license text includes public author email attribution.
# Only the exact notice bytes are exempt from the personal-email heuristic.
PUBLIC_NOTICE_HASHES = {
    "third_party/sparkle/LICENSE": "816be66341dd11b22806862dffd8392b240babaced1cdf24da2ff413ef00c3fd",
}

def violations(name, data):
    path = pathlib.PurePosixPath(name)
    parts = [p.lower() for p in path.parts]
    errors = []
    if any(p in DENIED_DIRS for p in parts) or path.name.lower() in DENIED_FILES or path.suffix.lower() in DENIED_SUFFIXES or path.name.startswith('.env'):
        errors.append('excluded private/generated filename')
    if path.suffix in {'.zig', '.zon'}:
        errors.append('Zig source is prohibited')
    public_notice = PUBLIC_NOTICE_HASHES.get(name) == hashlib.sha256(data).hexdigest()
    patterns = PATTERNS[:-1] if public_notice else PATTERNS
    if any(pattern.search(data) for pattern in patterns):
        errors.append('possible credential or private machine/account data')
    return errors

# Prose such as "a sibling such as /Users/alice2" names no real account, so a
# message may mention a home directory only for these placeholder accounts.
HOME_DIR = re.compile(rb'/(?:Users|home)/([A-Za-z0-9_.-]+)')
PLACEHOLDER_ACCOUNT = re.compile(rb'(?:alice|bob|example|user|username|name|me|you|runner|shared)[0-9]*', re.I)

def message_violations(text, private_words=()):
    errors = []
    # PATTERNS[0] (any home path) is replaced by the placeholder-aware HOME_DIR check.
    if any(pattern.search(text) for pattern in PATTERNS[1:]):
        errors.append('possible credential or private machine/account data')
    if any(not PLACEHOLDER_ACCOUNT.fullmatch(m.group(1)) for m in HOME_DIR.finditer(text)):
        errors.append('home directory of a real-looking account')
    for word in private_words:
        if re.search(rb'(?<![A-Za-z0-9])' + re.escape(word) + rb'(?![A-Za-z0-9])', text, re.I):
            errors.append('local login name')
    return errors

def local_private_words():
    # The developer's own login is a private identifier on their machine; CI
    # runner accounts are not, and generic short names would be too noisy.
    if os.environ.get('CI'):
        return ()
    try:
        login = getpass.getuser()
    except Exception:
        return ()
    if len(login) < 5 or PLACEHOLDER_ACCOUNT.fullmatch(login.encode()):
        return ()
    return (login.encode(),)

def audit_messages(revision):
    log = subprocess.check_output(['git', 'log', '-z', '--format=%H%n%an <%ae>%n%cn <%ce>%n%B', revision])
    words = local_private_words()
    count = 0
    failed = False
    for entry in filter(None, log.split(b'\0')):
        commit, _, text = entry.partition(b'\n')
        for error in message_violations(text, words):
            print(f'commit {commit.decode()[:12]}: {error}')
            failed = True
        count += 1
    print(f'Commit-message audit: {count} commits; {"FAILED" if failed else "passed"}.')
    return int(failed)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--revision', help='scan committed tree instead of staged index')
    parser.add_argument('--messages', metavar='REVISION', help='scan commit messages and identities reachable from REVISION')
    args = parser.parse_args()
    if args.messages:
        return audit_messages(args.messages)
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
