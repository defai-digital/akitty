#!/usr/bin/env bash
# Build the owned terminal engine. No upstream source fetch or Zig is involved.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/rust-toolchain.sh
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/redacted --remap-path-prefix=$PWD=/akitty"

vt_target_libdir="$("$RUSTC" --print target-libdir --target wasm32-unknown-unknown)"
if command -v wasm-ld >/dev/null 2>&1; then
    export CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_LINKER="$(command -v wasm-ld)"
fi
if [ -d "$vt_target_libdir" ]; then
    cargo build -p akitty-vt --release --target wasm32-unknown-unknown --locked
    if [[ ${AKITTY_VT_CLIPPY:-0} == 1 ]]; then
        cargo clippy -p akitty-vt --release --target wasm32-unknown-unknown --locked -- -D warnings
    fi
else
    # Distribution toolchains such as Homebrew ship Rust sources instead of the
    # WASM std component. Build that component from the matching installed source.
    test -f "$("$RUSTC" --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml" || {
        echo 'Install the wasm32-unknown-unknown Rust target or matching Rust sources.' >&2
        exit 1
    }
    RUSTC_BOOTSTRAP=1 cargo build -p akitty-vt --release --target wasm32-unknown-unknown --locked -Z build-std=std,panic_abort
    if [[ ${AKITTY_VT_CLIPPY:-0} == 1 ]]; then
        RUSTC_BOOTSTRAP=1 cargo clippy -p akitty-vt --release --target wasm32-unknown-unknown --locked -Z build-std=std,panic_abort -- -D warnings
    fi
fi

mkdir -p build
cp target/wasm32-unknown-unknown/release/akitty_vt.wasm build/akitty-vt.wasm
shasum -a 256 build/akitty-vt.wasm
