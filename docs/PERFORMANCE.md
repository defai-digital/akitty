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
4. Split the PTY worker into a reader and a parser over a fixed ring of four
   64 KiB slots. Gather every immediately available read into one slot and publish it
   when it is full, otherwise on would-block, EOF, a read error or a stop, so a tail
   is never held back and bytes read before a failure are still applied. The reader
   owns every `read(2)` and never takes the model lock; the worker applies one ring's
   worth per pass with each model lock covering at most 8 KiB, so the 256 KiB pass
   budget still yields to input and resize. Wake the host once per applied batch.
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
and PTY throughput. Separate I/O/parser threads remain a candidate for a later
hot-path pass; the GPU glyph atlas landed in the rendering follow-up at the end
of this file.

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
alternate screens, queries, bells and synchronized output. PTY pipeline tests
cover ring backpressure and slot ownership, a tail reaching the parser on
would-block/EOF/error, split Unicode and query sequences across slots, reply
ordering, one bounded model lock per parse batch, one host wake per applied batch,
post-exit reply delivery and bounded shutdown.

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
history and compact cells remain separate follow-up work; the GPU glyph atlas is
described at the end of this file.

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
| ASCII | 219.5 | 319.9 | 1.46x | 130.2 | 183.0 |
| ansi | 123.7 | 218.5 | 1.77x | 92.2 | 149.9 |
| Unicode | 31.7 | 31.7 | 1.00x | 24.6 | 25.1 |
| long-lines | 226.5 | 230.5 | 1.02x | 139.9 | 144.4 |
| alternate-screen | 62.2 | 67.7 | 1.09x | 44.0 | 44.7 |
| Synchronized screen | 93.4 | 91.6 | 0.98x | 76.7 | 76.3 |

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
| ASCII | 96.74 | 111.36 | 1.15x |
| ansi | 63.32 | 84.80 | 1.34x |
| Unicode | 58.55 | 61.27 | 1.05x |

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
| ASCII | 5.60x | 3.66x | 1.19x | 1.11x |
| ansi | 2.57x | 1.44x | 1.57x | 1.04x |
| Unicode | 5.97x | 5.98x | 4.97x | 4.91x |

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

## Native scroll qualification plan

The next bounded pass starts from `263d509` (1.3.29), including the accepted
unfocused refresh policy. It first attributes native work before changing the
renderer. The candidates are Unicode full-scroll repaint and unchanged foreground
polling; elapsed phase times and callback counts alone do not establish CPU share.
Reference review remains ideas-only. No VT, WASM, cell-storage or ABI rewrite is
part of this pass.

The native probe now correlates GPU completion and drawable presentation
independently. Each input records a base revision, a matching snapshot target,
and the first qualifying callback timestamp at or after that target. Reordered
delivery is reconciled by timestamp, and GPU completion cannot consume a pending
presentation. Superseding revisions remain recorded, so a later frame is not
mislabelled as the exact target frame. This is synthetic input-submission latency,
not physical key-to-photon latency. Echo is disabled and the foreground helper
emits complete lines only, so typing markers cannot appear before Enter submits
the line. Missing presentation callbacks remain null with their denominator;
invalid times and callback-buffer overflow are reported, not treated as fast.

Two additional scenes emit eight lines every 8 ms with backpressure, alongside
the existing one-line scenes. `AKITTY_NATIVE_PROBE_SCENES` selects a comma-separated
subset. `AKITTY_NATIVE_PROBE_PROFILE` sets an output prefix for four-second macOS
`sample` captures during each scene's measured window. Profiled runs are labelled
and excluded from performance comparisons; original stack files remain local.
Deterministic correlation checks run through `scripts/test-native-trace.sh` in
the canonical gate. The same instrumented harness must be used for both versions.

Only a confirmed material hotspot proceeds to a small prototype. Unicode bitmap
scroll reuse must match full repaint bytes across fonts, scales, CJK, emoji,
decorations, cursor and selection, preserving fallbacks for unsafe geometry or
glyph placement. CPU bitmap scrolling changes all destination texture rows and
does not by itself reduce the required GPU upload region. Adoption requires at
least 15% representative process CPU reduction or a material reproducible
presentation-p95 improvement, without visual or foreground p50/p95 regression.
An unsuccessful candidate is discarded rather than expanding into a renderer
rewrite. After correctness gates and an implementation commit, alternating
committed-baseline/candidate runs determine the accepted result.

### Rejected Unicode scroll experiment

Fresh four-second sample captures on the instrumented baseline found raster
self-weight estimates of 28.4% (Unicode scroll) and 32.1% (Unicode burst) among
non-wait stacks, versus 5.1% for ASCII typing. Snapshot estimates were 4.0-7.6%,
including changed and unchanged calls. Scheduler/unattributed leaves remain in
the denominator; these are approximate stack shares, not measured thread CPU
fractions. Profiled runs are excluded from performance comparisons.

The first placement-phase-only prototype failed 14 pixel comparisons for Menlo
17.25 pt at 3x. Rejecting scaled glyph reuse fixed those mismatches but made the
mixed-emoji row path entirely conservative. The revised, subsequently rejected prototype moved
retained bitmap rows and redraws unsafe glyphs inside their existing cell clips,
provided those clip edges are whole device pixels. It reuses an unscaled cached
line only when source/destination placement has identical scale/x and an exact
integer y translation with matching `CGFloat` and `Float` pixel phases. Cache
misses and scaled lines redraw. Decorations still redraw their whole row;
fractional cell boundaries, images, composition, cropped and changed layouts
retain conservative fallbacks. Rendering and glyph-fitting rules are unchanged.

Repair spans use the same merged-cluster box as the ordinary per-glyph clip;
backgrounds and intersecting glyphs repaint within the union of those spans and
full dirty rows. Old/new cursor rows remain full repairs. Every actual bitmap
scroll still reports the entire grid as GPU damage, including all repaired spans.
This prototype targets CPU painting work, not the upload region required by a
scroll. A passing pixel matrix establishes correctness for its covered cases;
committed-candidate remeasurement must still satisfy the performance gate above.
For this evaluation, CPU acceptance requires at least 15% median reduction in a
target Unicode scene with improvement in all three before/after pairs. The
presentation alternative requires at least 10% and 2 ms pooled p95 improvement,
with improvement in every pair beyond concurrent single/ASCII control movement.
Neither route permits a visual mismatch or a foreground/control latency
regression outside the observed run variation. An inconclusive result rejects
the product candidate; no second optimization line follows in this pass.

The extended matrix compares 270 coalesced Unicode frames against stateless full
painting across Menlo/Courier, 13/13.5/17.25 pt and 1x/2x/3x, including selected
text, cursor visibility, fitted emoji, combining marks, box drawing and decorated
rows. Separate fractional-scale, cropped and IME cases check fallback equality.
Existing randomized raster, glyph batching, layered rendering and font tests
also remain required. `NativeInputTrace` rejects a new submission until the last
GPU completion identifies its target, while earlier presentations can remain
pending; overlapping submission rejection and stale-history eviction have
explicit regressions. External CLI advice is independently checked against the
unchanged full-grid damage and per-glyph clipping paths.

### Committed-candidate evaluation and rejection

The instrumented baseline is `a29537a`; the experimental implementation is
`7a89fe893d85897b2011e426550aa401fecb864f`. Six alternating runs used frozen
release probes, the same Rust sources, harness, geometry and dependencies, with
three runs per version, six scenes and 60 inputs per scene/run. All 2,160 inputs
had valid GPU and presentation samples. CPU values are medians of three process
user/system CPU percentages; presentation quantiles pool 180 samples per
scene/version. No sampler, build or test ran during timed comparisons.

| Scene | CPU baseline | Candidate | CPU change | Presentation p95 baseline | Candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Single typing | 15.37% | 14.73% | -4.2% | 38.05 ms | 37.84 ms |
| ASCII streams + typing | 39.81% | 39.35% | -1.2% | 32.29 ms | 31.71 ms |
| Unicode streams + typing | 47.22% | 49.74% | +5.3% | 31.01 ms | 31.58 ms |
| Unicode streams + scroll | 48.06% | 49.08% | +2.1% | 31.58 ms | 33.76 ms |
| ASCII burst + typing | 49.17% | 48.68% | -1.0% | 31.54 ms | 32.65 ms |
| Unicode burst + typing | 46.05% | 53.25% | +15.6% | 30.97 ms | 32.80 ms |

The candidate failed both declared acceptance routes. No target scene reached a
15% CPU reduction; presentation p95 did not improve. Unicode scroll/burst tails
also regressed. Single/ASCII control movement is not evidence of a Unicode win.
The one-batch preflight's apparent 0-9% CPU reductions and shorter burst tail did
not hold in the committed-candidate comparison. The results do not identify a
single causal mechanism for the extra cost; eligibility scans, merged-cell
work and complex clip regions add work that component raster counts alone do
not capture. These remain hypotheses, not a second optimization plan.

The renderer experiment was reverted. The native refresh policy and renderer
therefore retain their baseline behavior. The benchmark-only independent
GPU/presentation correlation, burst scenes, overlap/overflow regressions and
expanded Unicode pixel-equivalence tests remain. The latter intentionally do
not require the rejected Unicode reuse branch: they protect the conservative
fallback and can reject future unsafe changes. No additional GPU, cell-layout,
VT or polling optimization follows in this pass.

[The evaluation record](../benchmarks/results/native-scroll-rejected-2026-11-14.json)
retains all critical latency samples, per-run CPU windows, phase quantiles,
geometry, source/binary fingerprints, approximate profile summaries and hashes
of full local raw files. Presentation is a drawable timestamp for a target or
later revision, not physical key-to-photon time. Process CPU excludes producer
children and WindowServer; no energy or full-app Ghostty parity claim is made.

Both the experimental and restored trees passed the full local canonical gate:
391 Swift tests, three opt-in skips and no failures, plus the standalone trace
regressions and Rust/ABI/WASM/TypeScript/release-tooling checks. Chromium and
WebKit passed. The existing Firefox profile-folder startup failure caused its
configured local skip; fresh CI Firefox qualification remains outstanding.
Experimental debug and clean committed release app builds, startup and signature
checks passed, as did the real four-PTY/two-tab `TerminalWindow` smoke. Final app
build/startup qualification follows the restoration commit. No release or
notarization was performed. Grok, agy, Muse and Kimi supplied substantive scoped
close-out reviews supporting rejection; their advice is not test evidence.

## GPU glyph atlas

`MetalText.swift` adds a second Metal path for ordinary terminal text. It exists to stop re-rasterising and
re-uploading a whole window bitmap when only a few rows of ASCII change; the software rasterizer stays the
reference and the fallback.

- A glyph is shaped and rasterised by CoreText once, at the exact device-pixel position the rasterizer would use,
  and stored in one 2048x2048 R8 coverage texture (about 4 MiB). Masks are keyed by style, text and foreground
  colour, because macOS font smoothing is colour-dependent: a colour-independent mask differed from the
  reference by up to ~50/255, while a mask rasterised in the text colour stays within 2/255.
- Shelf packing bounds the atlas in entry count as well as size. When it fills it is recreated and every row is
  re-encoded, so eviction costs work but never correctness. Rebuilds are rationed per font/scale/grid/theme epoch:
  a storm that would refill the atlas on every frame stands the path down to the software rasterizer instead of
  rasterising the whole window through CoreText each frame, and a frame that needs more distinct masks than the
  entry cap is refused outright rather than drawn with missing glyphs. Both cases redraw correctly through the
  renderer at its ordinary incremental cost.
- Instance rows live at a fixed per-row stride. While no frame is in flight, an update writes only the rows the
  core damaged and zeroes the unused tail of each row, so a row that shrank needs no second draw call. While a
  frame may still be reading the buffer, the upload instead publishes a complete replacement built from a
  one-buffer CPU mirror, and the retired buffer returns to a pool of at most two once the frame that owned it
  completes; no upload ever edits bytes the GPU may still read. The mirror, the draw buffer and that pool are the
  hard bound (about four buffers of `rows x (2 x cols + 4)` instances at most). Unused slots are zeroed degenerate
  quads. A row that would exceed the stride is an error that hands the frame to the rasterizer, never a truncation.
- New masks are appended at atlas coordinates that were never written before, so an atlas upload cannot disturb a
  texture a frame in flight is sampling; only a recreate allocates a new texture. The texture's lifetime matches the
  mask cache: a frame drawn by another path (IME, CJK, an image) drops the instance buffers but keeps the atlas, so
  returning to the atlas reuses every cached mask. Both are released together when the pane leaves its window.
- Glyph quads are clipped to their cell box, matching the rasterizer's per-cell clip, and solid quads (cell fills,
  selection and find highlights, cursor bands) are converted from `CGColor` through the same one-pixel device-RGB
  bitmap the CPU bitmaps and the Metal clear colour use.
- Frames with Kitty images keep the existing layered path, so image compositing is unchanged. IME composition,
  non-ASCII text, wide cells, box drawing, underlined or struck-through cells and backing scales outside 1x-3x
  keep the software rasterizer.

