# Independent terminal engine migration

Replace the Alacritty and VTE derived native engine and the Ghostty WebAssembly
engine with an AkiTTY implementation shared by the native and browser terminals.
Preserve the shipped terminal, graphics, agent, accessibility and host-policy
contracts. Renaming or moving inherited source does not satisfy this migration.

## Completion requirements

- Production native and Web builds use the independently implemented Rust VT core.
- No Alacritty, VTE, Ghostty or ghostty-web implementation is compiled or bundled.
- Native C ABI v1 and ordinary Web Terminal API behavior remain supported. Removal
  of engine-specific Web exports is documented as a package compatibility change.
- Keyboard, mouse, UTF-8, control sequences, alternate screens, bounded history,
  resize/reflow, search/selection, replies and synchronized updates are qualified.
- Kitty graphics and agent status continue working without changes to command
  approval authority, clipboard policy or process cleanup guarantees.
- Native and WASM run shared behavioral fixtures. Existing regression suites,
  browser checks, Swift tests, ABI checks and release checks pass.
- Production dependency graphs and packaged artifacts are checked for old engines.
- Retained code, tests and assets have a reviewed provenance record. Required
  historical copyright and license notices are not removed merely to hide origin.
- Documentation describes the actual final implementation, and changes are committed.

## Architecture

`akitty-vt` owns a bounded streaming parser, terminal screens/history, cell styles,
mode state, content mutation events, selection primitives and keyboard encoding.
It has no PTY, UI, filesystem, wall-clock or command-approval dependency. Time is
supplied by the host. Native and WASM bindings adapt this same implementation.
Native AppKit/CoreText/Metal and browser DOM/Canvas remain platform frontends.

The host owns process lifecycle, file and shared-memory graphics transport,
clipboard permissions, IME, timer scheduling and command authorization. Program
output remains untrusted and cannot grant input ownership.

Protocol behavior is specified from ECMA-48, xterm control-sequence documentation
and public extension specifications. Existing engines are temporary differential
test oracles; differences are reviewed against protocol and product contracts.
New implementation is authored independently rather than translated from them.

## Milestones

1. **Independent foundation:** add the parser, cells and screen/history model;
   verify arbitrary byte segmentation, invalid input and bounded resources.
2. **Terminal semantics:** implement modes, edits, scrolling, resize/reflow,
   queries/replies, Unicode, selection and synchronized output. Establish a native
   and WASM vertical slice before expanding platform integration.
3. **Native integration:** replace concrete engine types in model/session; replace
   mirrored graphics tracking with actual content mutation events. Preserve ABI v1
   and snapshot delivery/commit semantics.
4. **Web integration:** build owned WASM, replace loader/types/key encoder and
   remove inherited frontend implementations while preserving ordinary public API.
5. **Qualification and removal:** run shared fixtures and all platform gates,
   review performance and provenance, remove obsolete engine packages/builds and
   update dependency/artifact verification and documentation.
6. **Commit:** audit every completion requirement against the current tree and
   test output, then commit the completed migration.

## Validation baseline

Before implementation, `cargo test --workspace --locked` passed (some explicit
external-tool and benchmark tests are ignored). Web type checking passed and
Vitest reported 620 passing tests and 2 skipped tests. Happy DOM emitted localhost
connection-refused diagnostics despite the successful test exit. Full native UI,
real-browser and release verification still must run during qualification.

## Current progress

- [x] Review native/Web dependency boundaries and preserve preexisting worktree state.
- [x] Record migration scope, architecture, completion requirements and baseline.
- [x] Independent parser and screen foundation.
- [x] Native/WASM terminal semantics and shared protocol qualification.
- [x] Native integration and graphics mutation tracking (142 unit tests, 49 conformance tests and lifecycle stress pass).
- [x] Independent Web frontend integration.
- [x] Full verification, provenance review and dependency removal.
- [x] Completion audit; this migration is committed with its implementation and qualification record.

The untracked `reference/` corpus predates the migration and is reference-only.
It must not be added to the commit or deleted during cleanup.

