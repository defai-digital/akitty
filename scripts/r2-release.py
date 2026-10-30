#!/usr/bin/env python3
"""Isolated R2 delivery: immutable assets, byte verification, then update feed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://download.automatosx.com/akitty'
BUCKET = 'akitty-releases'
WORKER = 'akitty-downloads'
ROUTE = 'download.automatosx.com/akitty/*'
REPO = 'defai-digital/akitty'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def credential():
    token = os.environ.get('CLOUDFLARE_API_TOKEN')
    if token is None:
        path = Path.home() / '.cf'
        require(path.stat().st_size <= 4096, 'Credential file is too large')
        token = path.read_text().strip()
    require(bool(token) and not any(c.isspace() for c in token), 'Expected a single API token')
    return token


def fetch(url, *, method='GET', data=None, headers=None, missing=False):
    request = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=240) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if missing and error.code == 404:
            return None
        # Never print response bodies or authorization headers.
        raise RuntimeError(f'{method} failed with HTTP {error.code}') from None


class Cloudflare:
    def __init__(self):
        self.token = credential()
        zones = self.api('/zones?name=automatosx.com')['result']
        require(len(zones) == 1, 'Expected exactly one automatosx.com zone')
        self.zone = zones[0]['id']
        self.account = zones[0]['account']['id']

    def api(self, path, method='GET', body=None, raw=None, content_type='application/json', missing=False):
        data = json.dumps(body).encode() if body is not None else raw
        result = fetch('https://api.cloudflare.com/client/v4' + path, method=method, data=data,
                       headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': content_type}, missing=missing)
        if result is None:
            return None
        value = json.loads(result)
        require(value.get('success') is True, 'Cloudflare API rejected the operation')
        return value

    def inspect(self):
        domains = self.api(f'/accounts/{self.account}/workers/domains')['result']
        domain = next((d for d in domains if d['hostname'] == 'download.automatosx.com'), None)
        require(domain and domain['service'] == 'ax-code-downloads', 'Shared download domain ownership changed')
        routes = self.api(f'/zones/{self.zone}/workers/routes')['result']
        own = [r for r in routes if r['pattern'] == ROUTE]
        require(len(own) <= 1 and all(r.get('script') == WORKER for r in own), 'AkiTTY route belongs to another Worker')
        buckets = self.api(f'/accounts/{self.account}/r2/buckets')['result']['buckets']
        return {'domain': domain, 'route': own[0] if own else None, 'bucket': any(b['name'] == BUCKET for b in buckets)}

    def gateway(self, deploy):
        before = self.inspect()
        if deploy:
            if not before['bucket']:
                self.api(f'/accounts/{self.account}/r2/buckets', 'POST', {'name': BUCKET})
            metadata = {'main_module': 'worker.mjs', 'compatibility_date': '2026-10-29',
                        'bindings': [{'type': 'r2_bucket', 'name': 'RELEASES', 'bucket_name': BUCKET}]}
            boundary = 'akitty-' + uuid.uuid4().hex
            parts = []
            for name, kind, data in [('metadata', 'application/json', json.dumps(metadata).encode()),
                                     ('worker.mjs', 'application/javascript+module', (ROOT / 'distribution/worker.mjs').read_bytes())]:
                parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{name}"\r\nContent-Type: {kind}\r\n\r\n'.encode() + data + b'\r\n')
            parts.append(f'--{boundary}--\r\n'.encode())
            self.api(f'/accounts/{self.account}/workers/scripts/{WORKER}', 'PUT', raw=b''.join(parts), content_type='multipart/form-data; boundary=' + boundary)
            if not before['route']:
                self.api(f'/zones/{self.zone}/workers/routes', 'POST', {'pattern': ROUTE, 'script': WORKER})
        after = self.inspect()
        require(after['bucket'] and after['route'], 'Gateway is not deployed')
        require(before['domain'] == after['domain'], 'Shared download domain changed')
        print('Gateway verified:', WORKER, BUCKET, ROUTE)

    def storage(self, key, data=None):
        require(re.fullmatch(r'[A-Za-z0-9/_.-]+', key) and '..' not in key.split('/'), 'Invalid object key')
        kind = 'application/xml' if key.endswith('.xml') else 'application/json' if key.endswith('.json') else 'application/zip' if key.endswith('.zip') else 'text/plain'
        return fetch(f'https://api.cloudflare.com/client/v4/accounts/{self.account}/r2/buckets/{BUCKET}/objects/{key}',
                     method='GET' if data is None else 'PUT', data=data, missing=data is None,
                     headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': kind})


def public(key):
    return fetch(BASE + '/' + key, headers={'User-Agent': 'akitty-release-verifier', 'Cache-Control': 'no-cache'}, missing=True)


def put_verified(cloud, key, data, mutable=False):
    previous = cloud.storage(key)
    require(previous is None or previous == data or mutable, 'Refusing to replace immutable object: ' + key)
    if previous != data:
        cloud.storage(key, data)
    require(cloud.storage(key) == data, 'Stored bytes differ: ' + key)
    require(public(key) == data, 'Public bytes differ: ' + key)
    print('Verified:', key, flush=True)


def validate_assets(release, tag, files):
    require(release.get('tag_name') == tag and release.get('draft') is False and release.get('prerelease') is False, 'Expected the published stable release')
    assets = {asset['name']: asset for asset in release.get('assets', [])}
    require(set(files) <= assets.keys(), 'GitHub release is missing required assets')
    for name, data in files.items():
        asset = assets[name]
        require(asset.get('size') == len(data) and asset.get('digest') == 'sha256:' + hashlib.sha256(data).hexdigest(), 'GitHub integrity metadata differs: ' + name)


def publish(tag, source):
    require(re.fullmatch(r'v\d+\.\d+\.\d+', tag), 'Expected vX.Y.Z')
    version = tag[1:]
    names = [f'AkiTTY-{version}-macOS-arm64.zip', 'SHA256SUMS', 'release.json', 'appcast.xml']
    # Capture exact bytes before any network mutation.
    files = {name: (source / name).read_bytes() for name in names}
    require(all(len(data) < 300 * 1024 * 1024 for data in files.values()), 'Asset exceeds REST upload limit')
    manifest = json.loads(files['release.json'])
    require(manifest['version'] == version and re.fullmatch(r'[a-f0-9]{40}', manifest['commit']), 'Invalid release identity')
    archive = names[0]
    require(manifest['sha256'] == hashlib.sha256(files[archive]).hexdigest() and manifest['size'] == len(files[archive]), 'Release manifest differs from archive')
    release = json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/releases/tags/{tag}']))
    validate_assets(release, tag, files)
    cloud = Cloudflare(); cloud.gateway(False)
    existing = public('latest.json')
    if existing:
        current = json.loads(existing)['version']
        require(tuple(map(int, current.split('.'))) <= tuple(map(int, version.split('.'))), 'Refusing to move latest backwards')
    prefix = 'releases/download/' + tag + '/'
    for name, data in files.items():
        put_verified(cloud, prefix + name, data)
    ready = json.dumps({'tag': tag, 'commit': manifest['commit'], 'verified': True, 'assets': len(files)}, sort_keys=True).encode() + b'\n'
    put_verified(cloud, prefix + 'release-ready.json', ready)
    put_verified(cloud, 'latest.json', files['release.json'], mutable=True)
    put_verified(cloud, 'install', (ROOT / 'scripts/install.sh').read_bytes(), mutable=True)
    # The signed feed is the updater's discovery point. Publish it last.
    put_verified(cloud, 'appcast.xml', files['appcast.xml'], mutable=True)
    print('R2 publication complete:', tag)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['gateway-check', 'gateway-deploy', 'publish'])
    parser.add_argument('--tag')
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    if args.command == 'publish':
        require(args.tag and args.source, 'publish needs --tag and --source')
        publish(args.tag, args.source)
    else:
        Cloudflare().gateway(args.command == 'gateway-deploy')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