`MetalTextRenderingTests` compares offscreen GPU frames against `GridRasterizer` output for ASCII at 1x, 2x and
3x, ANSI colours and highlights, all four cursor styles and a non-default theme. The worst channel difference is
2/255 with more than 95% of pixels byte-identical at every tested scale; the residual is blending rounding on
antialiased edges. The same suite covers atlas reuse, the entry cap and eviction path, dirty-row-only uploads,
layout invalidation and resource release. Component timings (raster versus atlas upload) are not yet measured,
so this is an equivalence and correctness result, not a speed claim.

## Native snapshot row certificate

A partial snapshot has always rehashed every visible cell to decide which rows changed, so even a quiet
poll paid for the whole grid. The certificate stage replaces that scan with a validity check: a row whose
cells cannot have changed keeps its previous hash and is never read.

- Each viewport position stores the row it held when its hash was sent, as `(row.id, row.generation)`
  (`RowStamp`). Row identity alone is not enough, because a recycled or reflowed row can keep an id;
  generation alone is not enough, because rows move between positions when the screen scrolls.
- Content identity is not the whole picture. A palette change (OSC 4, 10, 11, 12, 104, 110-112 or a host
  theme), DECSCNM reverse video, a selection drag and a search mark all repaint a row without moving any
  cell generation. Those fold into one appearance stamp per snapshot, built from the resolved palette
  (259 slots through `Palette::resolve`, plus `base_background` and `cursor`), the terminal geometry,
  `reverse_video`, the resolved selection range, the search ranges and the active mark, and the cell pixel
  size used to decode placeholder fragments. A row is reused only while that stamp is unchanged, and any
  uncertain change costs a rescan rather than a stale frame.
- Rows carrying placeholder cells are always rescanned. Decoding their image fragments reads the graphics
  state. A cell generation does not cover an image retransmit or a moved placement, so certifying those
  rows clean would silently drop visible image fragments.
- The dirty flag, scroll-shift detection, the partial/full decision, the bounded link table, the crowded
  table fallback, placeholder failure restoration and the one-shot event accounting are unchanged; the
  certificate only decides whether a row's hash has to be recomputed. A crowded table or an oversized
  build still drops the baseline, so the next poll is a full snapshot.
- Both passes now walk rows instead of cells: the hash pass visits only rows without a certificate, and the
  cell emitter visits only rows the comparison marked dirty. A partial that changes one row reads one row.

`Model::scanned_cells`, present in test builds, records how many visible cells a snapshot's hash pass read,
which is what makes the reuse observable instead of assumed. The tests assert that an unchanged screen reads
zero cells, that a single recoloured or retyped row reads one row, and that palette, DECSCNM, selection,
search, ED2, ED3 and RIS changes rescans rather than reusing a hash that would paint the old frame. Every
case also merges the partial into a client copy and compares it with a second model that saw the same bytes
and answers with a full snapshot, so the wire contract is checked alongside the fast path.

This stage is an algorithmic change with correctness coverage only. No timing or profile measurement of the
snapshot path was taken for it, so it carries no speedup figure and should not be read as one.


## Integrated I/O, VT, snapshot and renderer pass

Baseline for all controlled comparisons below is `dab8d910318034559b96b1525b4fca67ced3e51b`
in an immutable worktree; the candidate is the integrated uncommitted performance change. The
canonical `scripts/verify.sh` gate passed, including Rust, WebAssembly, TypeScript, ABI, release
 tooling, installer, public-file and 411 Swift tests. The debug app bundle passed ad-hoc signature
verification and a three-second startup smoke. The release bundle script itself requires a clean
commit and was not run; no commit or publication was made.

### Engine and real PTY throughput

The canonical native/WASM benchmark used 120x40, 1,000 history rows, 32 rounds and 15 samples,
with two baseline/candidate pairs. Rates are median MiB/s and final state agreement passed in every
run. ANSI is near baseline rather than a regression; synchronized-screen is also close to baseline.

| Workload | Native baseline | Native candidate | Change | WASM baseline | WASM candidate | Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ASCII | 296.26 | 368.17 | +24.3% | 175.55 | 195.60 | +11.4% |
| ANSI | 195.60 | 190.29 | -2.7% | 144.61 | 149.06 | +3.1% |
| Unicode | 31.67 | 39.19 | +23.7% | 24.74 | 29.76 | +20.3% |
| Long lines | 226.94 | 268.68 | +18.4% | 148.27 | 172.94 | +16.6% |
| Alternate screen | 65.13 | 68.12 | +4.6% | 42.18 | 52.38 | +24.2% |
| Synchronized screen | 90.45 | 88.35 | -2.3% | 74.07 | 78.03 | +5.3% |

The real PTY probe ran twice per version with the same 8 MiB fixtures. Reported values are the
median of the two p50 rates; these are host/model measurements, excluding rendering.

| Workload | Baseline MiB/s | Candidate MiB/s |
| --- | ---: | ---: |
| ASCII | 97.34 | 107.87 |
| ANSI | 58.95 | 105.83 |
| Unicode | 62.40 | 112.52 |

The VT implementation uses a 16-byte common cell, bounded four-slot prepared-style templates,
batched narrow/wide writes, conservative stateful-grapheme fallback, and parser-validated `&str`
runs that avoid a second whole-run UTF-8 validation. History charging remains exact: distinct side
records are counted once per row, with incremental common-path accounting and conservative full
recomputation for complex edits, reflow and more than four records. RGB blanks and combining/link
records cannot bypass the 64 MiB bound.

The PTY host uses a bounded two-stage reader/parser ring with four 64 KiB slots. Gathering fills
available bytes without waiting, publishes on full/would-block/EOF/error/stop, and preserves
backpressure, reply order, final drains and bounded shutdown. Host notification is once per applied
batch. Ordinary filter and parser event allocations are reused.

### Snapshot and native pipeline

Snapshot row certificates reuse a previous hash only while row identity, generation and appearance
are unchanged. Appearance covers palette resolution, reverse video, selection, search and cell pixel
state. Placeholder rows always rescan; dirty rows alone are emitted. Full-vs-partial reconstruction
covers palette changes, selection/search, scrolling, resize/reflow and failure recovery.

The native probe used 60 inputs per scene, with GPU completion and drawable presentation sampled
independently. It is synthetic input-submission latency, not physical key-to-photon time. CPU is
process user-plus-system time, excluding producer children and WindowServer.

| Scene | CPU baseline | CPU candidate | Upload baseline MiB | Upload candidate MiB |
| --- | ---: | ---: | ---: | ---: |
| Single typing | 13.50% | 11.77% | 1109.8 | 724.7 |
| ASCII streams + typing | 37.92% | 29.02% | 268.8 | 72.5 |
| Unicode streams + typing | 51.82% | 53.28% | 267.8 | 72.1 |
| Unicode streams + scroll | 54.01% | 53.83% | 280.2 | 280.2 |
| ASCII burst + typing | 52.56% | 30.89% | 269.3 | 73.2 |
| Unicode burst + typing | 51.80% | 52.68% | 267.0 | 71.8 |

ASCII multi-pane CPU falls 23-41% and upload volume about 73%. Single-pane CPU falls 13% and upload
volume 35%. Unicode raster work remains on the conservative CPU fallback and is not a CPU or latency
victory; upload savings there come from scheduling and upload behavior rather than a Unicode glyph
atlas. Presentation p95 is similar to baseline, with run-to-run variation, so this pass does not claim
a presentation-latency improvement.

The Metal text path rasterizes ASCII masks once into a bounded atlas and keeps per-row instance
buffers. Idle GPUs accept partial row updates; busy GPUs receive a complete replacement buffer from
a bounded pool, never an in-flight rewrite. Non-ASCII, wide, decorated, image, IME and unsupported
geometry cases retain the CPU rasterizer. CPU fall-through after an atlas frame repaints fully rather
than using a stale bitmap. Solid fills are byte-identical; antialiased glyph comparisons stay within
2/255 in the tested 1x/2x/3x matrix.

These results close the targeted ASCII/Unicode engine and PTY bottlenecks without claiming full-app
Ghostty parity, physical input latency parity, or identical performance for every terminal workload.

## Unicode grapheme hot path

A fresh matched-engine probe on Apple M3 Max measured the integrated candidate above at 41.21 MiB/s
against 190.37 MiB/s for `libghostty-vt 1.0.1` (4.62x). CPU samples identified repeated grapheme
classification, an unnecessary scalar fallback for every pictograph, repeated exact segmentation and
width measurement of the same clusters, and avoidable combining/spacer allocations. Reference review
informed the property-reuse and batching concepts; the implementation remains independently authored.

The print path now carries one classification into the next pair decision, batches standalone narrow
and wide codepoints, checks ordinary-script ranges before the mark table, prepares one style template
per printable run, and removes a temporary regional-indicator allocation. Grapheme joins take the cell
out of the grid rather than cloning its side record. Default-style wide spacers no longer allocate an
empty record, and a cell's first combining allocation reserves eight marks while retaining the 16-mark
limit and exact capacity-based history accounting.

A bounded 16-slot cache remembers exact break and unclamped width results for repeated candidate
clusters. Keys are complete UTF-8 strings in fixed 72-byte arrays (not hashes), so collisions cannot
change behavior. An eight-slot version thrashed on an 11-cluster emoji workload; 16 slots removed that
working-set eviction. Oversized keys are not retained. All column clamps, wrapping, row generations,
history accounting and event behavior still run through the original mutation path.

The direct comparison uses 120x40, no history, grapheme support enabled, 256 rounds, three warmups and
30 samples with randomized per-sample engine order. Every sample compares text, widths, styles,
wrapping and cursor metadata after feeding and both resize steps; all comparisons match. Rates are p50
MiB/s. Before/after drivers ran sequentially with ordinary desktop activity present.

| Unicode workload | Akitty before | Akitty after | Change | Ghostty after | Ghostty / Akitty after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixed | 41.30 | 69.74 | +68.9% | 194.71 | 2.79x |
| CJK | 79.64 | 154.42 | +93.9% | 398.14 | 2.58x |
| Standalone emoji | 56.25 | 173.43 | +208.4% | 479.80 | 2.77x |
| Complex emoji | 21.96 | 42.52 | +93.6% | 129.49 | 3.05x |
| Combining text | 28.86 | 37.73 | +30.7% | 83.53 | 2.21x |

The canonical 15-sample/32-round engine benchmark retains native/WASM state agreement in all six
workloads. Its Unicode rates improve from 39.19 to 65.53 MiB/s native and 29.76 to 43.96 MiB/s WASM.
The real native PTY probe reports 111.90 MiB/s Unicode (112.52 before this pass), 106.20 ASCII and
107.27 ANSI; this is a different grapheme-default worker/model measurement, not a matched Ghostty
comparison. No rendering or physical input latency improvement is claimed, and Ghostty remains faster
in these engine probes. The [raw record](../benchmarks/results/unicode-hotpath-2026-11-17.json) retains
source/artifact hashes, configuration, direct-comparison samples and the canonical engine result.

### Unicode follow-up: boundary reuse, UTF-8 and symbols

A second profile found three decisions for one joining pair: the ASCII-run probe, the cell run and
the scalar grapheme fallback each classified both sides. The run now returns its first unconsumed
join verdict, and a non-ASCII first character skips the ASCII probe entirely. Complete-feed tests
count classifications through joins and split UTF-8 chunks. CR×LF also reaches its GB3 exception
before the general control-break rules; every scalar is checked as a tail against exact segmentation.

The parser validates a complete multibyte scalar with inline lead/continuation and overlong/surrogate
checks instead of calling the general UTF-8 decoder for every scalar. Tests compare this check with
the standard decoder over every three-byte input, a four-byte boundary matrix and every Unicode
scalar. Common punctuation and symbol blocks no longer fall through the full combining-range chain.
U+2100–2BFF is conservatively treated as possible pictographs: ordinary neighbours break directly,
while anything after ZWJ still requires exact segmentation. CJK, Hangul, regional indicators and
emoji answer before the broad range tables.

Stationary same-width joins append in place, retain the existing trailing cell and record the actual
modified prefix. Width changes and wrapping retain the complete wide-cell repair. Exact-analysis
break entries no longer measure an unused cluster width. A 64-slot direct-mapped hash cache was
measured and rejected because it regressed common complex-emoji and combining workloads; the bounded
16-slot exact-key cache remains.

Repeating the matched comparison above against the `8ac2953` candidate gives the following p50 rates.
All cell and resize comparisons match.

| Unicode workload | Akitty before | Akitty after | Change | Ghostty after | Ghostty / Akitty after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixed | 69.74 | 102.53 | +47.0% | 193.91 | 1.89x |
| CJK | 154.42 | 172.23 | +11.5% | 387.06 | 2.25x |
| Standalone emoji | 173.43 | 188.73 | +8.8% | 479.78 | 2.54x |
| Complex emoji | 42.52 | 71.44 | +68.0% | 128.40 | 1.80x |
| Combining text | 37.73 | 51.70 | +37.0% | 82.87 | 1.60x |

A separate mixed punctuation, arrows, box drawing and symbol workload improves from 22.84 to 149.66
MiB/s (6.55x) after the classification expansion. Its baseline is the verdict-reuse candidate
immediately before that expansion, not `8ac2953`. The canonical 30-sample/128-round Unicode rate is
90.98 MiB/s native and 64.90 MiB/s WASM. The preceding section's 65.53/43.96 rates used 15 samples
and 32 rounds, so they are not a same-configuration baseline for these figures. The actual PTY worker
reports 107.97 MiB/s ASCII, 106.70 ANSI and 113.77 Unicode. These are engine and worker/model measurements,
not full-application or physical-input parity claims. The [follow-up raw record](../benchmarks/results/unicode-followup-2026-11-18.json)
contains source/artifact hashes, all direct samples, symbol samples, canonical results and PTY samples.