## Final implementation and qualification

The owned Rust engine and reauthored Web frontend replace the previous production
implementations. Alacritty/VTE source trees, their recordings, the mirrored graphics
tracker, Ghostty WASM, the upstream build patch and old engine bindings are removed.
Native ABI v1 remains supported. The 219 Rust tests also passed with the standard
library rebuilt for deployment target macOS 14 (on the current macOS host). Web is version 0.6.0; engine-specific API changes,
the total cell limit and Unicode profiles are documented in the package README.

The final required `scripts/verify.sh` run completed successfully on Apple Silicon
macOS on 2026-11-04:

| Gate | Result |
| --- | --- |
| Workspace build and native/WASM Clippy with warnings denied | Passed |
| Rust tests | 219 passed; 9 explicit optional benchmark/external-tool cases ignored |
| Shared native/WASM streams | 13 fixtures, every byte split, both committed and freshly built WASM |
| WASM artifact | No imports; owned ABI exports; source/artifact hashes and private-path audit passed |
| Feature/distribution Node tests | 18 passed |
| SDK | 28 passed; 2 native cases skipped in the portable run, then both passed through the real C ABI/PTY |
| Web type checking and Vitest | 620 passed, 2 opt-in probes skipped |
| Chromium/WebKit | 10 passed, including actual pixels, input, repeated lifecycle, hidden sync expiry and SGR mouse |
| Swift | 258 executed, 1 skipped, zero failures |
| C ABI and header identity | Passed |
| Shell integration | 21 executed, 1 inapplicable shell-capability branch skipped |
| Publication audit, release preparation/publication unit tests and installer tests | Passed; no real release published |
| App packaging | Debug build passed, ad-hoc signature and macOS 14 deployment baseline checked |

Firefox's Playwright binary cannot start on this machine (the existing exact
"Could not find profile folder" failure). The existing local-only exception is
reported; CI still requires Firefox. Windows/Linux browser CI, physical IME,
all fonts, macOS 14 runtime testing and multi-day reliability are not established
by this local run. None is claimed as a new capability of the engine migration.

App packaging rebuilds matching Rust standard-library sources at deployment
target macOS 14 when a distribution compiler is used. This avoids shipping
Homebrew's newer deployment baseline. Normal rustup builds use the pinned
compiler and its standard library. Ordinary dependency versions were preserved;
only now-unreachable engine dependencies were removed and the owned engine's
Unicode segmentation library was added.

## Performance observations

Explicit release-mode native probe on this machine: colored input including JSON
request wrapping 52.8 MiB/s; full 200x50 snapshot 0.42 ms; idle poll 0.5 microseconds.
The explicit Web probe measured 50-row reads at 3.751 ms with forced repeated
viewport decoding and 0.117 ms with pooling; one dirty row 0.072 ms; a 66 KB write
1.985 ms. These compare paths within the new implementation, not old engines.
They are local observations rather than upstream speedup or UI latency claims.

Viewport cells, WASM transfer buffers and evicted screen rows are reused. ASCII
text avoids grapheme-string allocation. Graphics follows actual mutation events
rather than a duplicate parser. Host theme colors survive terminal palette reset,
and cursor color no longer changes the text foreground. DECRQSS reports active
styles, and reverse-video mode participates in Web cell decoding and row damage. The host expires synchronized output even while the browser is hidden.

The full verification and performance logs are task-owned ignored files under
`build/migration-*.log`; browser screenshots were inspected. `reference/` remains
untracked and untouched. Root historical notices and retained Coder-derived tests
are explicitly distinguished from current production authorship in the provenance
ledgers. No memory, private reference corpus or generated build directory is committed.

## Post-migration bug audit

All local branches and worktrees were inspected before publication. Only `main`
and its primary worktree remained; the six pending commits were already on it.
No merge or branch deletion was needed. Cleanup removed 523 obsolete Alacritty/VTE
build artifacts and preserved the untracked reference corpus.

