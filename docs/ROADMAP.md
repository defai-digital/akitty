# AkiTTY implementation roadmap

This roadmap records shipped behavior through [AkiTTY 2.4.1](releases/2.4.1.md)
and the remaining qualification and feature work.
Native and Web now share the independently authored `akitty-vt` Rust engine.
The native app uses Rust/Swift integration and CoreText/Metal rendering; Web uses
WASM and a reauthored Canvas frontend. Neither builds an upstream terminal engine.
Performance must be measured separately for each host.
The [original quality milestone](archive/QUALITY_IMPROVEMENTS.md) introduced a source-backed
[compatibility matrix](COMPATIBILITY.md), [Native/WASM benchmark](../benchmarks/README.md)
and [reproducible agent approval demo](AGENT_DEMO.md).
See [architecture](ARCHITECTURE.md) for the current implementation and
[the README](../README.md#what-is-implemented) for shipped behavior.

## 1. Performance and stability

Implemented foundation: local engine ownership, synchronized-output timeout recovery,
PTY read diagnostics, required repeated concurrent PTY/pane cleanup checks, and
real-browser canvas/input/lifecycle tests. Run a longer PTY soak with
`AKITTY_STRESS_ROUNDS=100 cargo test --locked -p akitty-core --test lifecycle_stress -- --nocapture`.
This exercises 800 sessions and checks that descriptors, threads and RSS settle.
It does not establish multi-day reliability or complete terminal conformance.
`AKITTY_SLEEP_WAKE_MANUAL=1 swift test --package-path macos --filter AkittyKitTests.SleepWakeTests`
performs an opt-in manual system sleep/wake qualification; it skips in normal CI.


Establish repeatable baselines before changing hot paths. Priorities are:

- Measure input throughput, full/partial snapshot cost, typing latency, idle
  wakeups, and memory with several panes and graphics workloads.
- Partial snapshots carry a `shift` when the screen scrolled, so streaming output
  sends only new rows; snapshots serialize outside the model lock and animation
  frames are shared rather than copied. Filter-buffer copies and per-slice event
  draining were reduced after 1.3.5 (about 20% more feed throughput). Scrolled
  frames now reuse opaque text bitmap pixels when device-pixel geometry aligns. Coalesced scrolls relocate
  pending damage; exposed rows, cursor damage and complex/decorated text rows are redrawn. Images,
  composition, cropped grids and fractional geometry retain the full repaint fallback. Moved pixel rows
  still upload to Metal; this optimizes CPU raster work rather than eliminating the GPU upload.
- The PTY worker now wakes through a self-pipe for input, resize and close, sleeps
  up to 250 ms when idle, coalesces queued resizes and applies up to 256 KiB per pass.
  A separate reader thread owns every read through a fixed ring of four 64 KiB slots,
  so parsing overlaps reading and the host is woken once per applied batch.
- Accepted input signals the host only when it snaps the viewport back from scrollback or
  marks an unedited prompt dirty; repeated typing does not produce a no-op snapshot/wake.
  The PTY worker signals a host-notification pipe whenever it advances the model, so an
  idle pane no longer polls on a 30 Hz timer; a 1 Hz safety tick backstops a missed wake.
  A timed chrome status or progress also wakes the host when it expires, so it clears on time.
  Hidden panes (background tabs, occluded windows, minimized windows, a hidden app) coalesce
  wakeups to 4 Hz and the view polls again when shown. A pane in a background tab, or one that
  becomes hidden, occluded, or minimized, releases its window-sized bitmaps and Metal textures,
  stops rasterizing, and repaints in full when it becomes visible again.
  Measured idle on an Apple M5 Max Mac (macOS 27.2, release build, idle zsh, 60 s `top` samples): four
  windows use 0.10% CPU and about 34 context switches a second, eight use 0.21% and about 63, with almost
  no idle wakeups; hiding the app changes neither. Each pane adds about eight switches a second, which
  matches the PTY worker's 250 ms idle poll for a silent child exit.
- The Metal text path draws wide (two-column) monochrome single-scalar cells and single-cell colour
  clusters from the glyph atlas, so CJK ideographs, kana, hangul and fullwidth forms, plus emoji such
  as `😀`, `❤️`, `👍🏽` and `#️⃣`, no longer force a whole-frame CPU raster. Clusters that span
  cells — ZWJ sequences and flags — still fall back, as do combining sequences, wide geometric glyphs
  and decorations on wide cells. Drawing a spanning cluster from the atlas needs cluster iteration in
  the composer, which today iterates raw cells: eligibility excludes a superset of the scalars
  `GlyphClusters.merge` joins on, and every join starts at a cell carrying one, so on an eligible frame
  merging is the identity. `testEveryCellMergeWouldJoinIsRefusedByEligibility` pins that coupling. Eligibility is per
  frame, so one spanning cluster left on screen keeps that frame on the CPU path, and a repertoire
  larger than either atlas page stands down to it after two rebuilds.
- Engine cells are 40 bytes (packed colours, boxed combining marks, one shared
  hyperlink record per OSC 8 target), so grid and scrollback memory halved and the
  64 MiB history cap retains twice as many rows. Printable ASCII bypasses the parser
  state machine, and snapshots resolve the selection range once rather than per
  cell. See the [committed benchmark baseline](../benchmarks/baseline-macos-arm64.json).
  In 2.3.1, clearing the alternate screen renews row identities and reuses the
  metadata of rows already known to be clean and blank.
- Extend malformed-input and stream-chunking coverage, including graphics/chrome
  sequences, Unicode, resets, resize, and partial/full snapshot equivalence.
- Stress repeated open/close, shell exit during output, resize/input bursts,
  backpressure, and renderer fallback. Check that child processes, file
  descriptors, threads, and memory settle after cleanup.
- Preserve unexpected I/O and cleanup errors in visible session status; distinguish
  expected PTY closure from failures rather than silently discarding errors.

The existing release-mode timing probe is a starting point:

```sh
cargo test --release --locked --test hotpath_probe -- --ignored --nocapture
```

It measures headless feed, full snapshot serialization, and unchanged polls; its
feed result includes JSON request overhead. It does not measure end-to-end UI
latency, GPU behavior, idle power, or long-running stability.

Acceptance: compare the same workloads before/after, preserve full/partial snapshot
equivalence and protocol behavior, and pass `scripts/verify.sh` plus app smoke
checks. Performance claims need measurements; stability claims need stress-test
evidence. The owned engine provides independent maintenance; integration improvements still require their own tests.

### Known wide-cell and grapheme limitations

Found by an external review pass and reproduced against the shared engine. Three were fixed and are
covered by tests. `wrap_padding` was asserted over a last column that held visible text, so selection
trimmed a character the user could see — either because a wide glyph wrapped over a column the cursor
was parked on, or because text was written or shifted into the padding column afterwards.
`Row::trailing_padding()` is now the single answer to "is the last column blank padding", and
selection, reflow and the WASM export that browser copy reads all ask it instead of reading the raw
flag, so the three cannot disagree about a row. A wide glyph also only marks an unwritten last column
as padding in the first place. A grapheme that widens in insert mode now shifts following cells,
including when it wraps onto a populated row. A runtime change of the preferred languages now
invalidates both font caches on the same frame: `GlyphFonts.cascadeKey()` summarises the resolved CJK
cascade order, and both `GridRasterizer.Layout` and `TextComposer.Layout` key on it, so neither path
can keep stale masks while the other rebuilds and switch a codepoint between regional Han shapes.

One limitation remains that is inherent to the grid rather than a defect:

- **A resize to exactly one column permanently narrows a wide glyph.** At 4x4 print `A界B`, resize to
  1x4 and back to 4x4: `界` returns one column wide and `B` lands in column 3. Measured round trips
  through two and three columns restore the pair exactly, so this is specific to `cols == 1`, where a
  two-column cell cannot be represented at all — reflow clamps with `width.min(cols)` and stores the
  result, and the grid invariant forbids a width-2 cell in a one-column row. Recovering the intrinsic
  width from the base character would be wrong for emoji and ZWJ clusters, whose stored width comes
  from cluster analysis rather than `ch.width()`. Left as-is: a real fix needs per-cell width history,
  and the only trigger is a one-column terminal.

One gap of the same shape as the language-desync fix is still open, and is deliberately not closed
here:

- **Font installation changes are invisible to both layouts.** `GlyphFonts.cascadeFont` drops a
  preferred face that `GlyphFonts.installed` reports missing and prepends the user's CJK font only when
  it is installed, but neither result is part of either `Layout`, and `cjkFontName` is the *requested*
  name, which does not change when Font Book enables or disables that face. So enabling or disabling a
  font at runtime, followed by a theme change or an image appearing (which builds fresh layer passes),
  can still refresh one path's faces and not the other's. Cosmetic, and it needs a rarer trigger than a
  language change. The correct fix is a generation counter bumped on
  `kCTFontManagerRegisteredFontsChangedNotification`, carried in both layouts — but it must live outside
  `GlyphFonts`, which is documented as pure helpers with no observable state, and be owned where the
  notification can be observed safely (the view, passed into both render calls). Adding a notification
  observer and a lock to a pure helper type to close a cosmetic gap is the wrong trade.

Two defects found by external review of the colour atlas page are now **fixed**, and one is still open:

- **A frame could be handed to the presenter after its textures were released.** `releaseRetainedFrames()`
  calls `presenter?.releaseTextures()` on the main thread but dispatches `TextComposer.releaseFrames()`
  to the raster queue, so a frame composed before a hide could reach its main-thread handoff after the
  pane was visible again. A partial frame then failed the `Metal text frame is not a full repaint` guard
  and `renderFailed` disabled Metal for that pane for good; a full warm-cache frame instead drew from
  freshly allocated blank atlases. The handoff now compares a `releaseGeneration` captured when the
  raster work was dispatched and simply drops the frame and redraws on a mismatch — deliberately not via
  `renderFailed`, which is permanent. The bitmap and layered handoffs take the same guard: they would not
  fail, since `upload(into:)` falls back to a complete upload whenever the texture is nil, but they would
  upload a whole window of pixels that is about to be replaced anyway.
  `LifecycleStressTests.testAFrameComposedBeforeAHideIsDroppedInsteadOfDisablingMetal` reproduces the
  race deterministically by hiding and un-hiding inside `.rasterReady`, which fires on the main thread
  inside the handoff after the compose and before the publish. A negative control with the guard removed
  fails with `Metal text frame is not a full repaint` and `usesSoftware == true`.
- **Atlas pages were reallocated on every reset instead of being pooled.** `TextComposer.Layout` carries
  width, height, cols and rows, so every frame of a live drag-resize is a layout change and therefore an
  atlas reset: 4 MiB per frame before the colour page, 20 MiB after it. A reset reuses atlas coordinates,
  so a page cannot be rewritten while an in-flight frame samples it — but it can be reused once
  `pending.completed` passes it, which is the same gate the window-bitmap pool already used. `retireAtlas`
  and `takeAtlas` now do that for both pages, bounded at four entries and emptied by `releaseTextures()`.
  Both pages are taken *before* either is retired, because with two frames in flight and emoji on screen
  the pool reaches its cap, and retiring first would evict exactly the pages that had just become reusable
  — collapsing reuse to zero. Completed pages are pruned once all takes for a frame are done, so a burst's
  pages are not kept alive after it ends, and a colour page is not retained after its last tile has gone.
  With the GPU idle a steady resize allocates nothing at all.
  `testAtlasPagesAreReusedOnlyOnceNoFrameCanSampleThem` checks the allocation counter across idle,
  in-flight, completed and released states and compares both paths against the CPU rasterizer;
  `testAtlasReuseSurvivesTwoFramesInFlightAndPrunesWhenIdle` covers the cap-ordering and pruning cases.
- **`TextComposer.compose(deferPublication:)` still defaults to `false`,** which acknowledges publication
  inside `compose` and clears the pending uploads of a frame the caller may still drop. Production always
  passes `true`; only test helpers take the default. With a dropped frame the atlas keeps entries whose
  bytes were never uploaded, so a later warm frame vends UVs into empty texels — invisible glyphs rather
  than a loud failure. Left alone deliberately: flipping the default changes the semantics of 47 test
  call sites, so it belongs in a change that is about that API rather than in a resource fix.

An external review also proposed relaxing the rasterizer's conservative scroll rule, which repaints
every row containing non-ASCII text instead of reusing the retained bitmap. Removing the rule fails
pixel equivalence at 2x and 3x, so italic and stroked decorations genuinely do round differently per
row. A narrowed variant that keeps those dirty did pass an extended font, size and scale matrix, but
it was not adopted: since wide CJK moved to the Metal atlas, only mixed-emoji, decorated and
post-suspension frames still reach this path, and bitmap scroll still pays a full-window move and
texture upload per frame. `GridRasterizer` is the pixel-exact reference for the whole renderer test
stack, so it is not worth trading that for a shrinking fallback. An earlier, more ambitious version of
the same idea was measured and rejected; see "Rejected Unicode scroll experiment" above.

## 2. Shell integration (implemented in 1.1.0; qualification continues)

Version 1.1.0 provides local bash/zsh hooks and bounded command history/output; the app enables
them by default for bash and zsh from 1.2.0.
See [host workflows](AGENT_WORKFLOWS.md) for startup, limits and trust boundaries.
Continue qualifying native-app awareness of prompt and command boundaries, working-directory
changes, and command completion/exit status through shell notifications. Define
the initial supported shells and notification protocol during implementation;
support for every shell is not implied.

Acceptance criteria:

- Document explicit enable/disable behavior and installation for supported shells.
- Validate bounded notifications and handle partial, malformed, repeated, or
  unexpected sequences without corrupting terminal output or session state.
- Test prompt/command transitions, failed commands, directory changes, multiline
  input, and startup files. Ordinary interactive shells work without integration.
- Treat shell-reported data as untrusted metadata. Integration does not grant
  terminal output permission to execute host commands or bundled JavaScript.
- Document any ABI additions and preserve schema-1 compatibility. AkiTTY Web's
  host must explicitly adopt any integration; native support does not add it to
  the separate web package automatically.

### Bash version qualification (2026-10-31)

macOS ships bash 3.2, which runs only the first `PROMPT_COMMAND` element, so macOS CI
alone could not catch prompt-array defects. A report from Linux bash 5.2 showed a
second `PROMPT_COMMAND` array hook recorded as the user's command (`printf HOOK_B`
instead of `echo REAL_COMMAND`). `scripts/test_shell_integration.py` was then run
against bash built from GPG-verified GNU sources (`AKITTY_TEST_BASH=/path/to/bash`;
`AKITTY_TEST_ZSH` selects zsh):