### Unicode follow-up: cached scalar properties and bounded wide repairs

A fresh profile and two independent source reviews found that each non-ASCII scalar paid for a
boundary classification and a separate width lookup. The run now reads both properties from one
byte. A bounded array of lazy 256-scalar pages supplies those bytes; each page is initialized from
AkiTTY's existing classifier and `UnicodeWidthChar`, rather than from a second hand-maintained
Unicode table. The payload is bounded at 1,114,112 bytes if every page is used, while ordinary text
touches only a few pages. `OnceLock` makes concurrent initialization safe. All scalar properties
match the original functions, including concurrent first use, and unknown widths retain the
original lookup. Full-cluster segmentation and width measurement are unchanged.

Width-changing grapheme repairs also invalidated the whole row's modified prefix even though their
writes cover at most the glyph and its neighbour. Those repairs now record their actual end column,
as same-width joins already did. Generation advances, wide-neighbour cleanup, wrapping and history
accounting are unchanged. A regression checks the bounded prefix, and the existing differential
prefix-reset, scalar/run, cell and resize comparisons pass. Two smaller experiments—carrying a few
hand-classified widths without page caching, and filtering the exact cluster cache by a tail
fingerprint—were rejected because they reduced throughput.

Repeating the matched comparison against `1c9cfac` gives these p50 rates. The candidate runs use
120x40, no history, grapheme support enabled, 256 rounds, three warmups and 30 randomized paired
samples; every cell and resize comparison matches.

| Unicode workload | Akitty before | Akitty after | Change | Ghostty after | Ghostty / Akitty after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixed | 102.53 | 123.66 | +20.6% | 191.12 | 1.55x |
| CJK | 172.23 | 193.23 | +12.2% | 393.72 | 2.04x |
| Standalone emoji | 188.73 | 214.86 | +13.8% | 484.46 | 2.25x |
| Complex emoji | 71.44 | 84.81 | +18.7% | 128.00 | 1.51x |
| Combining text | 51.70 | 58.73 | +13.6% | 80.84 | 1.38x |

The canonical 30-sample/128-round Unicode rate is 104.00 MiB/s native and 74.43 MiB/s WASM,
compared with 90.98/64.90 under the same configuration before this pass. The final actual-PTY run
reports 102.45 MiB/s ASCII, 102.06 ANSI and 103.02 Unicode. That worker uses different grapheme
defaults and is not a matched Ghostty comparison; a prior run with severe scheduling outliers was
not used for the reported rates.

Ghostty remains faster in these engine probes. The results do not establish full-application,
rendering or physical-input parity. The [property-page raw record](../benchmarks/results/unicode-property-pages-2026-11-18.json)
contains the direct samples, source/artifact hashes and final canonical and PTY measurements.

### Unicode follow-up: inline combining storage

Profiling after the property-page pass still showed two allocations on a cell's first combining
mark: one for the shared side record and another for its vector buffer. Combining storage now holds
up to eight marks inside that record. The ninth mark moves the ordered sequence into a fixed
16-slot boxed array; the sixteenth is accepted and the seventeenth is rejected before mutation.
A fixed spill makes history charging deterministic even after copy-on-write. Debug output and
equality inspect only the visible mark slice. New records receive their first mark directly, while
existing shared style/link records still detach through `Arc::make_mut`. Spacers never inherit
marks, and the row charge includes the record and any spill exactly once.

The tradeoff is a larger side record, including style-only records, offset by eliminating the
separate allocation for the common one-to-eight-mark case. Tests cover ordered marks at 8/9/16,
the rejected seventeenth, inline and spilled clones, shared templates, links, spacers, exact history
charges and scalar/run agreement. A `strong_count` shortcut and a 64-slot identity scratch for
history recounts were both measured and rejected: neither improved the paired history-enabled runs.
Those history runs are Akitty-only because Ghostty's history row semantics differ, so they are not
reported as a cross-engine comparison.

Repeating the matched history-zero comparison against the property-page candidate gives the
following p50 rates, with every cell and resize comparison matching:

| Unicode workload | Akitty before | Akitty after | Change | Ghostty after | Ghostty / Akitty after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixed | 123.66 | 126.82 | +2.6% | 193.02 | 1.52x |
| CJK | 193.23 | 191.81 | -0.7% | 382.68 | 2.00x |
| Standalone emoji | 214.86 | 216.20 | +0.6% | 472.56 | 2.19x |
| Complex emoji | 84.81 | 84.95 | +0.2% | 127.69 | 1.50x |
| Combining text | 58.73 | 65.35 | +11.3% | 82.80 | 1.27x |

Small non-combining differences are run-to-run variation, not claimed regressions or improvements.
The canonical Unicode rate is 110.19 MiB/s native and 76.27 MiB/s WASM, compared with 104.00/74.43
before inline storage. The [inline-combining raw record](../benchmarks/results/unicode-inline-combining-2026-11-18.json)
contains direct samples, paired history measurements, rejected-experiment results, source hashes
and the canonical result. Ghostty remains faster, and no full-application or physical-input parity
is claimed.

## PTY refill bridging and filter pass-through

Attribution came before any change. On Apple M3 Max, a single-thread C reader with
no processing drains `cat` through a raw macOS PTY at about 141 MiB/s, because the
kernel hands the master at most 1 KiB per read. The release model alone applied
the PTY benchmark's payloads at 372 (ASCII), 147 (ANSI) and 179 (Unicode) MiB/s.
The PTY path still delivered only 92–115 MiB/s. Two costs explained the gap:

1. The reader published a 64 KiB slot on every would-block, so each slot carried
   about 1 KiB. Four slots then made a 4 KiB backlog, and the reader, and with it
   the program, stalled behind every parse pass.
2. Any escape byte made the chrome and APC filters copy the whole chunk
   byte-by-byte into owned pass segments. That was 43% overhead over the engine
   for SGR-heavy output, which those filters pass through unchanged.

Changes:

1. Both filters accept a chunk as unchanged pass-through when it ends in ground state
   and every escape is followed, inside the chunk, by a byte that cannot start
   their sequences: OSC and a repeated ESC for chrome; APC, a repeated ESC and a
   whole or truncated `CSI 16 t` for graphics. The vectorized no-escape check
   still runs first. Exhaustive tests over short strings of state-driving bytes
   check that every accepted input comes back from `feed` unchanged, as one
   segment, in ground state, and mutation checks confirm that both tests catch a
   wrong condition.
2. A slot with at least 1 KiB that would block is treated as a saturated stream's
   refill gap. The reader re-reads up to 16 times, then polls for 1 ms while the
   parser still has published bytes, within 3 ms per slot. Under the ring lock,
   the parser writes a ring-owned idle pipe when it runs dry during a bridge.
   A short read, an idle parser, a quiet stream, a stop or a hangup publishes at
   once.

The refill-gap bridging approach was learned from reviewing Ghostty's macOS PTY
reader under `.internal/reference`. AkiTTY's implementation, names, structure and
tests are its own; no reference code was copied.

Results on a heavily loaded host (load average 15–25), rotated variant order,
median of all rounds ([raw measurements](../benchmarks/results/pty-bridge-2026-11-18.json)):

| PTY MiB/s | Base | Filters + re-reads | + bridge poll (shipped) |
| --- | ---: | ---: | ---: |
| ASCII | 114.8 | 171.5 / 135.9 | 148.8 / 174.3 |
| ANSI | 91.3 | 115.0 / 101.8 | 126.0 / 149.8 |
| Unicode | 107.6 | 132.3 / 111.8 | 153.6 / 149.6 |

The two figures per cell come from two separate rotated sets. The model probe
moved ANSI from 146.5 to 176.9 MiB/s, with ASCII and Unicode unchanged. User-initiated
QoS on the reader and worker threads showed no measurable gain on this host and
was not adopted; it should be measured again on an idle machine. These rates exclude snapshots and
rendering and make no Ghostty parity claim.

## Synchronized-output text runs

The fresh engine comparison after the PTY bridge showed synchronized-screen as the
largest remaining gap: 85.9 MiB/s against libghostty-vt's 887.8 (10.3x). AkiTTY
holds synchronized output in a bounded queue and replays it when mode 2026 ends,
so snapshots, the Web canvas and query replies never observe a half-drawn frame.
That queue stored one `Print` action per character, and the flush rebuilt ASCII
runs from them while dispatching every other character alone.

Reviewing Ghostty's handling under `.internal/reference` confirmed the cost is in
the queue, not in the mode itself: Ghostty applies synchronized output to the
terminal at once and only holds rendering. AkiTTY keeps its own queue semantics
and changes only how text is held:

1. A printable run that arrives during synchronized output is queued as one text
   entry, merged with a preceding text entry, and replayed through the same row
   writer as unsynchronized text. Non-ASCII text now takes that path too.
2. Each character is still charged the size of the scalar action it replaces, so
   the 2 MiB bound is reached on the same run as before. Where the overflow flush
   falls inside that run is not observable, because its characters print in order
   either way. A test sweeps runs ending just short of, on and past the bound,
   behind other queued actions and in multi-byte text, and mutation checks
   confirm it catches a wrong charge, a lost flush or a lost character.
3. The queue's entry storage is kept between ordinary frames and released after a
   frame larger than 1024 entries.

The text is owned by each entry rather than by a separate buffer on `Terminal`.
Adding one unused `String` field to `Terminal` alone slowed long-lines from 302 to
288 MiB/s with no sample overlap, a layout effect rather than a logic cost, so the
struct keeps its size.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/sync-text-runs-2026-11-18.json)):

| Synchronized screen, engine MiB/s | AkiTTY | libghostty-vt 1.0.1 |
| --- | ---: | ---: |
| Before, rotated against the change (5 passes) | 83.0 | |
| After, same set | 264.2 | |
| After, rotated against libghostty-vt (3 passes) | 268.2 | 897.7 |

The Ghostty / AkiTTY ratio moves from 10.3x to 3.35x.

The other five workloads were unchanged within noise on a host at load average
35–65; their fastest samples matched within 3%. Final viewport, cursor and screen
state agree with libghostty-vt. The remaining synchronized-screen cost is mostly
the parser and row writer that every workload shares, plus about a fifth in
allocation for queued runs and CSI parameters. These rates exclude snapshots and
rendering and make no Ghostty parity claim.

## Heap-free row stores and word-at-a-time ASCII scanning

After the synchronized-output change, plain ASCII remained 3.2x behind libghostty-vt.
A profile of the ASCII workload put about 37% of the time in the row writer, 22% in
the parser's text scan, 12% in blanking recycled rows and 14% in scrolling.

Reviewing Ghostty's batched print path under `.internal/reference` showed two ideas
that fit AkiTTY's own structures: a row known to be blank needs no inspection of its
old cells, and a store of a cell that owns nothing needs no per-cell branch. AkiTTY's
cell is 16 bytes with an optional shared side record, so every assignment ran its
destructor check. The changes are:

1. Each row already certifies, for history accounting, whether any cell may own a
   side record. When it does not, ASCII run writes and recycled-row blanking store
   cells without running a destructor (`Cell::store_heap_free`). This is safe code:
   a wrong certificate would leak a record, never corrupt memory, and debug builds
   assert the precondition on every store.
2. Columns past the row's blank certificate hold single-column blanks, so an ASCII
   run written there skips the old-cell width scan.
3. A scroll whose region ends at the bottom row appends the new blank row instead
   of taking `VecDeque::insert`'s general move path.
4. The parser skips whole eight-byte words of printable ASCII where a text run
   opens and after each multi-byte scalar, with an exact SWAR test. Other bytes
   keep the original one-test-per-byte loop. Testing words at every ASCII byte
   kept costing mixed Unicode text 2–5% even when no word matched, so words are
   only tried at those two points.

Tests check the word test against the byte test for every byte value in every lane
and across lane boundaries, compare runs over link, combining-mark and RGB-blank
rows with the scalar path, write over either half of a wide glyph behind a stale
blank certificate, and move rows for every scroll region against a reference
model. Mutation checks confirm each of those tests catches its targeted defect.

