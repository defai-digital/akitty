# Compatibility and qualification

This matrix describes the current source tree, not a six-product ranking or certification.
The canonical [verification gate](../scripts/verify.sh) runs the required automated suites.
Refer to a release tag and its successful CI run when assessing a published binary.

| Capability | Evidence | Qualification boundary |
| --- | --- | --- |
| ANSI/VT screen state, margins, cursor save/restore, alternate screen and query replies | [Shared Native/WASM streams](../crates/akitty-vt/tests/fixtures/streams.json), [native contracts](../crates/akitty-vt/tests/contracts.rs), [WASM checks](../scripts/test-vt-wasm.ts) | Curated fixtures at every byte split; deterministic edit/resize stress. Full external esctest qualification remains outstanding. |
| Selection, soft wraps, wide cells and retained-row identity | Native screen/terminal tests, [Web selection tests](../packages/akitty-web/lib/selection-manager.test.ts), [real-browser canvas tests](../packages/akitty-web/browser/terminal.spec.ts) | Exercised behaviors have regressions; every font and host clipboard is not qualified. |
| Clipboard shortcuts and multiline paste | [Actual-PTY native paste tests](../macos/Tests/AkittyKitTests/PasteTests.swift), Web terminal/input tests | Native Command-V has priority over enhanced key encoding. Confirmation defaults on; Don't ask again persists only after Paste and can be restored in Settings. Existing dialogs block additional terminal pastes. |
| CJK, combining marks and emoji | Native cell/grid and shared stream fixtures; browser glyph pixels | Native rendering and Web have distinct grapheme support profiles. Native mode 2027 is not advertised; the direct VT benchmark explicitly enables the same grapheme profile in both engines. |
| Physical IME and VoiceOver | Composition and accessibility API regressions; [manual qualification](ACCESSIBILITY.md) | Unit tests do not establish physical input-method or VoiceOver user validation. |
| Local bash/zsh prompt history | [Isolated interactive shell tests](../scripts/test_shell_integration.py), [workflow contract](AGENT_WORKFLOWS.md) | Qualified shell versions and remaining limitations are in [the roadmap](ROADMAP.md#bash-version-qualification-2026-10-31). Vendor prompt frameworks need separate qualification. |
| Kitty keyboard and mouse protocols | Shared key encoder, Swift/Web input tests and browser keyboard events | Host shortcuts and IME policy remain host-specific; base-layout alternate keys use the documented supported layouts. |
| Kitty graphics | Native conformance/graphics tests and [optional external clients](../crates/akitty-core/tests/real_tools.rs) | Bounded implementation with explicit limits. Missing optional clients are skipped and do not establish compatibility. |
| Vim, Neovim, tmux and SSH workflows | Protocol fixtures cover constituent behaviors | No complete application/version/platform qualification matrix is claimed. Record actual versions and observed workflows before marking these qualified. |
| Local command request, approval, denial and reclaim | [Native request tests](../macos/Tests/AkittyKitTests/AgentRequestTests.swift), [reproducible demo](AGENT_DEMO.md) | The receipt establishes queued input. Shell/program reports are untrusted; the demo checks one separate expected file effect. Ordinary agent subprocesses are outside this path. |
| Program identity/status and event timeline | OSC 7501/771 and local recorder tests; [native contract](AGENT_NATIVE.md) | Program labels are self-reported. Retained event metadata is bounded, locally editable and incomplete. |
| Session continuity | Quick-terminal toggle and lifecycle tests; [window-layout tests](../macos/Tests/AkittyKitTests/WindowLayoutTests.swift) | Hiding the quick terminal retains its live PTY. Named layouts save windows, tabs, splits and each pane's starting folder. An unchecked Include recent scrollback option stores up to 200 lines / 16 KiB of plain text per pane (128 KiB per layout) locally; Remove Stored Scrollback removes that text while keeping the layout. Restored text is searchable and copyable above a fresh shell, separated by markers. Processes are new. App-restart restoration, remote reattachment and a persistent PTY server remain unimplemented. |
| Parser/grid/reflow performance | [Native/WASM benchmark](../benchmarks/README.md) with raw samples and state equivalence | Excludes PTY, font rendering, key-to-paint latency, idle power and long-term memory behavior. No competitor ranking is inferred. |

## Recording an external qualification

Record the AkiTTY commit/artifact, OS, application versions, terminal dimensions, font, shell/configuration,
exact input bytes, expected output and observed result. Include failed or skipped cases and a reproducer.
Separate automatic app-restart restoration, live-process continuation, and remote disconnect/reattach checks from optional saved plain-text history.
Named layout restore is covered; whether a saved pane's shell can still run its original program is not.
An engine ownership decision is architectural context; quality and performance need their own observations.