| Bash | Before the fixes | After | Subshell-only lines |
| --- | --- | --- | --- |
| 3.2.57 (macOS) | pass | pass | recorded (functrace) |
| 4.3.30 | not run | pass | recorded (functrace; checked on 4.3.0) |
| 4.4.18 | not run | pass | recorded |
| 5.1.16 | 2 failures | pass | recorded |
| 5.2.37 | 2 failures (the reported defect) | pass | recorded |
| 5.3 | 2 failures | pass | recorded |

Fixed: whole-array `PROMPT_COMMAND` assignment; hooks added after startup are adopted
instead of recorded; each hook sees the command's exit status as bash 5.1+ gives it;
subshell-only lines are recorded through `PS0` on bash 4.4+. A subshell line was also
checked through a real PTY on bash 5.2: command, start, its output, then exit status 3.
CI now runs the tests with bash 5.1 and 5.2 (Ubuntu 22.04/24.04) and Homebrew bash 5.3
on macOS, in addition to the system bash 3.2.

Bash 3.2–4.3 later gained subshell-only lines through functrace (`set -T`): the subshell
inherits the DEBUG trap and reports the line before its first command, so the record
keeps its output and duration (a record made after the fact would have neither), and
the core collapses a repeated start of the same command before a prompt. Qualified with
macOS bash 3.2.57 and unpatched GNU 4.3.0 and 5.2.0 builds, plus a real PTY through the
core on bash 3.2 (`actual_shells_record_subshell_only_lines_once_with_output_and_status`).

