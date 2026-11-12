#!/usr/bin/env python3
"""Collect Rust licenses and resolved Swift package notices for macOS distribution."""
import json
import pathlib
import subprocess
import sys
metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--filter-platform','aarch64-apple-darwin']))
selected = None
if sys.argv[1:] == ['--vt']:
    nodes = {node['id']: node for node in metadata['resolve']['nodes']}
    start = next(p['id'] for p in metadata['packages'] if p['name'] == 'akitty-vt')
    selected = set()
    pending = [start]
    while pending:
        package_id = pending.pop()
        if package_id in selected: continue
        selected.add(package_id)
        pending.extend(dep['pkg'] for dep in nodes[package_id]['deps']
                       if any(kind['kind'] != 'dev' for kind in dep['dep_kinds']))
elif sys.argv[1:]:
    raise SystemExit('Usage: dependency-licenses.py [--vt]')
parts=['Third-party Rust dependency licenses\nGenerated from Cargo.lock.\n']
for package in sorted(metadata['packages'],key=lambda p:(p['name'],p['version'])):
    if package['source'] is None or (selected is not None and package['id'] not in selected): continue
    root=pathlib.Path(package['manifest_path']).parent
    parts.append(f"\n{'='*72}\n{package['name']} {package['version']}\nLicense: {package.get('license','unspecified')}\nSource: {package.get('repository') or package['source']}\n")
    candidates=sorted(p for p in root.rglob('*') if p.is_file() and p.name.lower().startswith(('license','licence','copying','notice')) and p.stat().st_size<100000)
    seen=set()
    for path in candidates:
        text=path.read_text(errors='replace')
        if text not in seen: parts.append(f'\n{path.relative_to(root)}\n{text}');seen.add(text)
    if not candidates: raise SystemExit(f'Missing license file for {package["name"]}; audit before distribution')
if selected is None:
    # The Swift SDK's complete resolution includes build tools and optional products.
    # Include every resolved checkout notice rather than accidentally omitting one.
    lock = json.loads(pathlib.Path('macos/Package.resolved').read_text())
    checkouts = pathlib.Path('macos/.build/checkouts')
    for pin in lock['pins']:
        identity = pin['identity']
        if identity == 'sparkle': continue  # Its binary distribution notice is bundled separately.
        root = next((p for p in checkouts.iterdir() if p.name.lower() == identity.lower()), None)
        if root is None: raise SystemExit(f'Missing resolved Swift checkout for {identity}')
        parts.append(f"\n{'='*72}\nSwift package: {identity}\nRevision: {pin['state']['revision']}\nSource: {pin['location']}\n")
        candidates = sorted(p for p in root.iterdir() if p.is_file() and p.name.lower().startswith(('license', 'licence', 'copying', 'notice')))
        if not candidates: raise SystemExit(f'Missing Swift license file for {identity}')
        for path in candidates: parts.append(f'\n{path.name}\n{path.read_text(errors="replace")}')
pathlib.Path('build').mkdir(exist_ok=True)
pathlib.Path('build/VT_LICENSES.txt' if selected is not None else 'build/THIRD_PARTY_LICENSES.txt').write_text('\n'.join(parts))
