#!/bin/bash
# Run a local, instrumented AppKit app using the normal PTY/snapshot/raster/Metal code.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Apple Silicon macOS is required.' >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: benchmark-native.sh OUTPUT.json [SAMPLES=60]' >&2; exit 2; }
output=$1
if [[ $output != /* ]]; then output="$PWD/$output"; fi
[[ ! -e $output ]] || { echo 'Output already exists.' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
source scripts/rust-toolchain.sh
export MACOSX_DEPLOYMENT_TARGET=27.2
cargo build --release --locked >&2
export AKITTY_RUST_LIB_DIR="$PWD/target/release"
swift test --package-path macos -c release --filter '^$' >&2
native_bin=$(swift build --package-path macos -c release --show-bin-path)
mkdir -p build
stage=$(mktemp -d "$PWD/build/native-pipeline.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/NativePipelineProbe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.defai.akitty.native-probe</string>
<key>CFBundleExecutable</key><string>NativePipelineProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>27.2</string>
</dict></plist>
PLIST
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macosx27.2 -I "$native_bin" -I macos/Bridge -F "$native_bin" \
  benchmarks/native-pipeline.swift benchmarks/native-input-trace.swift "$native_bin/AkittyKit.o" "$native_bin/AgentIPC.o" \
  -L "$AKITTY_RUST_LIB_DIR" -lakitty_core -framework Sparkle -framework AppKit -framework MetalKit \
  -framework Carbon -framework CoreText -framework JavaScriptCore -framework AppIntents \
  -Xlinker -rpath -Xlinker "$native_bin" -Xlinker -rpath -Xlinker "$AKITTY_RUST_LIB_DIR" \
  -o "$app/Contents/MacOS/NativePipelineProbe"
if [[ -n ${AKITTY_NATIVE_PROBE_SAVE_APP:-} ]]; then
  [[ ! -e $AKITTY_NATIVE_PROBE_SAVE_APP ]] || { echo 'Saved probe app already exists.' >&2; exit 1; }
  ditto "$app" "$AKITTY_NATIVE_PROBE_SAVE_APP"
fi
native_node=$(command -v node)
open -n -W --stdout "$stage/stdout.log" --stderr "$stage/stderr.log" \
  --env "AKITTY_NATIVE_PROBE_SCENES=${AKITTY_NATIVE_PROBE_SCENES:-}" \
  --env "AKITTY_NATIVE_PROBE_PROFILE=${AKITTY_NATIVE_PROBE_PROFILE:-}" \
  --env "AKITTY_NATIVE_PROBE_NODE=$native_node" --env "AKITTY_NATIVE_PROBE_SAMPLES=${2:-60}" --env "AKITTY_NATIVE_PROBE_OUTPUT=$output" "$app"
cat "$stage/stdout.log" "$stage/stderr.log" >&2
[[ -f $output ]] || { echo 'Probe returned without a measurement.' >&2; exit 1; }