A line that reached history without running a command in the shell (a comment, a
function definition, or a subshell on these versions) used to leave an end mark with no
start; the prompt now restates such a line and the core folds the restart, so it is
recorded like any other.

The zsh ZDOTDIR wrapper was re-qualified on Linux (Ubuntu 26.04.1, zsh 5.9, bash
5.3.9) on 2026-10-31. The v1.2.2 wrapper reproduced the reported failure there: the
`compinit` in `/etc/zsh/zshrc` wrote `.zcompdump` into the shell-integration directory,
which in the app is the signed bundle. The single `.zshenv` that restores the user's
ZDOTDIR before the system files run passes all 12 shell tests on that box and leaves
the directory untouched; macOS zsh 5.9 and bash 3.2 pass as well.

Remaining: on bash 3.2–4.3 functrace makes functions inherit RETURN traps; the
bash-preexec path keeps its own limits; bash 4.3/4.4 are qualified locally, not in CI.

## 3. Quick terminal (implemented in 1.1.0; qualification continues)

Version 1.1.0 provides a persistent window and three selectable global shortcuts.
Continue qualifying a configurable global shortcut that shows/hides a persistent native terminal.
Hiding the terminal keeps the shell session alive. Closing it or quitting the app
continues to follow live-process confirmation and bounded shutdown rules.

