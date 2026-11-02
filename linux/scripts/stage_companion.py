#!/usr/bin/env python3
"""Stage the native companion independently of Cargo's configured target directory."""
import json
import pathlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--no-deps", "--format-version", "1",
    "--manifest-path", str(root / "src-tauri/Cargo.toml"),
]))
source = pathlib.Path(metadata["target_directory"]) / "release/akitty-agent"
destination = root / "src-tauri/binaries/akitty-agent"
destination.parent.mkdir(exist_ok=True)
shutil.copy2(source, destination)
