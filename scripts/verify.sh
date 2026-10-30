#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'macOS is required.' >&2; exit 1; }
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$(rustup which --toolchain 1.99.1 rustc)"
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --locked
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
npm ci --ignore-scripts
npm run build
npm test
cmp include/akitty.h macos/Bridge/akitty.h
mkdir -p build
clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I include scripts/abi-smoke.c -L target/debug -lakitty_core -framework Security -framework Foundation -o build/abi-smoke
build/abi-smoke
swift test --package-path macos
python3 scripts/test_public.py
if git rev-parse --verify HEAD >/dev/null 2>&1; then python3 scripts/check_public.py --revision HEAD; else python3 scripts/check_public.py; fi