The follow-up audit corrected runtime theme updates that left WASM colors and
cached rows unchanged; Ctrl+Alt chords confused with AltGraph text; enhanced
keyboard reports that substituted physical Latin identities for Unicode layout
text; cancelled browser dead-key composition; Ctrl-modified editing/keypad keys
that produced no bytes; alternate-screen wheel input that ignored mode 1007,
application cursor mode and delta units; and mouse releases retained after reset
or after tracking was disabled. Palette changes preserve text, history and OSC
overrides. Fractional alternate-wheel deltas accumulate rather than disappearing.

The new regression tests reproduce the failures and the required verification
passes with 220 Rust tests, 626 Web tests, 12 Chromium/WebKit tests and 258 Swift
tests executed with one skip and zero failures. Native/WASM shared fixtures,
WASM/native Clippy, SDK/ABI, shell, publication, release and installer checks also
pass. Firefox retains the reported local startup exception; CI still requires it.
Runtime-theme screenshots from both tested browsers were inspected. Physical
keyboard-layout and IME hardware coverage is not implied by synthetic event tests.

CI preparation also exposed a toolchain-selection gap: selecting the pinned
`rustc` did not select Cargo when rustup's default differed. Build scripts now set
`RUSTUP_TOOLCHAIN` for the process, preserving global defaults. Four isolated
shell-toolchain tests cover a differing default, the exact distribution fallback
and rejection of incorrect compiler/Cargo versions. They run in the required gate.


## Retained-buffer and cursor audit

A further audit reproduced inactive normal/alternate buffer objects reading the
active screen, cursor relocation to line end when resizing on a wide-cell trail,
and cumulative cursor opacity from repeated idle or unrelated-row painting. The
renderer also ignored the cursor color already reported by the core.

Read-only WASM buffer exports now select a screen explicitly without changing
modes, revisions or queued events. Native reflow preserves offsets within wide
cells. Cursor overlays are painted only after their row has been repainted;
unchanged frames skip both cursor blending and native damage-hash recomputation.
OSC cursor colors invalidate the cursor row and are drawn from core state.

Regression qualification includes inactive history/cursor/wrap/grapheme reads,
retained row snapshots, direct WASM bounds/lifetime/state tests, native/WASM wide
cursor reflow and real Canvas pixel stability/color/reset tests. The required
local gate passes with 221 Rust tests, 629 Web tests, 14 Chromium/WebKit tests and
258 Swift tests executed with one skip and zero failures. SDK/ABI, Clippy,
source/artifact provenance, shell, release and installer checks pass. Firefox
retains the previously documented local-only startup exception. No remote CI or
push is part of this audit.

## Character-shift, mode-list, keypad and URL audit

The next audit reproduced SS2/SS3 remaining active after one character, combined
DEC mode lists failing to start/finish synchronized output, printable keypad
input bypassing application/enhanced encoding, Unicode URL paths stopping at a
wide-cell spacer, and balanced URL/IPv6 delimiters being removed as punctuation.

Single shifts now preserve the locking GL selection and affect one character,
following the public xterm control-sequence specification:
https://invisible-island.net/xterm/ctlseqs/ctlseqs.html. Mode lists containing 2026
are processed in order through the existing synchronization state machine.
Keypad identities survive layout-text adaptation; normal numeric mode still
emits text. URL detection uses complete graphemes, skips wide-cell spacers and
maps the final glyph's full column extent. Delimiter trimming is linear and
keeps balanced parentheses/brackets while removing surrounding prose punctuation.

Local required verification passes with 223 Rust tests, 632 Web tests, 16
Chromium/WebKit tests, and 258 Swift tests executed with one skip and zero
failures. Sixteen shared native/WASM fixtures pass every byte boundary. Clippy,
SDK/ABI, source/artifact provenance, shell, release and installer checks pass.
The real-browser URL case uses the platform's primary link modifier and verifies
activation from the trailing half of a wide glyph. Firefox retains the documented
local startup exception; required remote CI runs before publication to main.