Acceptance criteria:

- Define shortcut registration, conflict reporting, and enable/disable behavior.
- Define placement on multiple displays and behavior across Spaces/full-screen
  apps; document supported behavior and limitations.
- Show and focus the terminal predictably, and restore prior application focus
  when hidden where macOS permits it.
- Preserve the session across repeated toggles, sleep/wake, and display changes.
- Keep IME, paste policy, rendering fallback, and ordinary terminal windows working.
- Test failure paths and lifecycle cleanup; no orphaned shortcut registrations,
  timers, display links, or child processes.

## 4. Existing Agent Overview and accessibility (P1)

Agent Overview already lists panes across windows, tabs, splits and the hidden quick
terminal. Terminal text, selection, UTF-16 character counts, range reads and cursor
line are already exposed through AppKit accessibility APIs. Improve and validate
these foundations rather than scheduling them as new features.

The current app preserves Overview cell objects during status updates, clears
selection when a pane disappears, establishes keyboard focus and labels each cell's
source. The approval sheet exposes the exact command and shell-reported directory,
with Deny as the default. Terminal accessibility includes line and index queries,
coalesced text-change notifications and concise state-transition announcements.

Acceptance: regression tests for multiple windows/splits/hidden quick terminals,
stable selection and accessible cells, stale-pane action disabling, Unicode line
navigation, approval context/default and bounded notification behavior. Exercise
keyboard and VoiceOver operation in the native app, including denial, reclaim,
settings, selection and sustained output. Record each result and remaining limitation.
**VoiceOver user validation is not complete.** See [accessibility](ACCESSIBILITY.md).

