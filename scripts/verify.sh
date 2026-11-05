#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin ]] || { echo 'macOS is required.' >&2; exit 1; }
source scripts/rust-toolchain.sh
export MACOSX_DEPLOYMENT_TARGET=14.0
python3 scripts/test_rust_toolchain.py
cargo build --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
python3 scripts/check-engine-source.py
AKITTY_VT_CLIPPY=1 bash scripts/build-vt-wasm.sh
node scripts/test-vt-wasm.mjs
node scripts/test-vt-wasm.mjs packages/akitty-web/akitty-vt.wasm
quality_run_dir=$(mktemp -d "$PWD/build/quality-smoke.XXXXXX")
bash scripts/benchmark.sh --samples 3 --rounds 2 --output "$quality_run_dir/benchmark.json"
node --test scripts/benchmark-vt.test.mjs
npm ci --ignore-scripts
npm run build
npm test
npm ci --ignore-scripts --prefix packages/akitty-sdk
npm --prefix packages/akitty-sdk test
npm ci --ignore-scripts --prefix packages/akitty-web
npm --prefix packages/akitty-web run type-check
npm --prefix packages/akitty-web test
npm --prefix packages/akitty-web exec -- playwright install chromium firefox webkit
npm --prefix packages/akitty-web run test:browser
cmp include/akitty.h macos/Bridge/akitty.h
mkdir -p build
clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I include scripts/abi-smoke.c -L target/debug -lakitty_core -framework Security -framework Foundation -o build/abi-smoke
build/abi-smoke
clang -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I include scripts/sdk-abi-smoke.c -L target/debug -lakitty_core -framework Security -framework Foundation -o build/sdk-abi-smoke
AKITTY_SDK_ABI_SMOKE="$PWD/build/sdk-abi-smoke" node --test packages/akitty-sdk/test/native.test.mjs
swift test --package-path macos
python3 scripts/test_shell_integration.py
python3 scripts/test_agent_demo.py
python3 scripts/test_public.py
python3 scripts/test_r2_release.py
python3 scripts/test_prepare_release.py
bash scripts/test_install.sh
python3 scripts/check_public.py
