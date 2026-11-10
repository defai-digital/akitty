#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/rust-toolchain.sh
python3 scripts/vt-provenance.py >&2
cargo build --release --locked -p akitty-vt --example benchmark >&2
node scripts/benchmark-vt.ts "$@"