Engine results, rotated order, history 0, 7 passes against the previous commit and
3 against libghostty-vt 1.0.1 ([raw record](../benchmarks/results/ascii-heap-free-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 408.8 | 573.0 | 1.40x | 1298.3 | 3.18x → 2.27x |
| ANSI | 208.0 | 217.6 | 1.05x | 267.0 | 1.30x → 1.25x |
| Unicode | 126.5 | 125.9 | 1.00x | 194.6 | 1.56x |
| Long lines | 308.8 | 345.2 | 1.12x | 485.9 | 1.62x → 1.42x |
| Alternate screen | | 74.1 | | 168.2 | 2.27x |
| Synchronized screen | | 297.5 | | 903.4 | 3.35x → 3.04x |

Final viewport, cursor and screen state agree with libghostty-vt on every workload.
These rates exclude snapshots and rendering and make no Ghostty parity claim.

## Erasing rows that are already blank

The alternate-screen workload enters the alternate screen, erases it with ED 2,
writes two rows and leaves, so nearly every row it erases is already blank. A
profile put most of its time in `Screen::clear`, the per-row `erase` calls and the
cell fills they ran.

Ghostty's `clearRows` under `.internal/reference` resets only a row's metadata when
the row is already blank and keeps its dirty state. AkiTTY's rows carry a blank
certificate (the generation at which they were last fully blanked, and the colour),
so the same idea applies to its own structures:

1. A full-row erase of a row certified blank in the current background, with no
   wrap state, leaves the row untouched, generation included. The host compares
   row identity and generation to decide what a snapshot resends, so such rows are
   no longer resent either.
2. ED erases whole rows in one pass over the screen instead of one call per row.
3. Clearing the alternate screen on entry skips the cell reset for rows that are
   already blank, sets the blank charge once, and rebuilds tab stops only when
   they differ from the defaults.
4. Blank fills on heap-free rows use the destructor-free store from the ASCII path.

Tests check that repeated erases keep the generation of rows they erase whole,
that rows with content or wrap state still change, that a coloured partial erase
is not hidden by a later full erase, and that tab stops changed on the alternate
screen are reset on its next entry. Mutation checks confirm each one is caught.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/blank-erase-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Alternate screen | 73.8 | 131.7 | 1.78x | 169.1 | 2.27x → 1.29x |

The other five workloads were unchanged within noise. Final viewport, cursor and
screen state agree with libghostty-vt. These rates exclude snapshots and rendering
and make no Ghostty parity claim.

## Reused synchronized-queue storage and a CSI body fast path

Synchronized output still spent about a fifth of its time in the allocator: each
queued text run owned a `String`, and each deferred CSI took the parser's parameter
vectors, so the parser had to allocate new ones. CSI-heavy workloads also paid for
the byte state machine on every parameter digit.

1. The synchronized queue is boxed, so `Terminal` does not grow, and holds one
   shared text buffer that queued runs index into. A deferred CSI is copied into a
   recycled record with `clone_from` instead of being taken from the parser, and
   up to 64 records are kept for reuse. Mode 2026 set and reset with a single
   parameter are applied without taking the parser's storage. Every queued item
   is charged exactly as before.
2. When `ESC [` arrives whole in a chunk, the parser collects the CSI body in a
   tight loop: a leading prefix, digits, `;` and the final byte, with the current
   parameter's digits kept in a local. It applies exactly the byte machine's
   transitions for those bytes. Any other byte, the parameter limit or the end of
   the chunk stops it with the parser state the byte machine would have, and the
   byte machine continues from there.

Feeding one byte per call never sees an introducer whole, so it always takes the
byte machine. A differential test feeds 20,000 random CSI-heavy streams whole, one
byte at a time and split at a moving point, and compares actions and live parser
state, including at and past the parameter limit. Mutation checks confirm it
catches wrong digit arithmetic, a lost parameter, a missing parameter on a leading
`;` and an incomplete reset after the final byte.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/csi-fast-path-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ANSI | 217.6 | 286.9 | 1.32x | 271.9 | 1.24x → 0.95x |
| Synchronized screen | 297.4 | 456.3 | 1.53x | 903.5 | 3.01x → 1.93x |
| Alternate screen | 133.2 | 164.0 | 1.23x | 177.5 | 1.29x → 1.07x |

The queue change alone moved synchronized screen from 304 to 374 MiB/s. ASCII,
Unicode and long lines were unchanged. Final viewport, cursor and screen state
agree with libghostty-vt. These rates exclude snapshots and rendering and make no
Ghostty parity claim.

## Fewer passes per written line

Synthetic engine workloads split the remaining ASCII cost: rewriting one row with
carriage returns cost 1.19 ns per byte, and each line feed that scrolls about
17 ns. The row writer passed over each character three times: re-checking that
bytes the parser had already validated were printable, scanning the old cells'
widths with an early exit per cell, then storing.

1. A text run holds printable ASCII and whole multi-byte scalars only, so its ASCII
   prefix is found eight bytes at a time from the high bits.
2. The old-cell width check tests groups of eight cells without a per-cell branch.
3. A scroll of the whole screen that recycles its top row rotates the row deque and
   blanks the row where it lands. The deque is first trimmed to its length, so a
   rotation moves its head instead of copying a row; other scrolls blank the removed
   row in place rather than passing its cells through the spare slot.
4. A C0 control in text, other than the cancels and ESC, is emitted directly by the
   parser and applied directly outside synchronized output.

Rewriting a row now costs 0.81 ns per byte. Tests compare both prefix helpers with
their one-at-a-time forms at every stopping position, every C0 byte through the
fast path with the byte machine after text, a partial UTF-8 lead and inside
sequences, and the existing scroll-region and scalar-path tests cover the row
rotation. Mutation checks confirm each is caught.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/write-passes-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 579.2 | 758.5 | 1.31x | 1273.7 | 2.21x → 1.70x |
| ANSI | 285.1 | 327.6 | 1.15x | 272.5 | 0.95x → 0.82x |
| Unicode | 127.7 | 130.2 | 1.02x | 194.0 | 1.57x → 1.48x |
| Long lines | 343.8 | 377.1 | 1.10x | 494.4 | 1.44x → 1.32x |
| Alternate screen | 166.5 | 166.6 | 1.00x | 174.2 | 1.07x → 1.02x |
| Synchronized screen | 463.5 | 561.7 | 1.21x | 903.3 | 1.93x → 1.57x |

A vectorizable fill of recycled rows through a word image of the blank cell was
also measured. It showed no gain and was not adopted, since it needed `unsafe`.
Final viewport, cursor and screen state agree with libghostty-vt. These rates
exclude snapshots and rendering and make no Ghostty parity claim.

## Runs of characters that never join each other

Only printable ASCII skipped the grapheme pair decision in a text run; CJK, kana,
Hangul syllables and accented Latin each paid a property lookup and a pair decision.
Per-class synthetic lines put the remaining Unicode gap in those ordinary scripts
rather than in emoji sequences: a CJK line cost 190 ns against libghostty-vt's 98,
while a ZWJ sequence line cost 337 ns against 283.

A character is now simple when it is printable ASCII, in U+00A0..U+02FF other than
the two pictographs and the soft hyphen, or in the kana, CJK unified ideograph or
Hangul syllable blocks. Their classes are plain or a Hangul syllable, and no pair of
those classes joins, so a simple character after a simple character needs neither a
lookup nor a decision and takes its width from the range. Any other character, or
a simple character next to one, takes the existing path. A test walks every scalar
value and checks each simple character's width and class against the tables and
every class pair against the pair rules. Mutation checks confirm each range and the
run condition are caught, except edits that the range ordering makes unreachable.

| Synthetic line | Before ns | After ns | libghostty-vt ns |
| --- | ---: | ---: | ---: |
| CJK and ASCII | 189.6 | 150.3 | 98.4 |
| Hangul and ASCII | 173.5 | 137.5 | 87.8 |
| é and ASCII | 148.3 | 102.3 | 50.5 |
| Mixed Unicode workload line | 491.9 | 478.5 | 331.1 |

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/simple-runs-2026-11-18.json)):

| Engine MiB/s | Before | After | Change |
| --- | ---: | ---: | ---: |
| ASCII | 733.2 | 747.7 | 1.02x |
| ANSI | 329.6 | 326.7 | 0.99x |
| Unicode | 131.8 | 136.8 | 1.04x |
| Long lines | 375.0 | 380.9 | 1.02x |
| Alternate screen | 166.9 | 166.1 | 1.00x |
| Synchronized screen | 564.3 | 563.7 | 1.00x |

The mixed Unicode workload is dominated by emoji, ZWJ and flag sequences, which
still take the pair path, so its gain is smaller than the per-script lines.

## Packed stores for wide runs and scalar cluster continuation

Two costs remained on Unicode lines after simple runs skipped the pair decision.

1. The general run writer built each cell through the template, cloning its side
   record, and built a wide cell's trailing half with `spacer()`. Without a side
   record the cells now come from three precomputed packed words, and over a row
   whose cells own no heap they are stored without a destructor, as ASCII runs are.
2. After a character joined the cluster before it, the rest of the text went back
   through the run writer, which set up a run only to stop again at the next
   modifier, joiner or regional indicator. Characters up to the next simple one now
   go straight to `print`, the scalar reference the run writer is tested against.

A test checks that the packed words build exactly the template's cells and spacer for
several presentations, and mutation checks confirm each word, the heap-free choice
and both store paths are caught.

| Synthetic line | Before ns | After ns | libghostty-vt ns |
| --- | ---: | ---: | ---: |
| CJK and ASCII | 152.3 | 147.3 | 98.4 |
| Hangul and ASCII | 139.2 | 125.9 | 87.8 |
| ZWJ sequences | 352.9 | 325.3 | 282.7 |
| Mixed Unicode workload line | 479.7 | 447.5 | 331.1 |

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/wide-runs-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 738.4 | 733.3 | 0.99x | 1280.4 | 1.75x |
| ANSI | 320.2 | 321.7 | 1.00x | 263.6 | 0.83x |
| Unicode | 132.7 | 142.8 | 1.08x | 190.2 | 1.48x → 1.33x |
| Long lines | 374.4 | 374.5 | 1.00x | 480.7 | 1.30x |
| Alternate screen | 161.0 | 165.9 | 1.03x | 169.5 | 1.02x |
| Synchronized screen | 546.3 | 550.9 | 1.01x | 897.0 | 1.63x |

The remaining cluster cost is the per-cluster side-record allocation and the exact
cluster cache comparison; libghostty-vt keeps grapheme data in page-owned storage.

## Single-store cell images for blank fills and ASCII runs

Removing parts of the line path one at a time, in throwaway builds, showed where
ASCII lines still lost to libghostty-vt. Its pure line feed was already slower than
AkiTTY's (21.7 against 17 ns), but refilling each recycled row with blanks cost
about 0.3 ns per written byte, and every cell store was two separate field stores.
libghostty-vt clears a row with a zero fill; AkiTTY's blank is not all zero bytes,
since it holds a space and a packed presentation.

1. A heap-free blank fill writes one 16-byte image of the blank per cell, which the
   compiler unrolls. `Row::fill_blank` and recycled-row refills share it.
2. A heap-free ASCII run writes one 16-byte image per cell, built from a base image
   and the character field's unit. Both come from reference cells, so no field layout
   is assumed, and the compiler widens the bytes in vector registers.

Both are `unsafe` writes guarded by the existing heap certificate: the source cell
has no side record (asserted), and no target owns one (debug-asserted; `has_heap`
certifies it). They apply on 64-bit targets, where a cell without a side record is
sixteen bytes with no padding (a compile-time assertion checks the size); the
WebAssembly build keeps the element-wise stores. Tests compare every fill length and every ASCII byte with the safe
element-wise stores for several presentations, and mutation checks confirm each
image term is caught. A 32-byte two-cell image was also measured and gave no
further gain.

| Synthetic ns per byte | Before | After | libghostty-vt |
| --- | ---: | ---: | ---: |
| One column rewritten (`x` wrap) | 1.128 | 0.876 | 0.483 |
| 54-byte lines with scrolling | 1.305 | 1.020 | 0.709 |

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/cell-images-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 744.3 | 931.6 | 1.25x | 1322.3 | 1.75x → 1.39x |
| ANSI | 326.7 | 326.7 | 1.00x | 272.8 | 0.84x |
| Unicode | 145.7 | 144.6 | 0.99x | 192.6 | 1.33x |
| Long lines | 382.5 | 408.9 | 1.07x | 500.3 | 1.30x → 1.21x |
| Alternate screen | 170.5 | 172.9 | 1.01x | 174.1 | 1.02x |
| Synchronized screen | 566.6 | 567.0 | 1.00x | 894.1 | 1.56x |

## Lighter synchronized-queue entries

The benchmark frame (`?2026h`, a cursor move, two rows of text with colour changes,
`?2026l`) cost 296 ns synchronized and 185 ns without the mode, against 189 and 140
ns for libghostty-vt. An empty mode pair costs about the same in both engines, so the
remaining difference is the queue: AkiTTY holds the frame's actions, replies included,
until the frame ends, where libghostty-vt applies them and holds only rendering.
That semantics is kept. Three costs in it were cut:

1. C0 controls were queued as full actions through the general dispatcher; they are
   now one-byte entries, charged the same, and replayed through the control handler
   after clearing the grapheme target as `apply` does.
2. Queued text counted its characters byte by byte for its charge; it now uses the
   standard library's word-at-a-time count.
3. A recycled CSI record whose parameter count differed from the sequence dropped or
   allocated parameter vectors; a bounded pool of 256 now supplies and keeps them.

The synchronized-output equivalence test now feeds controls followed by combining
marks and CSIs with changing parameter counts, and mutation checks confirm the
charge, the grapheme reset, the character count and the control routing are caught.

| Engine MiB/s ([raw record](../benchmarks/results/sync-entries-2026-11-18.json)) | Before | After | Change |
| --- | ---: | ---: | ---: |
| Synchronized screen | 561.0 | 578.7 | 1.03x |
| ASCII | 921.4 | 919.0 | 1.00x |
| Unicode | 141.4 | 141.8 | 1.00x |
| Long lines | 405.4 | 403.8 | 1.00x |

## Returning long ASCII stretches to the packed path