Complete terminal navigation, range geometry, cursor tracking through scrollback,
remote/multiplexer behavior and user validation continue in P1–P2. Sixel stays
unsupported and is P3, subject to demonstrated compatibility demand. Performance,
stability and trusted-host execution control remain P0.

## 5. Agent-native integration (introduced in 1.3.0)

The first native integration implements bounded OSC 7501 revision 0.4 reports
alongside OSC 771, a request-only local companion with mandatory human approval,
source-labeled Overview state, and bounded local timeline/export. See
[the implementation contract](AGENT_NATIVE.md) for scope and usage.

Acceptance requires parser/lifecycle/ABI tests; no authority from program reports;
denial/disconnect/timeout/reclaim regressions; a real PTY command with an observed
filesystem effect; bounded private recording with loss markers; and the canonical
verification gate plus a built-app smoke. Published binaries are separate evidence.

Version 2.0.0 adds per-pane approval queues, request IDs and request status,
Claude Code and Codex hooks for supported Bash permission prompts, and AX Code
setup through Settings → Agents. Settings now also configures MCP and lifecycle
reporting for Grok, Muse Code, Kimi Code and AGY, with per-client conversation
resume commands. The [local MCP approval bridge](MCP.md) exposes `list_panes`,
`request_command` and `request_status`; pane listing also identifies the caller's
pane when known and reports untrusted readiness and directory observations.
Output reading, UTCP, optional policy and evidence adapters, cloud execution,
remote multiplexing, and result attestation remain follow-up areas.

