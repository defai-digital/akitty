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

## Row-reset and CSI follow-up

The source review and CPU samples identified full recycled-row clearing, row
movement and ANSI parameter allocations as separate costs. This pass addresses
those costs before changing rendering or cell storage:

1. Retain the last blank background and a conservative modified-prefix bound.
   Track written spaces, styles, combining marks, hyperlinks and wide-cell repairs,
   rather than deriving the bound from visible text. Complex scalar writes
   conservatively invalidate the whole bound, avoiding per-scalar range tracking.
   Clear only that prefix when the requested background matches; changing backgrounds, resizing/reflowing or
   an untracked generation change requires a full reset. Recycling retains the
   bound and background along with the cell allocation. Full clears still release
   heap-owned cells and update history accounting and row generations. Wide writes
   skip pre-clearing a span only when no wide neighbour outside it needs repair,
   preserving generation advances.
2. Store visible rows in the standard library's deque. Full-screen scrolling
   rotates logical rows without shifting all row records. Region scrolling keeps
   its existing bounds, identities, history and event semantics.
3. Borrow a completed CSI during the terminal callback, retaining its bounded
   parameter allocations for reuse. The public parser action API still returns
   owned actions; synchronized output takes CSI data into its existing bounded
   queue. Semicolon RGB decoding uses three stack slots instead of a temporary
   vector. Parameter, subparameter and malformed-input limits are unchanged.
4. Differentially compare prefix resets against conservative full resets across
   background changes, written spaces, editing, Unicode, links, history, screen
   switches and resizing. Compare borrowed and owned CSI actions across byte
   boundaries, cancellation and overflow; retain synchronized-output tests.
5. Rebuild committed WASM/provenance, run the canonical gate and build the app,
   commit the implementation, then remeasure release-mode engine and actual PTY
   throughput against the pinned parent on the same machine.

The implementation is independently authored. Reference review informed the
reset-range and logical-row-rotation concepts; no external implementation is
copied or linked. Display-link changes, unfocused-pane pacing, texture damage
history, compact cells and a GPU glyph atlas remain separate follow-up work.

### Committed-candidate remeasurement

Baseline: `12ddfbd473638b089ecd15c48fda71f3e534e1d6`.
Implementation: `63f835d7282db254801c7e598c37c1ac1dac1bd2`.
Both were measured from clean committed trees after the implementation commit,
with the same harness and fixture hashes on Apple M3 Max / macOS 27.2.1,
Rust 1.99.1 and Node 26.13.1. All raw samples, configuration, source/artifact
fingerprints and qualifications are retained in the
[measurement record](../benchmarks/results/row-reset-csi-2026-11-14.json).

The canonical native/WASM engine measurement uses the same 120x40 grid, 1,000
history rows, 128 rounds, three warmups and 30 samples per condition described
above. Grapheme support is enabled on both builds. Rates are MiB/s at p50:

| Workload | Native before | Native after | Ratio | WASM before | WASM after |
| --- | ---: | ---: | ---: | ---: | ---: |
| ascii | 219.5 | 319.9 | 1.46x | 130.2 | 183.0 |
| ansi | 123.7 | 218.5 | 1.77x | 92.2 | 149.9 |
| unicode | 31.7 | 31.7 | 1.00x | 24.6 | 25.1 |
| long-lines | 226.5 | 230.5 | 1.02x | 139.9 | 144.4 |
| alternate-screen | 62.2 | 67.7 | 1.09x | 44.0 | 44.7 |
| synchronized-screen | 93.4 | 91.6 | 0.98x | 76.7 | 76.3 |

Unicode throughput is effectively unchanged. Long-line and small WASM differences
should not be read as broad gains. Native synchronized-screen throughput is
about 2% lower in this run; the pass does not improve every workload. All six
native/WASM final text/cursor/history/active-screen summary hashes agree across
versions. The deterministic tests separately compare cells, styles, generations,
history accounting and events. A cross-version replay also matched both screens,
cell contents/attributes, row identities/generations, public metadata and events
for six settings with 1,000 operations each; reset certificates and parser scratch
are excluded from that replay.

The actual product PTY worker uses native defaults, with grapheme support off.
It repeats the same 8 MiB transport probe with three warmups and 11 samples:

| PTY workload | Before MiB/s | After MiB/s | Ratio |
| --- | ---: | ---: | ---: |
| ascii | 96.74 | 111.36 | 1.15x |
| ansi | 63.32 | 84.80 | 1.34x |
| unicode | 58.55 | 61.27 | 1.05x |

