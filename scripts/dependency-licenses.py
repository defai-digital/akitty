#!/usr/bin/env python3
"""Collect license/notice text from the exact locked macOS Rust dependency graph."""
import json
import pathlib
import subprocess
metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--filter-platform','aarch64-apple-darwin']))
parts=['Third-party Rust dependency licenses\nGenerated from Cargo.lock.\n']
for package in sorted(metadata['packages'],key=lambda p:(p['name'],p['version'])):
    if package['source'] is None and package['name'] not in {'alacritty_terminal', 'vte'}: continue
    root=pathlib.Path(package['manifest_path']).parent
    parts.append(f"\n{'='*72}\n{package['name']} {package['version']}\nLicense: {package.get('license','unspecified')}\nSource: {package.get('repository') or package['source']}\n")
    candidates=sorted(p for p in root.rglob('*') if p.is_file() and p.name.lower().startswith(('license','licence','copying','notice')) and p.stat().st_size<100000)
    seen=set()
    for path in candidates:
        text=path.read_text(errors='replace')
        if text not in seen: parts.append(f'\n{path.relative_to(root)}\n{text}');seen.add(text)
    if not candidates: raise SystemExit(f'Missing license file for {package["name"]}; audit before distribution')
pathlib.Path('build').mkdir(exist_ok=True)
pathlib.Path('build/THIRD_PARTY_LICENSES.txt').write_text('\n'.join(parts))
