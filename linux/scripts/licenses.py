#!/usr/bin/env python3
"""Collect exact locked Rust and bundled JavaScript licenses for the Linux app."""
import json
import hashlib
import os
import pathlib
import platform
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
linux = root / "linux"
desktop_package = pathlib.Path(os.environ.get("AKITTY_DESKTOP_PACKAGE", str(linux)))
arch = "aarch64" if platform.machine() in {"aarch64", "arm64"} else "x86_64"
target = os.environ.get("AKITTY_LINUX_TARGET", f"{arch}-unknown-linux-gnu")
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", target,
    "--manifest-path", str(desktop_package / "src-tauri/Cargo.toml"),
]))
parts = ["AkiTTY Experimental desktop — third-party licenses\nGenerated from the locked dependency graph.\n"]
fallbacks = json.loads((linux / "licenses/manifest.json").read_text(encoding="utf-8"))
for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
    if package["source"] is None and package["name"] != "vte":
        continue
    directory = pathlib.Path(package["manifest_path"]).parent
    candidates = sorted(path for path in directory.rglob("*") if path.is_file()
                        and path.name.lower().startswith(("license", "licence", "copying", "notice"))
                        and path.stat().st_size < 100000)
    if not candidates:
        fallback = fallbacks.get(f"{package['name']}@{package['version']}")
        if not fallback:
            raise SystemExit(f"Missing license files for {package['name']}; audit before packaging")
        path = linux / "licenses" / fallback["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != fallback["sha256"]:
            raise SystemExit(f"License hash mismatch for {package['name']}")
        parts.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\nLicense: {package.get('license')}\n"
                     f"Notice source: {fallback['source']}\n"
                     f"Unmodified package source: https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download\n"
                     f"{path.read_text(encoding="utf-8")}")
        continue
    parts.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\nLicense: {package.get('license')}\nSource: {package.get('repository') or package['source']}\n")
    seen = set()
    for path in candidates:
        text = path.read_text(encoding="utf-8", errors="replace")
        if text not in seen:
            parts.append(f"\n{path.relative_to(directory)}\n{text}")
            seen.add(text)
for path in [root / "LICENSE", root / "packages/akitty-web/LICENSE", root / "packages/akitty-web/LICENSE-GHOSTTY",
             linux / "node_modules/@tauri-apps/api/LICENSE-MIT", linux / "node_modules/@tauri-apps/api/LICENSE-APACHE-2.0"]:
    parts.append(f"\n{'=' * 72}\n{path.relative_to(root)}\n{path.read_text(encoding="utf-8")}")
(desktop_package / "THIRD_PARTY_LICENSES.txt").write_text("\n".join(parts), encoding="utf-8")
