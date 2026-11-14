#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'Akitty builds only on macOS.' >&2; exit 1; }
config=${1:-debug}
[[ $config == debug || $config == release ]] || exit 2
export MACOSX_DEPLOYMENT_TARGET=27.2
source scripts/rust-toolchain.sh
commit=$(git rev-parse --verify HEAD 2>/dev/null || true)
dirty=false
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then dirty=true; fi
if [[ -z $commit ]]; then dirty=true; fi
if [[ $config == release ]]; then
    [[ -n $commit ]] || { echo 'Release builds need a resolved Git HEAD.' >&2; exit 1; }
    [[ $dirty == false ]] || { echo 'Release builds must start from a clean committed tree.' >&2; exit 1; }
fi
python3 scripts/check-engine-source.py
npm ci --ignore-scripts
npm run build
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/redacted --remap-path-prefix=$PWD=/akitty"
native_library_root="$PWD/target"
if [[ $AKITTY_RUST_DISTRIBUTION == true ]]; then
    # Distribution std archives can target the build machine's newer macOS.
    # Rebuild matching sources at our deployment target instead of shipping them.
    test -f "$("$RUSTC" --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml" || {
        echo 'Distribution Rust requires matching sources to build the macOS 27.2 standard library.' >&2; exit 1;
    }
    native_host_target="$("$RUSTC" -vV | sed -n 's/^host: //p')"
    export RUSTC_BOOTSTRAP=1
    native_library_root="$PWD/target/$native_host_target"
fi
build_native() {
    if [[ $AKITTY_RUST_DISTRIBUTION == true ]]; then
        cargo "$@" -Z build-std=std,panic_unwind --target "$native_host_target"
    else
        cargo "$@"
    fi
}
if [[ $config == release ]]; then build_native build --locked --release; else build_native build --locked; fi
export AKITTY_RUST_LIB_DIR="$native_library_root/$config"
swift build --package-path macos --configuration "$config" -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/akitty"
bin=$(swift build --package-path macos --configuration "$config" --show-bin-path)
mkdir -p build
stage=$(mktemp -d "$PWD/build/.app-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Akitty.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Akitty" "$app/Contents/MacOS/Akitty"
cp "$bin/akitty-agent" "$app/Contents/MacOS/akitty-agent"
# Swift may add a build-only package-framework search path. Bundled frameworks
# live at @executable_path/../Frameworks; remove the private build path before signing.
python3 - "$app/Contents/MacOS/Akitty" "$app/Contents/MacOS/akitty-agent" "$PWD/macos/.build/" <<'PYRPATH'
import subprocess, sys
*binaries, build_root = sys.argv[1:]
for binary in binaries:
    lines = subprocess.check_output(['otool', '-l', binary], text=True).splitlines()
    for index, line in enumerate(lines):
        if line.strip() != 'cmd LC_RPATH':
            continue
        for detail in lines[index + 1:index + 4]:
            value = detail.strip()
            if value.startswith('path '):
                path = value[5:].rsplit(' (offset ', 1)[0]
                if path.startswith(build_root):
                    subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
                break
PYRPATH
# Remove linker debug-map object paths from the distributable executable.
xcrun strip -S "$app/Contents/MacOS/Akitty"
xcrun strip -S "$app/Contents/MacOS/akitty-agent"
python3 - "$app/Contents/MacOS/Akitty" "$app/Contents/MacOS/akitty-agent" <<'PYSCAN'
import pathlib, re, sys
for executable in sys.argv[1:]:
    data = pathlib.Path(executable).read_bytes()
    if any(name in data.lower() for name in (b'alacritty_terminal', b'ghostty_', b'ghostty-vt.wasm', b'vte::')):
        raise SystemExit('Packaged executable contains an obsolete engine')
    if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', data):
        raise SystemExit('Packaged executable contains private build paths')
PYSCAN
mkdir -p "$app/Contents/Frameworks"
ditto macos/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
cp third_party/sparkle/LICENSE "$app/Contents/Resources/SPARKLE_LICENSE"
mkdir -p "$app/Contents/Resources/shell-integration"
for resource in .zshenv akitty.bash akitty.zsh bashrc; do
    cp "macos/Sources/AkittyKit/Resources/shell-integration/$resource" "$app/Contents/Resources/shell-integration/$resource"
done
cp macos/Sources/AkittyKit/Resources/features.js "$app/Contents/Resources/features.js"
# AppKit loads these credits in the standard About panel from Bundle.main.
cp macos/Sources/AkittyKit/Resources/Credits.html "$app/Contents/Resources/Credits.html"
swift scripts/build-icons.swift
iconutil -c icns build/Akitty.iconset -o "$app/Contents/Resources/Akitty.icns"
cp macos/Info.plist "$app/Contents/Info.plist"
python3 scripts/build-siri-metadata.py --build-dir "$PWD/macos/.build" --configuration "$config" --resources "$app/Contents/Resources" --binary "$app/Contents/MacOS/Akitty"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp third_party/unicode/LICENSE "$app/Contents/Resources/UNICODE_LICENSE"
# features.js carries the adapted AX TUI ranking, so its MIT notice ships with it.
cp third_party/ax-tui/LICENSE "$app/Contents/Resources/AX_TUI_LICENSE"
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
