# Reproducible Native/WASM VT benchmark

From the repository root, with the pinned Rust toolchain and Node installed:

```sh
bash scripts/benchmark.sh --samples 30 --rounds 64 --output build/quality/baseline.json
```

Output files are created exclusively; choose a new filename for another run. Both engines consume the same
[synthetic workload manifest](workloads.json): ASCII, ANSI colors, Unicode, long logical lines and alternate-screen
changes. Each sample starts from a fresh 120x40 terminal with 1,000 history rows, feeds repeated approximately
8 KiB chunks, then measures a narrow/restore resize pair. Three warmup samples are discarded per workload/engine.

The native executable uses release-mode Rust calls. WASM uses the committed binary in Node, including its export
call overhead; fixture copying, module compilation, terminal creation, state extraction and destruction are outside
the timed sections. Both use the WASM grapheme support profile explicitly. This is a direct VT engine benchmark,
not a claim about the native renderer's mode 2027 support or browser rendering performance.

The runner checks source/artifact provenance and compares final viewport text, cursor, history length and active
screen before publishing a result. A disagreement, missing sample or invalid timing fails the run. Percentiles use
nearest rank; every raw timing is retained in nanoseconds. Resize timings cover a pair, not an individual resize.
Throughput is derived from actual UTF-8 bytes and median feed time. Small smoke runs have coarse percentiles.

Results include the Git revision/dirty flag, source/workload/harness/binary hashes, CPU model, OS, architecture,
Node/Rust versions and configuration. No username, hostname, home path or terminal contents are collected.
Use these fingerprints when comparing before/after results, especially for a dirty working tree.

`scripts/verify.sh` runs a three-sample correctness smoke with no speed threshold. macOS CI retains its JSON artifact.
Timing changes should be evaluated on the same hardware with repeated runs; hosted runner speed is variable.
The checked-in [macOS arm64 baseline](baseline-macos-arm64.json) records one machine's observations,
including its dirty flag and exact source/harness fingerprints; it is not a release or comparative speed claim.

## Broader product measurements

Measure parser throughput, PTY-to-render throughput and physical key-to-paint latency separately. Pin app versions,
OS, fonts, dimensions, scrollback, workload bytes and visible/hidden pane counts. Record p50/p95/p99 latency,
idle/active CPU, energy and memory across repeated runs, including cleanup and sleep/wake. This harness does not
measure those UI/OS costs and does not support a Kitty/Ghostty/iTerm2/Rex/Warp product ranking.
