#!/usr/bin/env python3
"""Verify production dependency resolution and owned WASM artifact provenance."""
import json
from pathlib import Path
import re
import subprocess
from check_public import violations

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1'], cwd=root))
packages = {package['id']: package for package in metadata['packages']}
for name in ('akitty-core', 'akitty-vt'):
    matches = [p for p in packages.values() if p['name'] == name]
    assert len(matches) == 1, f'{name}: missing or duplicate package'
    package = matches[0]
    assert package['source'] is None, f'{name}: must be owned source'
    assert Path(package['manifest_path']).resolve() == root / 'crates' / name / 'Cargo.toml'
for package in packages.values():
    assert not re.search(r'alacritty|ghostty|(^|[-_])vte($|[-_])', package['name'], re.I), f'Forbidden engine: {package["name"]}'
for obsolete in ('third_party/alacritty', 'third_party/alacritty_terminal', 'third_party/vte',
                 'packages/akitty-web/ghostty-vt.wasm', 'packages/akitty-web/lib/ghostty.ts',
                 'packages/akitty-web/patches/ghostty-wasm-api.patch'):
    assert not (root / obsolete).exists(), f'Obsolete implementation remains: {obsolete}'
web = root / 'packages/akitty-web'
assert not violations('akitty-vt.wasm', (web / 'akitty-vt.wasm').read_bytes()), 'WASM contains private build data'
exports = json.loads((web / 'package.json').read_text())['exports']
assert './akitty-vt.wasm' in exports and './ghostty-vt.wasm' not in exports
for path in (web / 'lib').rglob('*.ts'):
    if path.name.endswith('.test.ts') or path.name == 'test-helpers.ts':
        continue
    assert not re.search(r'ghostty|alacritty|@cmux', path.read_text(), re.I), f'Old engine binding: {path.relative_to(root)}'
subprocess.run(['python3', 'scripts/vt-provenance.py'], cwd=root, check=True)
subprocess.run(['node', '--input-type=module', '-e', '''
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const module = new WebAssembly.Module(readFileSync('packages/akitty-web/akitty-vt.wasm'));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const exports = WebAssembly.Module.exports(module);
assert(exports.some(e => e.name === 'akitty_vt_abi_version'));
for (const e of exports) assert(e.name.startsWith('akitty_vt_') || ['memory', '__data_end', '__heap_base'].includes(e.name), e.name);
'''], cwd=root, check=True)
print('Native/WASM dependency graph uses owned akitty-vt; obsolete engine sources and exports absent')