The long-lines workload wraps text that holds one wide glyph every 74 bytes. Once a
run reached that glyph, the general cell writer took it and then every ASCII byte
after it, one character at a time, until the run ended, so the packed ASCII path
handled only the very first stretch of each run. After writing a non-ASCII
character the cell writer now returns when the next 16 bytes are ASCII (one 128-bit
test of their high bits); the caller's next run starts on the packed path. Plain
ASCII never joins a non-ASCII character before it, so the handoff changes no
grapheme decision. Shorter stretches stay, as switching would cost more than it
saves. Placing the test after a non-ASCII write, instead of before each ASCII
character, kept the per-script lines within noise of their previous cost.

A test pins where the handoff happens and compares the resulting screens with the
scalar path; mutation checks confirm the condition, the mask and the window length
are caught. Enabling the test after ASCII characters as well is equivalent in
practice: a cell-path ASCII character followed by 16 ASCII bytes can only arise
after a non-ASCII character that already handed off.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/ascii-handoff-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Long lines | 406.4 | 737.3 | 1.81x | 498.3 | 1.21x → 0.67x |
| ASCII | 920.6 | 944.1 | 1.03x | 1343.3 | 1.42x |
| ANSI | 326.9 | 325.5 | 1.00x | 277.6 | 0.83x |
| Unicode | 142.7 | 143.5 | 1.01x | 198.4 | 1.35x |
| Alternate screen | 174.0 | 173.0 | 0.99x | 174.6 | 1.01x |
| Synchronized screen | 593.0 | 607.3 | 1.02x | 906.2 | 1.49x |

## Controls that own nothing

A C0 control from the parser's text fast path reached the terminal as
`Input::Action(Action::Control(_))`. `Action` has variants that own vectors, so
every line feed and carriage return ran `Action`'s drop glue, an out-of-line call
that was 6% of an ASCII profile. The fast path now emits `Input::Control(u8)`, which
owns nothing; the byte machine's controls are unchanged and both reach the same
handler. The control fast-path equivalence test maps the new input to the action it
stands for and still compares every C0 byte with the byte machine.

Two experiments in the same pass were measured and dropped: four-lane NEON stores of
sixteen ASCII cells (taken, but no gain, so stores are not the bound) and releasing
side records before a pattern refill of heap rows (no Unicode gain, 12% ASCII loss
from the refill no longer inlining). A probe timed the parser alone at 0.17 ns per
ASCII byte.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/owned-controls-2026-11-18.json)):

| Engine MiB/s | Before | After | Change |
| --- | ---: | ---: | ---: |
| ASCII | 934.8 | 962.6 | 1.03x |
| Unicode | 146.2 | 146.1 | 1.00x |
| Synchronized screen | 603.9 | 604.4 | 1.00x |

## Grapheme pair decisions from a table

Every non-simple pair in a run went through an out-of-line chain of rule checks. The
rules depend only on the two class nibbles, apart from the regional-indicator
look-behind, so they are now a `const fn` evaluated once at compile time into a
16-by-16 table (unknown classes included). A pair is decided with one lookup;
only a regional indicator after a regional indicator still counts the run before it.
The rules keep a single source, and the existing segmentation tests, which compare
against exact segmentation, cover them. Mutation checks confirm the table index
order, the regional look-behind, the unknown verdict and the rule results are caught.
Marking the lookup `#[inline]` copied it into the ASCII run writer and cost 4% on
ASCII and the alternate screen, so it is left to the compiler; ASCII, ANSI and the
synchronized screen remain within 2% of their earlier rates.

One other experiment was dropped: letting a short ASCII stretch before non-ASCII
text stay in the cell writer cost 1-4% on ASCII, long lines and the alternate screen
without a Unicode gain.

| Synthetic line | Before ns | After ns |
| --- | ---: | ---: |
| CJK and ASCII | 130.3 | 132.5 |
| Hangul and ASCII | 121.4 | 125.1 |
| é and ASCII | 105.6 | 106.4 |
| Emoji and ASCII | 125.0 | 113.3 |
| ZWJ sequences | 312.3 | 297.8 |
| Flags | 297.0 | 281.0 |
| Mixed Unicode workload line | 451.6 | 424.8 |

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/pair-table-2026-11-18.json)):

| Engine MiB/s | Before | After | Change |
| --- | ---: | ---: | ---: |
| Unicode | 145.4 | 151.2 | 1.04x |
| ASCII | 978.8 | 961.6 | 0.98x |
| ANSI | 329.3 | 321.4 | 0.98x |
| Long lines | 736.5 | 784.3 | 1.06x |
| Alternate screen | 172.5 | 173.6 | 1.01x |
| Synchronized screen | 610.6 | 599.4 | 0.98x |

## Synchronized frames that close within one chunk

A host reads the terminal only between `feed` calls, and a queued frame replays with
synchronized output already off, in order, emitting every held event in that order.
A frame whose `?2026h` and exact `?2026l` both arrive in one chunk therefore gives
the same state and the same events when its actions are applied as they arrive, so
such a `?2026h` no longer starts a queue. Frames that span chunks, eight-bit or
parameter-list ends, and timeouts keep the queue exactly as before.

Whether an end lies ahead is decided without parser positions: every literal
`ESC [ ? 2026 l` in a chunk is dispatched as an exact end, because ESC begins a new
sequence from every parser state (strings included), so the ends ahead are the
chunk's literal ends less the exact ends dispatched so far. An end the count cannot
see (eight-bit, or begun in the previous chunk) only lowers the estimate and makes
the frame queue. The chunk is counted once, on its first `?2026h`, by a word-at-a-time
search for `?`, which is rarer than ESC in escape-dense output; a queue with nothing
in it now returns from its flush at once.

A differential test feeds frames whole and one byte at a time (which always queues)
and compares events and the whole state after every part: replies and mode reports
inside frames, ends inside OSC and DCS strings, eight-bit and subparameter ends,
parameter lists, re-arming, combining marks across the frame edges, frames past the
memory bound, unclosed frames and splits inside a UTF-8 sequence. The end count is
compared with a window search over pseudo-random fragment mixes. Mutation checks
confirm the count, its start, both checked neighbours, the byte search and the
dispatched-end test are caught; dropping the "nothing queued" check, counting
subparameter ends as dispatched, and resuming the search inside a match are
equivalent and were left out or noted.

| Frame (ns) | Before | After | libghostty-vt |
| --- | ---: | ---: | ---: |
| Benchmark frame, synchronized | 275.9 | 220.6 | 186.0 |
| Same frame without mode 2026 | 174.7 | 178.5 | 124.5 |
| Sixteen empty mode pairs | 450.1 | 509.8 | 423.5 |

The empty-pair line is a worst case for the `?` search (a chunk of nothing but mode
pairs) and is about 12% slower; ordinary frames gain.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/closed-frames-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Synchronized screen | 603.6 | 744.9 | 1.23x | 906.7 | 1.21x |
| ASCII | 972.2 | 966.5 | 0.99x | 1335.2 | 1.38x |
| ANSI | 322.1 | 329.2 | 1.02x | 277.5 | 0.84x |
| Unicode | 153.9 | 148.7 | 0.97x | 196.2 | 1.3x |
| Long lines | 781.4 | 772.8 | 0.99x | 500.4 | 0.64x |
| Alternate screen | 172.3 | 173.3 | 1.01x | 176.0 | 1.0x |

## ASCII runs flagged by the parser

The parser finds the end of every text run, and knows on the way whether it took a
multi-byte scalar; the run writer then scanned the same bytes again for their ASCII
prefix. `Input::Text` now carries that flag, and an all-ASCII run, or any suffix of
it left after a row end, skips the second scan. Queue replay passes no promise. The
parser tests assert the flag equals `str::is_ascii` for every run they produce, the
run writer debug-asserts the promise, and mutation checks confirm a flag that is
never cleared, an ignored flag and a writer that trusts every run are caught.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/ascii-flag-2026-11-18.json)):

| Engine MiB/s | Before | After | Change |
| --- | ---: | ---: | ---: |
| ASCII | 965.6 | 1040.1 | 1.08x |
| Synchronized screen | 745.7 | 762.0 | 1.02x |
| ANSI | 327.1 | 341.7 | 1.04x |
| Unicode | 150.7 | 147.8 | 0.98x |
| Long lines | 782.6 | 783.9 | 1.00x |
| Alternate screen | 175.0 | 174.3 | 1.00x |

## Exact printable prefixes where a run opens

Where a text run opens, the parser skipped whole eight-byte words of printable ASCII
and left the bytes before the first control or escape to its byte loop, up to seven
per line. The word test's mask already marks that byte: a borrow starts only at a
byte below 0x20 or at a 0x7f and only reaches the bytes above it, so the lowest
flagged byte is exactly the first one that is not printable ASCII. The scan where a
run opens now returns that exact length. The scan after a multi-byte scalar keeps
whole words: there the ASCII stretches are short, and the exact form measured about
3% slower on the Unicode and ANSI workloads.

The word test now asserts that the lowest flagged byte equals the first
non-printable byte for every byte value in every lane, boundary pairs and random
words, and a new test checks the prefix length for every edge byte at every
position. Mutation checks confirm the wrong end of the mask, an off-by-one, a wrong
space bound and a dropped 0x7f test are caught.

A per-line split against libghostty-vt shows where ASCII time remains: about 9 ns of
fixed cost per text run and carriage return (two-character lines: 19.6 against
10.5 ns), and 0.37 against 0.26 ns per character. Checking the overwritten cells'
widths while storing, instead of in a vector pass before, measured slower and was
not kept.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/exact-prefix-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 1020.4 | 1078.1 | 1.06x | 1286.5 | 1.19x |
| ANSI | 341.4 | 336.2 | 0.98x | 264.6 | 0.78x |
| Unicode | 148.4 | 148.9 | 1.00x | 195.1 | 1.3x |
| Long lines | 749.8 | 782.4 | 1.04x | 501.2 | 0.64x |
| Synchronized screen | 743.9 | 754.3 | 1.01x | 878.0 | 1.19x |
| Alternate screen | 173.1 | 178.4 | 1.03x | 173.8 | 0.98x |

## The current presentation without a lookup

Every text run asked the style cache for its presentation, comparing the current
style and hyperlink with each retained slot. Short runs paid that in full: on
two-character lines it was about 18% of the samples. The terminal now remembers which
slot holds the current presentation and forgets it at each site that changes the
style or the hyperlink: SGR, cursor restore, the OSC 8 handler, soft reset and full
reset. The style field became crate-private so no other code can change it without
passing one of them. Remembering the slot, not a copy of the template, keeps a style
change from costing an extra reference count on a side record.

In debug builds every remembered answer is compared with a freshly built template.
Mutation checks remove each of the five forgetting sites in turn and point at the
wrong slot; all are caught, the soft-reset site by a new test that prints, changes
the style without an SGR, and prints again.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/current-template-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 1069.2 | 1094.1 | 1.02x | 1282.8 | 1.17x |
| ANSI | 330.0 | 328.0 | 0.99x | 266.5 | 0.82x |
| Unicode | 145.9 | 149.1 | 1.02x | 192.6 | 1.31x |
| Long lines | 775.5 | 781.9 | 1.01x | 490.2 | 0.63x |
| Synchronized screen | 742.2 | 735.1 | 0.99x | 898.7 | 1.22x |
| Alternate screen | 175.5 | 172.9 | 0.98x | 170.0 | 0.99x |

## Single-column certificates for rewritten rows

An ASCII run over cells that are not certified blank first checks that none of them
is a wide glyph or its spacer, because writing over half of one needs repair. Rows
that a program redraws in place, as the synchronized-output frame does, paid that
check on every frame. A row now also records the column before which every cell is
single-column, valid while the row's generation is unchanged: the same invariant the
blank certificate relies on, since every cell mutation advances the generation.
Only single-column ASCII stores over older cells extend it, so a redrawn row earns it
on its first rewrite and later rewrites skip the check up to it. Stores over blanks
leave it alone, which keeps the common blank-row path as it was; keeping that path
untouched was worth about 3% on the ASCII and long-line workloads in earlier drafts.
Resize, the one mutation that does not advance the generation, empties it.

The same work found that the scalar print path recorded a full-row write for every
character it placed without wide repair, which discarded the blank certificate of
each wrapped row and sent the rest of the row through the overwrite checks. It now
records the columns it actually changes.

In debug builds every use of the certificate is checked against a full scan. A new
differential test rewrites rows in place and then edits them with wide glyphs inside
and past the certified columns, marks, inserts, deletes, erases and resizes between
widths, comparing with the scalar path after every chunk. Mutation checks confirm an
extension over a gap, an ignored generation, a too-short print record, a wrong count
and a certificate extended by blank stores are caught. Three are equivalent: leaving
a stale bound after a reblank (the cells are blank and the next write ends it), a
looser clamp (the certificate never passes the blank bound) and not emptying it on
resize (resize only truncates, pads with single-column cells or rebuilds rows fresh).

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/single-column-rows-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Synchronized screen | 746.5 | 798.8 | 1.07x | 919.2 | 1.15x |
| ASCII | 1114.7 | 1132.1 | 1.02x | 1296.6 | 1.15x |
| ANSI | 335.1 | 331.9 | 0.99x | 271.6 | 0.83x |
| Unicode | 151.5 | 151.6 | 1.00x | 191.8 | 1.3x |
| Long lines | 795.6 | 915.9 | 1.15x | 497.7 | 0.56x |
| Alternate screen | 175.0 | 173.3 | 0.99x | 177.2 | 1.02x |

