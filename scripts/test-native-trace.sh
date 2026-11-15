#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc benchmarks/native-input-trace.swift benchmarks/native-input-trace-tests.swift -o build/native-input-trace-tests
build/native-input-trace-tests