These are worker/model throughput improvements, excluding snapshots and rendering.
The Unicode mode and fixture differ from the canonical engine measurement; their
absolute rates are not interchangeable.

A separate local benchmark links the official, pinned `libghostty-vt 1.0.1` only
into a benchmark executable. Both libraries receive identical inputs through the
same C host: 120x40, history disabled, grapheme support enabled, 256 rounds,
three warmups and 30 samples, with randomized paired execution order (seed
314159). Every sample compares active/history cell text, widths, styles,
wrapping and cursor metadata after feeding and after each narrow/restore resize.
All accepted comparisons match. Native-default mixed-emoji comparisons are
excluded because their cell-width policies differ.

| Workload | Ghostty/native engine ratio before | After | Ghostty/common PTY host ratio before | After |
| --- | ---: | ---: | ---: | ---: |
| ascii | 5.60x | 3.66x | 1.19x | 1.11x |
| ansi | 2.57x | 1.44x | 1.57x | 1.04x |
| unicode | 5.97x | 5.98x | 4.97x | 4.91x |

The common PTY host is not AkiTTY's actual worker or Ghostty's app. It isolates a
shared transport path, excluding both applications' rendering. The Unicode
comparison uses grapheme mode on and does not describe the Mac app's default
Unicode behavior. These results narrow ASCII/ANSI throughput gaps; they do not
establish full-app parity, physical input latency, or Unicode parity.

The canonical gate passed locally, including 55 VT unit tests, two shared
contracts, Rust workspace tests/clippy, WASM, TypeScript, ABI, Swift, release
tooling, installer and public-file checks. Chromium and WebKit passed. The
existing macOS Firefox startup failure caused the configured local Firefox skip;
Firefox CI qualification remains outstanding. Swift ran 382 tests with three
opt-in skips and no failures. Debug and clean committed release app builds,
three-second startup smokes and ad-hoc signature verification passed. No
notarization or release publication was performed.

## Native pipeline follow-up

This pass measures the native host before changing its scheduling. The opt-in
`scripts/benchmark-native.sh OUTPUT.json [SAMPLES=60]` builds a local AppKit probe
from the normal release testable modules. It opens a focused 1360x900-point
window, drives real PTYs, and exercises snapshot, raster, upload and GPU command
completion callbacks. The observer is internal and inactive in ordinary app use.
It records no terminal contents. Run it with an unlocked desktop and retain
keyboard focus in the probe window; losing focus fails the measurement.

Four scenes cover single-pane typing, typing alongside three ASCII streams,
typing alongside three Unicode streams, and scrolling with three Unicode streams.
Each producer writes one numbered line every 8 ms with backpressure. Synthetic
Enter events have matching key releases. Three warmups precede the measured
samples, with a fixed sequence of 83/97/113/91/109/101 ms input intervals to avoid
locking to one display phase. Process CPU covers the probe's user/system CPU,
including its PTY workers, but excludes producer children and WindowServer.

The latency metric ends at the GPU completion callback for a revision containing
the input marker or the requested viewport change. It does not measure physical
key-to-photon latency. Drawable presentation timestamps are counted separately.
Initial trials returned zero; all six formal runs returned positive timestamps,
but the probe retains only availability counts, not input-correlated presentation
times. These data therefore cannot supply event-to-presentation latency.
Raw phase samples, raster counts and uploaded bytes help distinguish where the
work is spent. GPU completion and drawable presentation are never conflated.

The candidates are coalescing visible unfocused panes at 30 Hz while retaining
focused and local-interaction responsiveness, and reducing unnecessary texture
uploads if measured damage supports it. Hidden panes retain their 4 Hz policy.
Any cadence change must preserve the final update, events, focus transitions and
shutdown. Texture history is deferred when full uploads correspond to genuinely
changed bitmap rows. VT/grapheme optimization and a new glyph renderer remain
separate work; this pass changes neither the Rust engine nor the browser artifact.

### Native refresh implementation

`FrameRefresh` retains one automatic refresh deadline and re-evaluates the current
interval when it fires. Earlier deadlines replace later ones; generations reject
stale cancelled callbacks. A visible unfocused pane uses 1/30 second, a hidden
pane 1/4 second, and focused or recently interacted-with panes bypass pacing.
Local input and grid resizing keep the bypass for 100 ms. Explicit polls for
scrolling, selection and visibility continue immediately. Shutdown invalidates
pending work before closing the session; the one-second safety timer is unchanged.

Deterministic clock/scheduler regressions cover burst coalescing, the final update
without another wake, focus gain, visibility restoration, hiding before a deadline,
stale callbacks and shutdown. A headless native-view integration regression also
checks that a burst's final text/title/bell arrive and late work does not poll a
closed session. Existing image animation, focus, input and raster tests remain
part of the full gate.

