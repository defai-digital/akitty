# Unreleased changes

Changes after AkiTTY 1.3.10; these are not yet part of a published release.

- Keep zsh history hooks visible to native registration. Removing, re-registering or replacing hooks no longer leaves stale or duplicate callbacks.
- Preserve autoloaded history hooks and their persistence decisions. A missing hook suppresses folder persistence until it can be observed safely; handled nested failures do not reject otherwise accepted commands.
- Preserve wrapped selection text, significant spaces and wide glyphs. Web selections follow retained rows and clear when those rows are evicted or the terminal is resized.
- Preserve native live/saved cursor positions and scrolled views through resizing.
- Correct functional-key repeat/release events, alternate-key reporting, keypad identities, legacy mouse-release modifiers and horizontal/stationary wheel handling.
- Keep native Command-V and Command-C as clipboard actions when foreground programs enable the Kitty keyboard protocol. Route Edit menu clipboard actions through the focused responder.
- Document folder-history navigation, settings, storage limits and hook behavior in the README and architecture guide.
- Add a persistent Don't ask again checkbox to the paste confirmation dialog and a Settings toggle to restore confirmation. Keep cancellation from changing the preference and avoid stacking paste dialogs.
- Publish a compatibility matrix, release-mode Native/WASM benchmark with raw percentile samples and state-equivalence checks, and a companion-driven approval/denial demo with a separately observed file effect.

History regression coverage uses isolated interactive zsh terminals, including native history-file checks for memory-only entries. The engine migration guide records the selection, resize and input-protocol audit.