## Selection, resize and input-protocol audit

This audit reproduced selection copying soft wraps as hard newlines, losing
significant spaces and nonbreaking spaces, omitting a wide glyph when the range
started on its trailing column, and including padding before a wrapped wide glyph.
Oversized selections could also reverse their final column, and bounded history
eviction silently moved a selection onto replacement text.

Selection extraction now follows logical wrapped lines and their explicit padding,
retains selected written spaces, and includes overlapping wide glyphs in both text
and highlighting. Ranges clamp to the last viewport cell and clear on resize.
Additive WASM ABI 1 exports expose opaque 64-bit row identities, retained-anchor
lookup and wrap padding. Selection anchors resolve once per core revision, so
history eviction cannot silently select different rows. The native selection path
also preserves spaces across wraps and omits wide-wrap padding.

Native resize now relocates both live and saved cursors, including delayed wrap,
and preserves the scrolled viewport through height changes and logical-line reflow.
Rebuilding history no longer counts retained rows as new output. Cursor save and
restore retain charset designations and locking selection, as described in the
DEC VT100 User Guide (DECSC/DECRC). Zero bottom margins default to screen height;
invalid single-row scrolling regions are ignored.

Input regressions cover legacy mouse-release modifiers, the UTF-8 mouse coordinate
ceiling, and horizontal/stationary wheel events producing vertical reports. Keyboard
event-only mode now reports functional-key repeat/release events. Alternate-key
reporting does not force otherwise legacy Shift keys into CSI-u; F3 uses its
unambiguous enhanced encoding. Lock modifiers, editing-key releases and keypad
identities follow progressive flag semantics. The Web adapter carries shifted and
base-layout identities, reports standalone modifiers when all-key reporting is
enabled, and omits associated text for Ctrl/Super chords while retaining legacy
non-English Ctrl input. Protocol grounding:
https://invisible-island.net/xterm/ctlseqs/ctlseqs.html and
https://sw.kovidgoyal.net/kitty/keyboard-protocol/.

Regression qualification includes 20 native/WASM stream fixtures at every byte
boundary, 60,000 deterministic edit/resize/screen-switch operations checking both
screens, direct WASM anchor/bounds/lifetime and keyboard checks, and real Canvas
drag-selection pixels and keyboard press/repeat/release events. The complete local
verification gate passes with 233 Rust tests, 639 Web tests, 20 Chromium/WebKit
tests and 258 Swift tests executed with one skip and zero failures. Native/WASM
Clippy, SDK/ABI, source/artifact provenance, shell, release and installer checks
pass. Firefox retains the documented local startup exception. The final source
review and regression sweep found no additional reproducible defects in the paths
reviewed; this does not establish that the entire application is defect-free.

## 1.3.10 reconciliation and clipboard audit

The release reconciliation retains both branches' regression cases and the released
cursor-state structure, including saved autowrap and a pending single shift. The
shared native/WASM stream corpus now contains 27 fixtures.

The clipboard audit reproduced Command-V arriving at the native key handler as an
enhanced keyboard chord instead of pasted text. Clipboard shortcuts now run before
the foreground program's Kitty keyboard encoding; Edit menu actions use the focused
responder, while palette commands retain their explicit pane target. Actual-PTY
tests verify the exact Unicode payload and bracket delimiters, both shortcut paths,
and approval/cancellation of multiline pastes. The unfixed implementation fails the
new shortcut regression by delivering an 8-byte key sequence instead of the expected
24-byte bracketed payload.

The release-merge verification gate passes with 236 Rust tests, 639 Web tests,
20 browser tests, SDK/ABI, Clippy, source/artifact provenance, shell, release and
installer checks. The final native clipboard revision passes 263 Swift tests with
one skip and zero failures; the shell suite runs 26 tests with one skip and zero
failures. The debug app bundle builds and launches an isolated interactive zsh with
the bundled folder-history hooks. These checks do not establish comparative
performance, complete terminal conformance or vendor-certified agent integration.
