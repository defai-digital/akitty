"""Build the companion without desktop resources, then stage it for the wrapper."""
import json
import pathlib
import shutil
import subprocess
root = pathlib.Path(__file__).resolve().parents[2]
manifest = root / 'windows/src-tauri/Cargo.toml'
metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--no-deps', '--format-version', '1', '--manifest-path', str(manifest)]))
target = pathlib.Path(metadata['target_directory'])
subprocess.run(['cargo', 'build', '--manifest-path', str(root / 'linux/src-tauri/Cargo.toml'), '--locked', '--release', '--no-default-features', '--bin', 'akitty-agent', '--target-dir', str(target)], check=True)
destination = root / 'windows/src-tauri/binaries/akitty-agent.exe'
destination.parent.mkdir(exist_ok=True)
shutil.copy2(target / 'release/akitty-agent.exe', destination)
