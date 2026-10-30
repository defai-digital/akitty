#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'Akitty builds only on macOS.' >&2; exit 1; }
config=${1:-debug}
[[ $config == debug || $config == release ]] || exit 2
export MACOSX_DEPLOYMENT_TARGET=14.0
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$(rustup which --toolchain 1.99.1 rustc)"
npm ci --ignore-scripts
npm run build
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/redacted --remap-path-prefix=$PWD=/akitty"
if [[ $config == release ]]; then cargo build --locked --release; else cargo build --locked; fi
export AKITTY_RUST_LIB_DIR="$PWD/target/$config"
swift build --package-path macos --configuration "$config" -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/akitty"
bin=$(swift build --package-path macos --configuration "$config" --show-bin-path)
mkdir -p build
stage=$(mktemp -d "$PWD/build/.app-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Akitty.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Akitty" "$app/Contents/MacOS/Akitty"
# Remove linker debug-map object paths from the distributable executable.
xcrun strip -S "$app/Contents/MacOS/Akitty"
python3 - "$app/Contents/MacOS/Akitty" <<'PYSCAN'
import pathlib, re, sys
if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', pathlib.Path(sys.argv[1]).read_bytes()):
    raise SystemExit('Packaged executable contains private build paths')
PYSCAN
cp macos/Sources/AkittyKit/Resources/features.js "$app/Contents/Resources/features.js"
swift scripts/build-icons.swift
iconutil -c icns build/Akitty.iconset -o "$app/Contents/Resources/Akitty.icns"
cp macos/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 scripts/dependency-licenses.py
cp build/THIRD_PARTY_LICENSES.txt "$app/Contents/Resources/THIRD_PARTY_LICENSES.txt"
# Local ad-hoc signature. Distribution signing is a separate explicit command.
codesign --force --deep --sign - "$app"
# Only replace the task-owned generated bundle after the complete build succeeds.
if [[ -d "$PWD/build/Akitty.app" ]]; then rm -rf "$PWD/build/Akitty.app"; fi
mv "$app" "$PWD/build/Akitty.app"
echo "$PWD/build/Akitty.app"
