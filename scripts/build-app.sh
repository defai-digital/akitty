#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'Akitty builds only on macOS.' >&2; exit 1; }
config=${1:-debug}
[[ $config == debug || $config == release ]] || exit 2
export MACOSX_DEPLOYMENT_TARGET=14.0
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$(rustup which --toolchain 1.99.1 rustc)"
commit=$(git rev-parse --verify HEAD 2>/dev/null || true)
dirty=false
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then dirty=true; fi
if [[ -z $commit ]]; then dirty=true; fi
if [[ $config == release ]]; then
    [[ -n $commit ]] || { echo 'Release builds need a resolved Git HEAD.' >&2; exit 1; }
    [[ $dirty == false ]] || { echo 'Release builds must start from a clean committed tree.' >&2; exit 1; }
fi
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
mkdir -p "$app/Contents/Frameworks"
ditto macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
cp third_party/sparkle/LICENSE "$app/Contents/Resources/SPARKLE_LICENSE"
cp macos/Sources/AkittyKit/Resources/features.js "$app/Contents/Resources/features.js"
swift scripts/build-icons.swift
iconutil -c icns build/Akitty.iconset -o "$app/Contents/Resources/Akitty.icns"
cp macos/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 scripts/dependency-licenses.py
cp build/THIRD_PARTY_LICENSES.txt "$app/Contents/Resources/THIRD_PARTY_LICENSES.txt"
# Record the exact source revision before signing, so a stale bundle can never be
# signed or prepared as a newer commit. Release builds must start from a clean
# tree; debug builds may be dirty but say so.
if [[ $config == release ]]; then
    [[ $(git rev-parse HEAD) == "$commit" && -z $(git status --porcelain) ]] || {
        echo 'Source changed during the release build; commit and rebuild.' >&2; exit 1;
    }
fi
python3 - "$app" "$config" "$commit" "$dirty" "$(uname -m)" <<'PYSTAMP'
import json, pathlib, plistlib, sys
app, config, commit, dirty, machine = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4] == 'true', sys.argv[5]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
stamp = {'schema': 1, 'commit': commit or None, 'dirty': dirty, 'configuration': config,
         'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
         'platform': 'macos', 'architecture': machine}
(app / 'Contents/Resources/akitty-build.json').write_text(json.dumps(stamp, indent=2) + '\n')
PYSTAMP
# Local ad-hoc signature. Distribution signing is a separate explicit command.
codesign --force --deep --sign - "$app"
# Only replace the task-owned generated bundle after the complete build succeeds.
# The previous bundle is renamed aside, never deleted first, so a failed swap can
# restore the last good artifact.
target="$PWD/build/Akitty.app"
backup=''
if [[ -e $target ]]; then
    backup=$(mktemp -d "$PWD/build/.app-previous.XXXXXX")
    mv "$target" "$backup/Akitty.app"
fi
if ! mv "$app" "$target"; then
    if [[ -n $backup ]]; then mv "$backup/Akitty.app" "$target"; fi
    echo 'Could not install the new bundle; the previous bundle was restored.' >&2
    exit 1
fi
if [[ -n $backup ]]; then rm -rf "$backup"; fi
echo "$target"
