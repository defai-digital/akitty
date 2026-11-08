# Unreleased changes

Changes after AkiTTY 1.3.10; these are not yet part of a published release.

- Require macOS 27.2 or later for the native Apple Silicon app and installer. Build and test Siri with stable Xcode/macOS 27.2. Keep seven default Siri and Shortcuts actions with foreground authentication and native command approval; remove the macOS 27.3 Siri AI tools, app skills, and preview build mode. Release manifests and Sparkle feeds use the packaged app's minimum OS version.
- Add a [Siri quick start](../../README.md#siri-and-shortcuts) and [setup and troubleshooting guide](../SIRI.md), including all seven English phrases, terminal reference lifetime, command approval, and the remaining spoken Siri and discovery qualification on macOS 27.2.
- Keep zsh history hooks visible to native registration. Removing, re-registering or replacing hooks no longer leaves stale or duplicate callbacks.
- Preserve autoloaded history hooks and their persistence decisions. A missing hook suppresses folder persistence until it can be observed safely; handled nested failures do not reject otherwise accepted commands.
- Keep history-hook bookkeeping in private variables so user hooks can read and update their own `result` and `saved` variables without changing privacy decisions.
- Preserve wrapped selection text, significant spaces and wide glyphs. Web selections follow retained rows and clear when those rows are evicted or the terminal is resized.
- Preserve native live/saved cursor positions and scrolled views through resizing.
- Correct functional-key repeat/release events, alternate-key reporting, keypad identities, legacy mouse-release modifiers and horizontal/stationary wheel handling.
- Keep native Command-V and Command-C as clipboard actions when foreground programs enable the Kitty keyboard protocol. Route Edit menu clipboard actions through the focused responder.
- Keep Web AltGraph text and Ctrl+Alt chords out of clipboard shortcut detection. Pair enhanced key releases with reported presses, preserving their key identities when layout modifiers are released first and excluding shortcuts or keys consumed by host handlers.
- Document folder-history navigation, settings, storage limits and hook behavior in the README and architecture guide.
- Add a persistent Don't ask again checkbox to the paste confirmation dialog and a Settings toggle to restore confirmation. Keep cancellation from changing the preference and avoid stacking paste dialogs.
- Publish a compatibility matrix, release-mode Native/WASM benchmark with raw percentile samples and state-equivalence checks, and a companion-driven approval/denial demo with a separately observed file effect.
- Preserve per-pane font zoom when saving paste or other unrelated preferences; explicit font-size changes and Reset Font still apply.
- Reject linked/non-regular Agent demo markers and avoid blocking on FIFOs while observing an effect.
- Reject sparse benchmark timings and abort report publication when measured inputs or the Git revision change during a run.
- Halve terminal grid and scrollback memory: each engine cell now occupies 40 bytes instead of 80 (packed colours, boxed combining marks, one shared hyperlink record per OSC 8 target), so the 64 MiB history cap retains twice as many rows and scroll, fill and snapshot hashing move half the bytes.
- Speed up the engine: printable ASCII runs bypass the parser state machine, grapheme joining reuses one scratch buffer, and entering the alternate screen or resetting blanks the retained screen in place instead of reallocating it.
- Resolve the selection range once per snapshot instead of once per cell, so dragging a selection over a long scrollback no longer stalls rendering. Feed PTY output to the engine in 1 KiB slices rather than 64-byte slices.
- Skip JSON decoding when an idle poll reports no change, and drop a background tab's window-sized bitmaps and Metal textures until it is shown again.

History regression coverage uses isolated interactive zsh terminals, including native history-file checks for memory-only entries. The engine migration guide records the selection, resize and input-protocol audit.
