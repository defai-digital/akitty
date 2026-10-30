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
npm ci --ignore-scripts --prefix packages/akitty-sdk
npm --prefix packages/akitty-sdk test
npm ci --ignore-scripts --prefix packages/akitty-web
npm --prefix packages/akitty-web run type-check
npm --prefix packages/akitty-web test
cmp include/akitty.h macos/Bridge/akitty.h
mkdir -p build
clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I include scripts/abi-smoke.c -L target/debug -lakitty_core -framework Security -framework Foundation -o build/abi-smoke
build/abi-smoke
clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I include scripts/sdk-abi-smoke.c -L target/debug -lakitty_core -framework Security -framework Foundation -o build/sdk-abi-smoke
AKITTY_SDK_ABI_SMOKE="$PWD/build/sdk-abi-smoke" node --test packages/akitty-sdk/test/native.test.mjs
swift test --package-path macos
python3 scripts/test_public.py
python3 scripts/test_r2_release.py
python3 scripts/test_prepare_release.py
bash scripts/test_install.sh
if git rev-parse --verify HEAD >/dev/null 2>&1; then python3 scripts/check_public.py --revision HEAD; else python3 scripts/check_public.py; fi