## Reused side records

Every joined cluster (a marked letter, an emoji family, a flag) allocates one side
record, and blanking its row frees it again, so output that scrolls such text paid
an allocation and a free per cluster per line. A probe that made small allocations
nearly free measured about 7% on the Unicode workload. Each screen now keeps up to 16
empty records: blanking a row moves the records only its cells own into the pool,
emptied on the way in so a pooled record holds no marks and no hyperlink, and a cell
that needs a record takes one from the pool before allocating. Records shared with a
style template are only released, after a plain reference-count load rules them out.
Once the loop has taken every record, the row is refilled with the pattern fill that
needs no destructor checks.

A unit test checks that shared records stay with their owner, that a pooled record
releases its link and comes back empty, and that the pool stays bounded; a terminal
test scrolls marked, linked and wide clusters away and checks that the clusters
written next hold exactly their own text, no link, the same cells as a fresh
terminal and an exact history charge. Mutation checks confirm that a record kept
with its contents, a record kept with only its marks cleared, an unbounded pool, a
missing hand-off before the fill and a pool that is never drawn from are caught;
dropping the reference-count pre-check is equivalent because the uniqueness check
still guards it.

The ANSI workload, whose colored cells share their template's record, measured about
2-3% slower from the extra pass; it remains faster than libghostty-vt.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/record-pool-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 145.9 | 156.8 | 1.07x | 191.7 | 1.24x |
| ANSI | 320.7 | 311.3 | 0.97x | 263.1 | 0.84x |
| ASCII | 1087.5 | 1096.6 | 1.01x | 1211.1 | 1.13x |
| Long lines | 881.4 | 898.6 | 1.02x | 464.2 | 0.52x |
| Synchronized screen | 789.2 | 793.8 | 1.01x | 900.1 | 1.13x |
| Alternate screen | 167.4 | 172.7 | 1.03x | 171.8 | 1.0x |

## A cluster's text kept between its characters

Each character that joins a cluster rebuilt the candidate text from the cell (lead,
every mark so far, then the new character) before looking it up, so a family emoji
rebuilt its text three times. The terminal now keeps the text of the cell it last
joined into, with that cell's position, row id and row generation. The next join
reuses it only while all three still match: every cell write advances the generation
and a recycled row gets a new id. Resize is the exception, because reflow gives a
rebuilt row its logical line's id while restarting the generation, so resize forgets
the text. In debug builds every reuse is compared with a rebuilt text, and mutation
checks confirm that a key without the generation, a key without the row id and a
resize that keeps the text are caught.

Two neighbouring ideas measured flat and were not kept: starting the cluster cache
search at the slot after the last hit, and a dedicated loop for runs of simple
non-ASCII characters (Unicode flat, ASCII and long lines 5% slower). A per-character
split shows where simple non-ASCII text stands: an accented letter costs about 5.7
against 1.1 ns in libghostty-vt, and CJK, Hangul and emoji about 2.7 times as much.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/kept-cluster-text-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 160.0 | 166.1 | 1.04x | 197.7 | 1.21x |
| ASCII | 1091.1 | 1116.8 | 1.02x | 1340.4 | 1.19x |
| ANSI | 320.3 | 314.9 | 0.98x | 270.0 | 0.84x |
| Long lines | 864.9 | 906.0 | 1.05x | 498.9 | 0.56x |
| Synchronized screen | 796.6 | 801.2 | 1.01x | 894.0 | 1.1x |
| Alternate screen | 175.4 | 176.1 | 1.00x | 174.2 | 0.98x |

## ASCII cells built in vector registers

A probe that parsed text and discarded it put the parser at 0.05 ns per ASCII
character; the cell writer took the remaining 0.35 ns. Its loop widened bytes in
vector registers and then moved each one back to a general register for an
eight-byte pair store. On aarch64 the writer now builds whole cells in vector
registers, sixteen characters at a time: each group of four characters is zipped
with the packed word and then with zero, giving four sixteen-byte cells. It runs only
when the cell images computed from two reference cells confirm that layout, and the
scalar loop takes the tail and every other target. The per-character slope fell from
0.395 to 0.345 ns. The existing store test compares exact images for 0 to 128
characters in two presentations, and mutation checks confirm swapped zips, a wrong
half, a wrong address, a wrong count and a wrong widening are caught.

The ASCII workload measured flat (0.99x over seven passes): its 54-character lines
get three groups and a six-character tail.

Engine results, rotated order, history 0 ([raw record](../benchmarks/results/vector-cells-2026-11-18.json));
this run was noisy, so the record also holds a seven-pass ASCII rerun:

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 1104.7 | 1046.7 | 0.95x | 1306.0 | 1.2x |
| Synchronized screen | 802.9 | 824.8 | 1.03x | 884.6 | 1.08x |
| Long lines | 885.0 | 901.5 | 1.02x | 464.1 | 0.51x |
| ANSI | 311.3 | 308.7 | 0.99x | 262.9 | 0.84x |
| Unicode | 158.1 | 162.0 | 1.02x | 189.1 | 1.18x |
| Alternate screen | 171.1 | 167.5 | 0.98x | 161.3 | 0.98x |

## Rows a line feed leaves for the next write

When a line feed scrolls the whole screen, the top row rotates to the bottom and is
refilled with blanks, and in ordinary output the next text overwrites those blanks
straight away. A probe that skipped the refill (wrong output, measurement only) put
the cost at 27% of ASCII throughput. A line-feed control now records the refill as
pending instead (`PendingBlank`: the row's id, how many cells hold stale text, the
background) when neither the old cells nor the blank own a side record. The row's
metadata is already that of the blank row. An ASCII store into the row refills only
the cells it did not write; every other access completes the refill first: CSI and
escape handling, the per-character and scalar print paths, deferred actions replayed
from a synchronized frame, any scroll, and the end of each `feed` and `expire_sync`,
so hosts never see a pending row. Wraps and other scrolls still refill at once,
since a cell write follows them directly. A one-flag test keeps the checks off the
other paths.

A new test feeds 56 follow-up sequences after a full-screen line feed (erases,
insertions, scrolls, scroll regions, the alternate screen, wide and combining text,
hyperlinks, insert mode, character sets, repeats, synchronized frames applied by
their end and by their timeout) at three widths, with and without history and
grapheme clustering. It compares state and events with a terminal that refills at
once. Mutation checks confirm that each completion point, the flag, both refill
ranges and both record conditions are needed. The control-byte check, the in-loop
scroll check and the resize check proved redundant and became debug assertions.

Rejected on the way: finding run ends with the standard UTF-8 validator (no
per-character gain; long lines 0.88x), a four-cell vector blank fill (0.99x
everywhere), and wrapping inside the run writer so wrapped rows also defer (ASCII
only 1.04x; Unicode and synchronized output 0.95x).

