# Terminal throughput improvements

The November 2026 performance pass reduces work in AkiTTY's owned engine and
native PTY worker. It retains the existing ABI, terminal behavior and rendering
architecture. Native Mac app and browser rendering need separate measurements.

## Plan and implementation

1. Measure the existing release-mode engine and native rasterizer before editing.
   Use the current checkout as the baseline, rather than an older release.
2. Pass borrowed printable ASCII runs from the parser to the terminal. Write
   ordinary width-1 spans per row, avoiding character-by-character dispatch,
   Unicode width lookups and repeated screen/mode access. Preserve row generations,
   cursor state, pending wrap, repeat-character state and the last grapheme target.
3. Keep insert mode, character-set shifts, hyperlinks, Unicode grapheme joins and
   wide-cell repair on the scalar path. Reassemble ASCII runs when the existing
   bounded synchronized-output action queue flushes, including timeout flushes.
4. Coalesce available short PTY reads into at most 8 KiB before feeding the model.
   Never wait for a buffer to fill. Flush tails on would-block, EOF and errors;
   preserve the 256 KiB pass budget and release the model lock before every read.
5. Compare full terminal state and ordered events against scalar processing,
   rebuild WASM and its provenance, run the canonical gate and build the app.

These changes are independently implemented in AkiTTY. No external terminal engine
or renderer is linked into the product.

## Measurements

Measured on Apple M3 Max / macOS 27.2.1, Rust 1.99.1 release mode, Node 26.9.0.
Baseline: `3b1d9cf3f8c36121e7ad8764e05050252744b22c` (1.3.26). Candidate identity
is recorded by source and artifact hashes in the [raw measurements](../benchmarks/results/ascii-runs-2026-11-14.json).
Both versions use the same workloads, settings and benchmark code. The new
synchronized-screen workload was also applied to the baseline checkout.

The engine benchmark uses 120 columns, 40 rows, 1,000 history rows, grapheme
support enabled, 8 KiB feed chunks, 128 rounds per sample, three warmups and 30
measured samples. Reported rates use nearest-rank p50; higher is better. The
baseline and candidate were measured sequentially after compilation completed.
Native and WASM final state hashes agree across versions for all six workloads;
this check covers the benchmark's text/cursor/history summary, not every cell
attribute. The differential Rust tests compare the complete terminal debug state
and event stream, including cell attributes, row generations and both screens.

| Workload | Native before MiB/s | Native after MiB/s | Ratio | WASM before MiB/s | WASM after MiB/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 85.2 | 218.0 | 2.56x | 57.4 | 126.5 |
| ANSI color | 76.9 | 121.5 | 1.58x | 56.6 | 91.9 |
| Unicode | 30.9 | 31.2 | 1.01x | 23.9 | 24.5 |
| Long lines | 89.6 | 225.0 | 2.51x | 62.4 | 138.7 |
| Alternate screen | 50.4 | 61.9 | 1.23x | 35.6 | 43.7 |
| Synchronized screen | 73.5 | 93.3 | 1.27x | 62.7 | 77.9 |

The PTY benchmark separately exercises AkiTTY's actual worker/model through the
public request interface: an already-started `/bin/sh` runs `cat` on an 8 MiB
fixture, then sends an OSC title completion marker. Input echo and output newline
translation are disabled. Three warmups precede 11 samples; p50 includes command
dispatch, shell scheduling, file reads, PTY transport, model processing and
completion observation. The observer polls status every millisecond. Snapshots
outside timing verify the final payload marker and absence of a model error.
This is a throughput probe, not exhaustive byte-for-byte PTY conformance.

| PTY workload | Before MiB/s | After MiB/s | Ratio |
| --- | ---: | ---: | ---: |
| ASCII | 60.05 | 98.73 | 1.64x |
| ANSI color | 50.59 | 63.85 | 1.26x |
| Mixed Unicode | 53.41 | 58.43 | 1.09x |

Engine rates exclude the native model, PTY and GPU. PTY rates exclude snapshots,
font shaping, rasterization, GPU presentation and physical keyboard latency.
These results do not establish an overall app speedup or parity with Ghostty.
Ordinary desktop background activity was present; the small Unicode engine
differences should be treated as noise rather than a Unicode optimization.

The initial native rasterizer probe measured about 4.59 ms for a warm 200x50
full repaint at 2x scale, 0.46 ms for a typing update including its snapshot,
1.65 ms for a full texture upload and 0.03 ms for a one-row upload. These are
component timings, not visible frame latency. This pass therefore targets engine
and PTY throughput. A GPU glyph atlas, separate I/O/parser threads and rendering
handoff changes remain candidates for a separately profiled rendering pass.

## Reproduction and regression coverage

```sh
bash scripts/benchmark.sh --samples 30 --rounds 128 --output build/throughput.json
cargo test --release --locked -p akitty-core --test pty_throughput -- --ignored --nocapture
AKITTY_HOTPATH_PROBE=1 AKITTY_RUST_LIB_DIR="$PWD/target/release" \
  swift test --package-path macos -c release --filter HotpathProbe
scripts/verify.sh
scripts/build-app.sh release
```

Build the release Rust core before the native Swift probe. Timing benchmarks are
opt-in; deterministic correctness tests run in the canonical gate without speed
thresholds. Differential tests exercise narrow grids, history limits, split UTF-8
and escapes, styled runs, wrapping, insert mode, DEC graphics, hyperlinks, Unicode,
alternate screens, queries, bells and synchronized output. PTY batching tests
cover short-read coalescing, tails on would-block/EOF/error, split Unicode/query
sequences, reply ordering, model-feed bounds and yielding under endless output.
