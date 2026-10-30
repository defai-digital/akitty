#!/usr/bin/env python3
"""Freeze and verify a notarized package, then sign its Sparkle update feed."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key-account', default='akitty')
    args = parser.parse_args()
    if run('git', 'status', '--porcelain'):
        raise SystemExit('Commit and verify the complete release source before preparing assets')
    version = tomllib.loads((ROOT / 'Cargo.toml').read_text())['workspace']['package']['version']
    commit = run('git', 'rev-parse', 'HEAD')
    destination = ROOT / 'build' / 'release' / ('v' + version)
    destination.mkdir(parents=True, exist_ok=False)
    name = f'AkiTTY-{version}-macOS-arm64.zip'
    archive = destination / name
    shutil.copyfile(ROOT / 'build/Akitty-macOS.zip', archive)
    expected = plistlib.loads((ROOT / 'macos/Info.plist').read_bytes())
    with tempfile.TemporaryDirectory(prefix='verify-release-', dir=ROOT / '.internal') as temp:
        run('ditto', '-x', '-k', str(archive), temp)
        app = Path(temp) / 'Akitty.app'
        actual = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        for key in ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString', 'SUPublicEDKey', 'SUFeedURL', 'SURequireSignedFeed']:
            if actual.get(key) != expected.get(key):
                raise SystemExit('Packaged identity differs from source: ' + key)
        if actual['CFBundleShortVersionString'] != version:
            raise SystemExit('Package and workspace versions differ')
        run('codesign', '--verify', '--deep', '--strict', str(app))
        run('spctl', '--assess', '--type', 'execute', str(app))
        run('xcrun', 'stapler', 'validate', str(app))
        if run('lipo', '-archs', str(app / 'Contents/MacOS/Akitty')) != 'arm64':
            raise SystemExit('This release lane expects an Apple Silicon package')
    prefix = f'https://download.automatosx.com/akitty/releases/download/v{version}/'
    notes = ROOT / 'docs/releases' / f'{version}.md'
    shutil.copyfile(notes, archive.with_suffix('.md'))
    tools = ROOT / 'macos/.build/artifacts/sparkle/Sparkle/bin'
    run(str(tools / 'generate_appcast'), '--account', args.key_account, '--maximum-deltas', '0', '--embed-release-notes',
        '--download-url-prefix', prefix, '--link', 'https://github.com/defai-digital/akitty', str(destination))
    archive.with_suffix('.md').unlink()
    content = archive.read_bytes()
    manifest = {'schema': 1, 'version': version, 'build': actual['CFBundleVersion'], 'commit': commit,
                'platform': 'macos', 'architecture': 'arm64', 'minimum_macos': '14.0', 'name': name,
                'url': prefix + name, 'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
    (destination / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
    checksums = []
    for file in [archive, destination / 'release.json', destination / 'appcast.xml']:
        checksums.append(hashlib.sha256(file.read_bytes()).hexdigest() + '  ' + file.name)
    (destination / 'SHA256SUMS').write_text('\n'.join(checksums) + '\n')
    print('Prepared verified release:', destination.relative_to(ROOT))


if __name__ == '__main__':
    main()
