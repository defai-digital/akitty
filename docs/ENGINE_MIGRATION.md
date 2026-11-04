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
