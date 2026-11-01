#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Linux ]] || { echo 'Linux is required for the experimental desktop gate.' >&2; exit 1; }
export RUSTC="$(rustup which --toolchain 1.99.1 rustc)"
cargo test --locked -p akitty-agent-core
cargo test --manifest-path linux/src-tauri/Cargo.toml --locked --no-default-features
cargo clippy --manifest-path linux/src-tauri/Cargo.toml --locked --no-default-features --all-targets -- -D warnings
npm ci --ignore-scripts --prefix linux
npm --prefix linux run build
python3 linux/scripts/licenses.py
cargo build --manifest-path linux/src-tauri/Cargo.toml --locked --features custom-protocol
cargo clippy --manifest-path linux/src-tauri/Cargo.toml --locked --features custom-protocol --all-targets -- -D warnings
python3 scripts/test_shell_integration.py