The initial 60-sample native preflight met the CPU-improvement criterion in all
three multi-pane scenes. Texture history was deferred: the Unicode scroll path
repaints the full bitmap, so those uploads are real damage, not only stale texture
copies. This pass reduces unnecessary refresh work and leaves pixel rendering,
protocol handling and frame damage semantics unchanged. Committed-candidate
measurements below determine the accepted scope of the improvement.

### Native committed-candidate remeasurement

Product baseline: `a0babc4f82907c82175bc375504c5b810d06743f` (1.3.28).
The unchanged scheduling baseline includes instrumentation at
`e0f1835ed44ab9bbf7425e3f43d50cead488bdde`; the implementation is
`e47b0c8ad0f1422dde2fb7157e70d821e53f73d1`. The baseline probe was frozen before
implementation; the candidate was built after committing it. The measurement
source tree stayed clean at the candidate commit throughout the formal runs.
Both probes use identical harness, renderer instrumentation and Rust source.

Six runs execute before/after/after/before/before/after on Apple M3 Max,
macOS 27.2.1, Rust 1.99.1, Swift 6.4.2 and Node 26.13.1. Each scene has three
warmups and 60 measured inputs per run: 180 latency samples per version/scene.
CPU is the median of three process user-plus-system percentages, where one fully
used core is 100%. Latency quantiles pool the 180 samples using nearest rank.
These are short repeated measurements on one host, without confidence intervals.

| Scene | CPU before | CPU after | CPU reduction | GPU completion p95 before | After |
| --- | ---: | ---: | ---: | ---: | ---: |
| Single-pane typing | 15.14% | 14.27% | 5.7% | 14.77 ms | 14.36 ms |
| Typing with three ASCII streams | 56.63% | 35.48% | 37.3% | 12.85 ms | 11.72 ms |
| Typing with three Unicode streams | 64.10% | 44.83% | 30.1% | 14.60 ms | 11.13 ms |
| Scrolling with three Unicode streams | 64.35% | 46.71% | 27.4% | 14.92 ms | 11.77 ms |

The three multi-pane scenes exceed the planned 15-20% CPU-improvement gate.
Their foreground GPU completion p50 rises from 7.00 to 7.78 ms, 6.21 to 7.03 ms,
and 7.21 to 8.12 ms respectively, while p95 and p99 fall. This is a measured
tradeoff, not a claim that every input becomes faster. The single-pane control
shows a much smaller difference; it does not establish a general single-pane gain.

| Scene | Background raster builds before | After | Total upload GiB before | After |
| --- | ---: | ---: | ---: | ---: |
| Single-pane typing | 0 | 0 | 1.09 | 1.09 |
| Typing with three ASCII streams | 1824 | 510 | 8.05 | 2.44 |
| Typing with three Unicode streams | 1796 | 510 | 8.45 | 2.59 |
| Scrolling with three Unicode streams | 1807 | 510 | 8.52 | 2.60 |

Counts and bytes are median totals over each approximately 5.84-second measured
window; upload totals include the foreground pane. Background rasters fall about
72%, consistent with retaining only the latest output at the lower cadence.
Unfocused visible panes now update at about 30 Hz, which is an intentional
smoothness tradeoff. Focus, local input and explicit scroll/selection polls retain
immediate refreshes. This change improves the native host's work under concurrent
output; it does not change the Unicode/grapheme engine gap, browser performance,
or establish full-app parity with Ghostty.

[The machine-readable record](../benchmarks/results/native-refresh-2026-11-14.json)
retains all 1,440 critical latency samples, raw CPU windows, per-pane counts,
phase quantiles, geometry, source/binary fingerprints and original raw-file
hashes. Full phase arrays and build logs remain local benchmark artifacts.
Reproduce a single run with `scripts/benchmark-native.sh OUTPUT.json 60` from
each pinned tree, preserving focus and the same display geometry; alternate the
versions as above. `AKITTY_NATIVE_PROBE_SAVE_APP` can retain an immutable probe
app to repeat runs without rebuilding; its Sparkle dependency must stay unchanged.

The full local `scripts/verify.sh` gate passed, including 389 Swift tests with
three opt-in skips and no failures. Chromium and WebKit passed; the existing
Firefox startup error (`Could not find profile folder`) triggered its configured
local skip, so fresh CI Firefox qualification remains outstanding. Debug and
clean committed release app builds, three-second startup smokes and ad-hoc
signature checks passed. WASM provenance was verified and its artifact is
unchanged. No notarization or release publication was performed.
