#!/usr/bin/env python3
"""Fail if either maintained terminal component resolves outside this checkout."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1'], cwd=root))
for name in ('alacritty_terminal', 'vte'):
    packages = [package for package in metadata['packages'] if package['name'] == name]
    assert len(packages) == 1, f'{name}: missing or duplicate engine dependency'
    package = packages[0]
    expected = root / 'third_party' / name
    assert package['source'] is None, f'{name}: engine reverted to external source'
    assert Path(package['manifest_path']).resolve() == expected / 'Cargo.toml', f'{name}: unexpected source path'
    origin = json.loads((expected / 'ORIGIN.json').read_text())
    assert origin['crate'] == name and origin['registry_checksum'], f'{name}: missing provenance'
    assert (expected / 'LICENSE-APACHE').is_file(), f'{name}: missing upstream license'
    print(f'{name}: local maintained source; upstream baseline {origin["version"]}')
