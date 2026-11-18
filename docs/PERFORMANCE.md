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