## 6. Workspace usability

Regular native windows support tab transfer along the entire title bar. Drop
past the last tab to append, or drag above or below the strip to detach.
The existing panes and PTYs move together, and both windows restore the
remembered focus of their selected tabs. Escape and app deactivation cancel
the drag. Quick terminals and windows with dialogs or pending termination
block transfers. [Tab transfer regressions](../macos/Tests/AkittyKitTests/TabTransferTests.swift)

Find in All Terminals (⌥⌘F) searches retained output in the current window or every open
terminal. Results are grouped by window, tab and pane, bounded to 100 hits, and choosing one
reveals that pane. A closed pane or a row that has left scrollback is reported and does not
move focus. [Issue 51](https://github.com/defai-digital/akitty/issues/51)

The Dock menu offers window, tab, Quick Terminal, and Agent Overview actions. Finder can open supported
executables with confirmation after the user selects AkiTTY as their file handler.
Pane actions follow the find field's target while it holds focus. The native command
palette ranks command names and keywords in Rust. [File and Dock behavior](ARCHITECTURE.md#macos-folder-opening) ·
[Command palette contract](ABI.md#command-palette)

Version 2.0.0 also ships opt-in workspace reopening with fresh shells and
per-pane conversation resume for Claude Code, Codex and AX Code. Grok, Muse Code,
Kimi Code and AGY use the same human-started restore flow through their own
resume commands.
[Workspace restore and resume](AGENT_NATIVE.md#reopen-windows-and-resume-agent-conversations)

### Feature candidates

1. Attention navigation in the existing Agent Overview: unread state, filters and jump to the next waiting pane.
2. Command navigation and output inspection using the existing bounded shell observations. Agent output-read
   access would require its own explicit permission and retention contract.
3. Further workspace recovery for corrupt layout data. Live-process continuation
   requires a separate persistent PTY design.
4. Project/worktree launch presets that open a task's tabs, folder and profile together.
5. Diff preview and selected review-feedback handoff to an agent.

## Outside the current roadmap

- Native Linux or Windows desktop apps (the 1.3.5 experiments are discontinued;
  AkiTTY Web covers those platforms).
- Ghostty configuration compatibility or importing Ghostty's native Zig core/renderer.
- Third-party plugins, arbitrary script loading, or a public extension ecosystem.
- Full external esctest qualification. The curated conformance suite remains a
  required gate; passing it does not establish complete xterm/esctest conformance.

Sixel, image clipboard protocols, and custom shaders remain unsupported and are
not added to this plan. Signing, notarization, and publication continue to follow
[the release procedure](RELEASING.md); this plan does not change those gates or
promise a release date/version for planned features.