Engine results, rotated order, seven passes, history 0
([raw record](../benchmarks/results/pending-blank-rows-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 1097.2 | 1255.6 | 1.14x | 1306.6 | 1.05x |
| Synchronized screen | 837.9 | 848.6 | 1.01x | 897.9 | 1.07x |
| Long lines | 932.5 | 896.6 | 0.96x | 496.5 | 0.55x |
| ANSI | 320.4 | 317.2 | 0.99x | 275.9 | 0.88x |
| Unicode | 165.6 | 163.0 | 0.98x | 197.7 | 1.19x |
| Alternate screen | 174.3 | 172.4 | 0.99x | 174.7 | 1.04x |

Long lines lost 4%: they wrap without line feeds, so they pay only for the checks.
They remain about 1.8 times Ghostty's throughput.

## Pending rows taken by the per-character writer

The previous step left a scrolled-in row's refill to the ASCII store only; a line
that starts with other text completed the refill and then overwrote it. A profile of
CJK-only lines put two thirds of the time in the run writer and a third in the
parser. The per-character writer now takes a pending row too. The row reads as
blanks, so its containment loads are skipped, and the refill is completed around
the cells written. It has its own copy of the loop (a const parameter), kept out of
line; a single loop with a per-character test of the pending flag cost Unicode 4%,
and two copies inlined into `write_run` cost ASCII 7% and synchronized output 9%.
The pending-row test now also starts from rows of stale wide cells and spacers.
Mutation checks: skipping the refill around the written cells is caught. Restoring
the containment loads is equivalent, since a stale cell read anyway only sends the
character to `print`, which completes the refill first. The guards for a pending
row elsewhere or a cluster target on the row cannot be reached after a line feed
and are debug assertions.

Per-character cost, median of three runs: CJK lines 7.22 to 6.20 ns, `é` lines
5.57 to 5.24 ns, CJK separated by spaces 5.52 to 4.79 ns. The Unicode workload is
flat (0.99x): most of its time is in the emoji, ZWJ and flag clusters that go
through `print`.

Engine results, rotated order, seven passes, history 0
([raw record](../benchmarks/results/pending-rows-for-wide-text-2026-11-18.json)):

| Engine MiB/s | Before | After | Change |
| --- | ---: | ---: | ---: |
| Unicode | 164.5 | 162.8 | 0.99x |
| ASCII | 1238.6 | 1274.0 | 1.03x |
| Synchronized screen | 850.9 | 850.4 | 1.00x |
| Long lines | 892.3 | 898.9 | 1.01x |
| ANSI | 316.1 | 317.4 | 1.00x |
| Alternate screen | 170.7 | 172.1 | 1.01x |

## Escape sequences entered without a reset

A profile of the synchronized-screen workload put 8.5% of its samples in
`Parser::begin` and another 4% in `memmove`. `begin` runs twice per escape
sequence: on entry and on the return to text. It returned parameter vectors to
their pool with `Vec::append`, which calls a block copy for one or two entries; it
now pops and pushes them. And the reset on entry is skipped when the sequence
starts from the Text state, which only `begin(State::Text)` and `Default` enter, so
everything `begin` resets is already reset there; a debug assertion checks that
invariant on every entry in the test suite. Mutation checks: removing the state
change, the parameter return, the parameter clear or the prefix reset in `begin`
is caught.

Engine results, rotated order, five passes, history 0
([raw record](../benchmarks/results/escape-entry-2026-11-18.json)); the two steps
together, with libghostty-vt measured afterwards:

| Engine MiB/s | Pool step | Entry step | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: |
| Synchronized screen | 1.05x | 1.07x | 895.2 | 1.0x |
| ANSI | 1.01x | 1.03x | 267.2 | 0.83x |
| Alternate screen | 1.03x | 1.04x | 169.7 | 0.99x |
| ASCII | 0.99x | 0.99x | 1308.0 | 1.06x |
| Unicode | 0.99x | 1.00x | 191.6 | 1.21x |
| Long lines | 1.00x | 1.00x | 484.0 | 0.55x |

## Carriage returns applied where they are parsed

A longer profile of the ASCII workload put 26% of its samples in per-line dispatch:
the feed closure, `print_run` and `control`. Every line ending passes a carriage
return through the out-of-line `control`, which for it only clears the column and a
pending wrap. The feed closure now applies a carriage return itself and calls
`control` for every other control byte. A new test checks that a vertical tab and a
form feed still act as line feeds and a carriage return does not; mutation checks
confirm that a kept column, a kept pending wrap or the wrong byte is caught.

Rejected: rotating rows with `pop_front` and `push_back` instead of `rotate_left`
(ASCII 0.97x, long lines 0.96x).

Engine results, rotated order, history 0
([raw record](../benchmarks/results/inline-carriage-return-2026-11-18.json)); ASCII
and synchronized screen over seven passes, the rest over five:

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 1219.5 | 1286.7 | 1.06x | 1262.9 | 0.99x |
| Synchronized screen | 894.2 | 902.4 | 1.01x | 872.2 | 0.96x |
| Unicode | 159.0 | 158.2 | 0.99x | 187.5 | 1.18x |
| Long lines | 890.7 | 881.1 | 0.99x | 483.1 | 0.54x |
| ANSI | 320.3 | 322.7 | 1.01x | 266.5 | 0.83x |
| Alternate screen | 174.3 | 174.9 | 1.00x | 167.4 | 0.96x |

libghostty-vt's own ASCII result ranges from about 1210 to 1340 MiB/s between runs
on this host, so ASCII is level with it here, not ahead.

## Cluster tails joined in one step

A profile of the Unicode workload put about a fifth of its samples in the
per-character cluster path: each character after the first of a ZWJ sequence such
as 👩🏽‍💻 went through `print` on its own, with a cluster-cache lookup, a combining
push and the row's bookkeeping. When the run writer stops at a joining character,
`join_tail` now takes it and the non-simple characters after it in one step, if
`print` taking them one at a time is certain to append each to the target cell and
keep the cell's width. Then `print` would neither repair neighbouring cells nor
wrap, and the step leaves the same marks, generation (repeated `record_write` calls
of one advance equal one call of their sum), certificates, cluster scratch and last
printed character. The check simulates `print`'s rules: the run writer's verdict for
the first character, the pair rules for the rest, exact segmentation where they say
`Unknown`, the clamped width of every candidate and the combining bound. Its answer
depends only on the cell's text and the tail, so it is kept in eight slots keyed by
both, with the split between them. Anything else goes through `print` as before.

The run-versus-scalar corpus gained marks past the combining bound and longer
family and keycap sequences. Mutation checks catch a missing width check, combining
bound, generation count, scratch, last printed character, heap mark or charge
reset, and any change to the simulated rules. Survivors are equivalent: the first
verdict check (the pair rules agree with exact segmentation), the zero-width and
edge guards (a target is always a placed lead cell), the remembered scratch
position (a cache only), the split in the key (a wrong split fails the width
check) and the tail's end (a simple character fails the simulation). Two counting
tests now feed the family one character per call, so they still reach `print`.

The per-character writer also tests the next byte before loading sixteen to decide
on an ASCII hand-off, so non-ASCII text that continues skips the load: CJK and `é`
lines cost 2 to 4% less per character.

Rejected: deferring rows whose cells own side records by releasing the records
during the scroll (Unicode 0.97x, ANSI 0.91x: lines that start with an escape
sequence complete the refill at once and pay a second pass), and comparing cluster
keys as fixed-size arrays (Unicode 0.95x: padding the query costs more than the
`memcmp` calls it saves).

Engine results, rotated order, seven passes, history 0
([raw record](../benchmarks/results/cluster-tails-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 161.3 | 169.3 | 1.05x | 196.1 | 1.16x |
| ASCII | 1308.6 | 1320.5 | 1.01x | 1316.4 | 0.99x |
| Synchronized screen | 916.4 | 929.1 | 1.01x | 911.2 | 0.98x |
| Long lines | 891.3 | 910.7 | 1.02x | 496.1 | 0.54x |
| ANSI | 328.2 | 335.1 | 1.02x | 272.3 | 0.82x |
| Alternate screen | 179.5 | 177.7 | 0.99x | 173.4 | 0.97x |

Per line of the Unicode workload, the family sequence now costs 87 ns against
libghostty-vt's 80 ns; CJK (67 against 34 ns), the flag (70 against 45 ns), the
lone pictograph and `é` hold the rest of the gap.

## Clusters growing in place

A flag's second regional indicator, or an emoji presentation selector, grows its
cell from one column to two. `join_grapheme` sent every such change through the
general wide-cell repair: take the cell out, blank it and its neighbour, record
three one-step writes, then store the cell and its spacer. When the neighbour is an
ordinary narrow cell inside the row, the net effect is now stored directly: the
mark, the width, the spacer, and one write of three steps, which records the same
generation and certificates. Wrapping, wide neighbours, spacers and shrinking
widths still take the general repair.

Both the run path and the scalar reference reach this code, so the run-versus-
scalar tests cannot see it; a test-only switch forces the general repair, and a new
test compares the two over flags and selectors on blanks, text, wide glyphs,
spacers, styled and linked cells, at and near the edge, with and without autowrap,
whole and one character per feed. Mutation checks catch a missing neighbour or edge
condition, a wrong generation count or certificate end, a missing spacer, a wrong
pending wrap and a missing charge reset.

Engine results, rotated order, seven passes, history 0
([raw record](../benchmarks/results/clusters-growing-in-place-2026-11-18.json));
the host was noisy during the libghostty-vt run:

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 165.3 | 168.3 | 1.02x | 185.5 | 1.14x |
| ASCII | 1298.6 | 1281.0 | 0.99x | 1206.0 | 0.93x |
| Synchronized screen | 907.0 | 917.6 | 1.01x | 881.0 | 0.96x |
| Long lines | 893.9 | 896.9 | 1.00x | 488.1 | 0.55x |
| ANSI | 327.4 | 324.7 | 0.99x | 265.3 | 0.82x |
| Alternate screen | 173.7 | 174.0 | 1.00x | 165.3 | 0.95x |

## Rejected: a parser loop for scalars without constrained continuations

Two- and three-byte scalars whose lead is not 0xe0 or 0xed (Latin, Greek,
Cyrillic, most CJK, kana and Hangul) are valid exactly when their continuation
bytes have the top bits `10`, so a loop can take consecutive ones without the
general check. After each multi-byte scalar, it cut the parse-and-write cost per
character of CJK-only lines from 6.06 to 5.06 ns and of `é` lines from 5.18 to
4.45 ns. However, CJK separated by spaces rose from 4.73 to 5.11 ns. The Unicode
workload, whose CJK comes in short groups, measured 0.99x, as did ASCII and
synchronized output. Using the same check in place of the general one at every
scalar was worse everywhere: Unicode 0.94x, ASCII 0.96x, synchronized output
0.95x. Neither was kept.

## Releasing records only from cells that own one

Refilling a recycled row whose cells may own side records passed every cell to
`RecordPool::keep`, which also wrote `None` back into each cell before the fill
overwrote it again. `keep_all` now only reads the cells that own no record and
hands the others to `keep`. The end state is the same, since `keep` on a cell
without a record does nothing the fill does not redo. ANSI rose 4% (its rows hold
styled cells with records); the rest held. Trying the tail cache's last-hit slot
before the others was flat (Unicode 1.00x) and was not kept.

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| ANSI | 325.6 | 339.4 | 1.04x | 268.6 | 0.79x |
| Unicode | 168.3 | 169.7 | 1.01x | 191.6 | 1.13x |
| ASCII | 1300.2 | 1300.5 | 1.00x | 1290.9 | 0.99x |
| Synchronized screen | 922.9 | 926.4 | 1.00x | 898.7 | 0.99x |
| Long lines | 897.6 | 895.8 | 1.00x | 480.4 | 0.54x |
| Alternate screen | 174.6 | 174.6 | 1.00x | 171.5 | 0.98x |

Raw record: [record-release-scan](../benchmarks/results/record-release-scan-2026-11-18.json).

## Simple stretches in their own loop

An instruction-level profile of `é` lines (a Time Profiler trace, its samples
mapped to the binary by hand) put 64% of the time in the per-character writer.
That was about 60 instructions per character, spread evenly, with the loop's state
(the grapheme flag, the column count, the text length) reloaded from the stack: the
general loop is large enough that its state does not stay in registers. After a
simple character, a stretch of simple characters cannot join anything, so
`simple_stretch` now writes it in a small out-of-line loop when the template has
plain words and the row's cells own no record. It stops exactly where the general
loop would: before any other character, a character that does not fit, an
uncontained cell, or after the ASCII hand-off. The general loop then continues from
there.

The run-versus-scalar corpus gained simple non-ASCII text overwriting narrow cells,
wide leads and spacers after a simple character. Mutation checks catch a missing
edge, containment (narrow or wide), spacer or hand-off check, a hand-off that does
not stop, use without a simple predecessor or over cells with records, and a lost
last column or character. The width clamp is equivalent: it matters only for a
wide character at column 0 of a one-column grid, and a stretch never starts at
column 0.

Per character, median of three runs: CJK lines 6.06 to 5.36 ns, `é` lines 5.13 to
4.10 ns, CJK with spaces 4.75 to 3.92 ns. The Unicode workload, whose simple
stretches end at its emoji, measured 1.01x; nothing else moved. libghostty-vt
afterwards, per character: CJK 2.81, CJK with spaces 3.87, `é` 1.16, lone
pictographs 3.84 (ours 9.98), flags 15.58 (ours 24.53), and the family sequence
24.26 (ours 19.67).

| Engine MiB/s | libghostty-vt | AkiTTY | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: |
| Unicode | 189.4 | 168.2 | 1.13x |
| ASCII | 1296.4 | 1295.5 | 1.0x |
| Synchronized screen | 878.9 | 929.8 | 0.95x |
| Long lines | 491.2 | 895.3 | 0.55x |
| ANSI | 265.8 | 339.3 | 0.78x |
| Alternate screen | 173.6 | 175.9 | 0.99x |

Raw record: [simple-stretches](../benchmarks/results/simple-stretches-2026-11-18.json).

## Stretch entry and ASCII classes

A profile of lines of lone pictographs with spaces showed three avoidable costs.
The writer called `simple_stretch` for every pictograph that followed a space, and
the stretch returned at once without writing (11%); it now runs only once the
current character is known to be simple. The space after each pictograph called
`class_direct` out of line (3%); ASCII classes now come from a 128-entry constant
table that a test checks against the classifier for every ASCII character. And
`join_classes`, a single table lookup, was a call (7%); it is inlined, with the
regional-indicator count kept out of line. The stretch also keeps its result in
locals instead of writing the returned struct on every character.

Mutation checks catch each wrong ASCII table entry (CR, LF, DEL, the printable
width) and a table that is not used. Dropping the new simple check before the
stretch is equivalent, since the stretch writes nothing for a character that is not
simple; it is there for speed only.

Rejected: a parser scan with direct paths for two-byte leads and for three-byte
leads other than E0 and ED, moved out of line. CJK lines fell from 5.38 to 4.57 ns
per character, but the ASCII workload measured 0.93x.

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 170.5 | 176.4 | 1.03x | 194.4 | 1.15x |
| ASCII | 1275.8 | 1293.0 | 1.01x | 1306.1 | 1.01x |
| Synchronized screen | 928.7 | 921.1 | 0.99x | 895.1 | 0.96x |
| Long lines | 894.3 | 914.0 | 1.02x | 493.8 | 0.55x |
| ANSI | 336.5 | 340.1 | 1.01x | 272.6 | 0.80x |
| Alternate screen | 176.0 | 177.5 | 1.01x | 175.7 | 0.99x |

The Ghostty columns come from a separate run on the same build, in which
libghostty-vt's Unicode figure also rose (194.4 against 189.4 before); host noise
is about 3%. Per character against libghostty-vt: lone pictographs 8.16 against
3.87 (9.98 before), CJK 5.29 against 2.82, and flags 23.74 against 15.65.

Raw record: [stretch-entry-and-ascii-classes](../benchmarks/results/stretch-entry-and-ascii-classes-2026-11-18.json).

## Flags inside runs

A flag's second regional indicator always left the run writer: the pair verdict
was `Yes`, so the run broke to `print`, which grew the cell from one column to two
in `join_grapheme`'s direct branch, and the rest of the line started a new run.
Since every pair of regional indicators measures two columns (a test checks all
676), the run writer now does that growth itself when the first indicator was
written in the same run as a plain one-column cell and the next cell is narrow or
the row is pending. The net effect is the direct branch's: the indicator appended,
the width and spacer, three generation steps, the heap flag and charge, and the
flag's text left in the cluster scratch. The next character then consults the
flag's cell, as at the start of a run, so a third indicator is decided against the
whole cluster.

The first version did this inline in the loop. Flags got faster, but a line without
any flag lost 7 ns (229.8 to 237.1) because the extra loop state cost registers, and
the Unicode line got slower overall. `grow_flag` is now out of line and records its
own two generation steps, heap flag and charge, so the loop only carries the flag's
column.

The growth oracle test (in-run growth against the general repair, whole and one
character per feed) gained runs of indicators, a mark after an indicator written in
the run, a wide glyph after the first indicator, and pending rows. The run tests now
expect a flag to be written by the run, with the same three classifications.
Mutation checks catch dropping either indicator test, the edge, the narrow-cell
check, the generation steps, the heap flag, the charge, the width, the spacer, the
`previous` reset, the scratch text and the last character. Four mutants are
equivalent:
- checking a pending row's stale cell only sends some flags to `print`, which gives
  the same result;
- the growth's own end column is always covered by the run's final write;
- leaving the old target in place can only add breaks to `print`;
- a remembered scratch position, if not reset, can never match the new generation.

Per line, median of three: four flags 304.5 to 195.1 ns, the Unicode workload's line
317.6 to 294.8 ns, the same line without its flag 229.2 to 230.7 ns. Flags now cost
13.29 ns per character against libghostty-vt's 15.69 (23.74 before).

Also rejected: calling an out-of-line scan of scalars from the parser's multi-byte
branch, which kept ASCII flat but measured Unicode 0.93x (one call per short CJK
word).

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 173.7 | 182.2 | 1.05x | 188.9 | 1.04x |
| ASCII | 1295.2 | 1286.6 | 0.99x | 1269.9 | 0.99x |
| Synchronized screen | 930.2 | 914.6 | 0.98x | 900.5 | 0.97x |
| Long lines | 897.4 | 901.0 | 1.00x | 485.2 | 0.55x |
| ANSI | 337.1 | 334.7 | 0.99x | 264.7 | 0.78x |
| Alternate screen | 177.6 | 175.1 | 0.99x | 162.3 | 0.93x |

Raw record: [flags-in-runs](../benchmarks/results/flags-in-runs-2026-11-18.json).

## Decoding simple stretches by lead byte

`simple_stretch` decoded with the generic `chars()` iterator, asked `simple_width`
about each scalar and then recomputed its length. It now decodes by lead byte and
decides simplicity from the ranges each length can reach: printable ASCII (a run
holds no other ASCII), two-byte scalars below U+0300 other than the C1 controls, the
two pictographs and the soft hyphen, and the three-byte kana, CJK and Hangul blocks.
Four-byte scalars are never simple. Debug assertions compare each decision with
`simple_width` and each length with the scalar's.

A new test runs the stretch over every scalar up to U+2FFFF and checks that it takes
exactly the simple ones, at their width and length. Mutation checks catch a wider
two-byte lead range, a missing C1, pictograph or soft-hyphen exclusion, each block
edge, the three-byte width and the length. Handing off after an ASCII character too
is equivalent: it only changes which writer stores the following ASCII.

Accented Latin text gains (a French sentence 164.6 to 138.0 ns per line, `é` lines
110.2 to 102.8 ns). CJK lines (110.2 to 112.9 ns) and the Unicode workload's line
(289.0 to 292.3 ns) are flat within noise, so the CJK cost is not in decoding. All
six workloads are flat.

Rejected in this round, all measured against the build before:
- the stretch also taking plain and pictograph characters, with their classes passed
  back to the run writer: emoji lines 1.12x and box drawing 1.17x, but `é` 0.92x,
  flags 0.88x and Unicode 0.99x; as a const-generic variant only for stretches that
  start at such a character, flags 0.94x and the Unicode line 0.98x;
- the stretch reading such characters only from property pages already built, so it
  makes no call: the Unicode line 1.04x and Vietnamese 1.43x, but French 0.95x,
  German 0.93x and the Unicode workload 1.00x;
- a per-row lower bound on the columns that own records, so a refill releases
  records only from there: Unicode 1.00x;
- the parser trying an ASCII word after a scalar only when an ASCII byte follows:
  the Unicode line 1.00x;
- sending ASCII prefixes shorter than four bytes before other text straight to the
  cell writer: the Unicode line 0.99x, and 0.95x for a family-and-flag line;
- counting plain and pictograph characters as simple predecessors: the Unicode line
  1.00x, emoji 0.96x.

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 180.0 | 180.3 | 1.00x | 196.0 | 1.06x |
| ASCII | 1298.7 | 1299.1 | 1.00x | 1307.3 | 1.00x |
| Synchronized screen | 916.5 | 925.9 | 1.01x | 899.8 | 0.94x |
| Long lines | 912.9 | 916.8 | 1.00x | 497.8 | 0.53x |
| ANSI | 341.8 | 338.5 | 0.99x | 281.4 | 0.81x |
| Alternate screen | 176.7 | 177.6 | 1.00x | 173.0 | 0.94x |

Raw record: [stretch-decoding](../benchmarks/results/stretch-decoding-2026-11-18.json).

### Further rejected attempts after lead-byte decoding

Measured per line against the build with lead-byte decoding, and, where noted,
against libghostty-vt 1.0.1 on the same host:
- `join_tail`'s cell work as a free function over the borrowed row and pool: the
  family line 1.09x, but the Unicode line 0.97x and combining accents 0.94x;
- after a multi-byte scalar, finding the run end with an eight-byte control scan and
  the standard UTF-8 validator: French 0.88x, emoji 0.94x (the standard validator
  costs more per byte than the per-scalar check);
- checking pairs of three-byte scalars with one eight-byte load in the parser: pure
  CJK 1.12x, but the Unicode line 0.99x and emoji 0.95x, since its CJK runs are two
  or three characters long;
- simple stretches also taking E2 and four-byte characters whose property page is
  built (box drawing, arrows, pictographs): the Unicode line 1.03x, but German 0.95x
  and French 0.97x;
- an inline hit path for the style template: within noise.

Where the Unicode workload's gap sits, by adding one segment at a time to its line:
the CJK segment costs about 15 to 20 ns more than in libghostty-vt, `😀 ` about
14 ns more and the flag up to 30 ns more, while the family is about 54 ns cheaper. A
line holding only `x` costs about 4 ns more. A pure CJK line spends about 2.6 ns per
character in the stretch and 2.1 ns in the parser, against libghostty-vt's 2.9 ns for
both; the stretch stores 32 bytes per wide character, well under one cycle of store
bandwidth, so it is bound by instructions, and halving the cell size alone would not
close this.

## Validating text sixteen bytes at a time

The parser checked each multi-byte scalar on its own (`scalar_width`) and tried an
ASCII word after it. Once per run, after the first multi-byte scalar, it now takes
whole sixteen-byte chunks with NEON: a compare for C0 controls and DEL, and the
lookup-table UTF-8 validation of Keiser and Lemire ("Validating UTF-8 In Less Than
One Instruction Per Byte", 2021), whose three nibble tables give each byte's error
classes from the byte before it and its own high nibble, matched against the
continuation bytes that three- and four-byte leads two and three bytes back require.
A sequence cut by the last chunk is backed off, and the per-scalar scan continues
from there as before, so the run ends exactly where it did. Other targets take no
chunks.

Tests compare it with the per-scalar scan: every byte value at forty positions in
text of each sequence length, every pair of bytes across a chunk edge, and 200,000
random mixtures of valid and invalid sequences. The taken prefix is never past the
scan's end, is valid UTF-8, and holds every whole chunk inside the scan's prefix
except a backed-off sequence. Mutation checks catch the control and DEL compares,
the continuation requirement, the four-byte lead, single table entries (surrogates,
two-byte overlongs, too-large four-byte leads, the C0..CF row), the previous-byte
shift, the carried chunk and each part of the back-off.

The Unicode workload line falls from 295.2 to 263.7 ns, a CJK line from 115.0 to
106.0 ns, French from 137.7 to 124.8 ns and German from 128.5 to 113.0 ns. Emoji
and ASCII lines are flat.

Engine results, rotated order, five passes against the build before and seven
against libghostty-vt 1.0.1, history 0
([raw record](../benchmarks/results/neon-text-chunks-2026-11-18.json)):

| Engine MiB/s | Before | After | Change | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unicode | 183.2 | 199.7 | 1.09x | 192.4 | 0.97x |
| ASCII | 1294.4 | 1287.0 | 0.99x | 1302.5 | 1.01x |
| Synchronized screen | 938.0 | 922.5 | 0.98x | 897.2 | 0.98x |
| Long lines | 928.4 | 911.1 | 0.98x | 485.0 | 0.54x |
| ANSI | 341.9 | 335.4 | 0.98x | 268.2 | 0.80x |
| Alternate screen | 178.6 | 176.6 | 0.99x | 174.4 | 1.00x |

The ASCII, synchronized and ANSI workloads never reach the new code; their changes
are within the host's noise.

### ASCII chunks and the mixed scan out of line

The first version cost the ASCII and long-line workloads 2% (rotated, seven passes:
1290.0 to 1267.6 and 903.1 to 889.4 MiB/s). ASCII text never reached the chunks, but
the run-once flag and the call grew the ASCII scan. The scan after a run's first
multi-byte scalar now lives in its own out-of-line function (`mixed_text_end`): the
chunks, then the per-scalar loop as before, so the ASCII scan holds less than it did
before chunks. The long-line workload is one run with a wide character every 76
bytes, so nearly all of it went through full validation, which costs more per byte
than the ASCII words. A chunk with no high bit set now needs only the control
compare and a check that the chunk before did not end inside a sequence (a lead in
its last three bytes at or above F0, E0 or C0 by position).

A new test puts every lead byte at each of the last six positions of a chunk with
its continuation bytes cut by the chunk edge, before an ASCII chunk and before a
mixed one; mutation checks catch each of the three limits, the control compare and
the incomplete check. Not updating the previous chunk after an ASCII one is
equivalent (both end at a character boundary, so the next chunk's first bytes are
judged the same), as is leaving out the ASCII words in the mixed scan (only speed).

Against the build before chunks, rotated, seven passes: ASCII 1286.9 to 1310.0
(1.02x), long lines 906.6 to 936.7 (1.03x), Unicode 180.5 to 197.5 MiB/s (1.09x).

Against libghostty-vt 1.0.1, rotated, seven passes, history 0
([raw record](../benchmarks/results/neon-ascii-chunks-2026-11-18.json)):

| Engine MiB/s | AkiTTY | libghostty-vt | Ghostty / AkiTTY |
| --- | ---: | ---: | ---: |
| Unicode | 195.5 | 184.3 | 0.94x |
| ASCII | 1318.7 | 1250.9 | 0.95x |
| Synchronized screen | 932.3 | 857.3 | 0.92x |
| Long lines | 926.5 | 462.4 | 0.50x |
| ANSI | 343.0 | 267.1 | 0.78x |
| Alternate screen | 176.1 | 166.3 | 0.94x |

In that zero-history run, AkiTTY recorded the higher median on each workload.

## Reference engine throughput

On 2026-11-19, five arm64 engine builds processed identical fixtures from
`benchmarks/workloads.json` on an Apple M3 Max running macOS 27.2.1 (26B131).

- AkiTTY 1.4.0 at `c0e5f9d3f5b18776aeb2da00fe728e5d6fe484da` and
  `alacritty_terminal` 0.26.1-dev at
  `aa5d942f46c40184a3f214830ff5f7989f4733a1` used Rust 1.99.1 release builds
  with thin LTO and one codegen unit. Alacritty used the dependency versions
  from its source snapshot. [Alacritty source revision](https://github.com/alacritty/alacritty/commit/aa5d942f46c40184a3f214830ff5f7989f4733a1)
- Ghostty used the official libghostty-vt 1.0.1 XCFramework and a local
  libghostty-vt 1.0.2-dev build from Ghostty source revision
  `f3e1f65bb602ac3d441ffdd5f9645bef66a39648`. Both reported ReleaseFast and
  SIMD. The latter used Zig 0.17.1 targeting baseline ARM64.
  [Official artifact checksums](https://release.files.ghostty.org/libghostty-vt/1.0.1/SHA256SUMS)
  · [Ghostty source revision](https://github.com/ghostty-org/ghostty/commit/f3e1f65bb602ac3d441ffdd5f9645bef66a39648)
- Kitty used the native engine in the signed arm64 macOS bundle for 0.50.0.
  [Kitty release](https://github.com/kovidgoyal/kitty/releases/tag/v0.50.0)

The AkiTTY, Ghostty and Alacritty adapters share a C timing loop. Kitty's test
feed times include Python calls and one input copy per feed. The timer covers
parsing, grid mutations and scrollback growth. Grid creation, teardown and state
extraction run outside it. PTY transport, font shaping, painting and input
latency are separate measurements. Each new grid is 120×40 with a 1,000-row
limit. AkiTTY and Ghostty explicitly enable grapheme clustering. Alacritty and
Kitty use their native Unicode behavior.

Each fixture repeats its complete UTF-8 pattern as many times as fit in 8 KiB.
Each sample sums feed time across 32 fresh grids, with four identical feeds
per grid to measure scrollback growth below the eviction limit. A pass takes
24 samples after three warmups. The engines rotate through five positions in
each of two sweeps. The reported rate is the median of the ten pass rates.
Each pass rate divides the sample byte count by the median elapsed time.

The harness compares the last grid of every sample with AkiTTY. It checks
visible text with trailing blanks and wide-cell placeholders omitted, cursor
position, active screen, retained history count and first-column foreground
colors. Separate probes check RGB color application, entry into the alternate
screen and cursor advance after successive Unicode clusters. Alacritty advances
four extra columns at the ZWJ emoji, so its Unicode timing appears only in the
raw record. The synchronized-screen fixture contains complete frames in each feed.

AkiTTY recorded the highest medians for long lines, synchronized output and
the matched Unicode workload. The Ghostty builds had higher ASCII and ANSI
color medians. Pass ranges overlap on several workloads, including alternate
screen and Unicode. The November 18 comparison above used zero history and
different batching. This run covered the three reference projects represented
in the table. Calyx, cmux, iTerm2, Warp, Zellij and Zentty were outside the
timed set.

The raw record includes every measured duration, pass order, pass-rate ranges,
state digests, the probe results and artifact fingerprints. The headless
comparison adapters were built locally outside the product build.
[Raw reference engine measurements](../benchmarks/results/reference-engine-throughput-2026-11-19.json)

## macOS PTY throughput

On 2026-11-19, the signed arm64 AkiTTY 1.4.0 bundle (build 10400, commit
`3d7cd93e3056d4dd6ec6499de1b72c1c8cdb015d`) and the signed cmux v0.65.2.2
release bundle (marketing version 0.65.2, build 113) ran on the same Apple
M3 Max with macOS 27.2.1. The benchmark verified both download hashes and
bundle signatures. [AkiTTY release](https://github.com/defai-digital/akitty/releases/tag/v1.4.0)
· [cmux release](https://github.com/manaflow-ai/cmux/releases/tag/v0.65.2.2)

Each launch used an isolated home, one hidden terminal and a 98×25 PTY grid.
Scrollback was configured off. AkiTTY used Menlo 16 pt. cmux used Menlo 12 pt
with adjusted padding to reach the same grid. The producer set the PTY to
byte-preserving mode and sent about 8 MiB per sample. It requested grapheme
mode reset and verified that ASCII, ANSI color and CJK text advanced the
cursor by the same number of columns in each app.

The timer ran from the first payload write through receipt of the cursor
position report after a trailing marker. This measures PTY transport,
terminal processing and the reply path. Screen preparation was outside the
timer. The harness verified the app was hidden at each workload boundary.
The three pairs ran in the order AkiTTY/cmux, cmux/AkiTTY, AkiTTY/cmux.
Both members of each pair used the
same shuffled workload order. Each launch ran three warmups and nine timed
samples per workload. Two additional cmux launches stopped before timing
because windows became visible during setup.

The table in the README divides the payload byte count by the median
elapsed time across 27 samples. AkiTTY's ANSI color and CJK medians were
1.33× and 1.42× cmux's, respectively. The per-launch median ranges overlap
for ASCII and long lines. The raw record includes payload hashes, app
fingerprints, PTY geometry, cursor-width checks and every timed sample.
[Raw macOS PTY measurements](../benchmarks/results/cmux-pty-throughput-2026-11-19.json)
