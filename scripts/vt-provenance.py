#!/usr/bin/env python3
"""Bind the committed WASM to the owned engine's exact source/build inputs."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
files = [root / name for name in ('Cargo.toml', 'Cargo.lock', 'scripts/build-vt-wasm.sh', 'scripts/rust-toolchain.sh')]
files += sorted((root / 'crates/akitty-vt').rglob('*.rs'))
files += [root / 'crates/akitty-vt/Cargo.toml']
inputs = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(files)}
record = {
    'schema': 1,
    'engine': 'akitty-vt',
    'abi': 1,
    'rust': '1.99.1',
    'artifact': 'akitty-vt.wasm',
    'sha256': hashlib.sha256((root / 'packages/akitty-web/akitty-vt.wasm').read_bytes()).hexdigest(),
    'inputs': inputs,
}
manifest = root / 'packages/akitty-web/wasm-provenance.json'
if sys.argv[1:] == ['--write']:
    manifest.write_text(json.dumps(record, indent=2) + '\n')
else:
    assert not sys.argv[1:], 'Usage: vt-provenance.py [--write]'
    assert json.loads(manifest.read_text()) == record, 'WASM/source stamp is stale; rebuild WASM and stamp it'
    print('Owned VT WASM source and artifact hashes verified')
