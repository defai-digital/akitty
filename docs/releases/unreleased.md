# Unreleased changes

Changes after AkiTTY 1.3.14; these are not yet part of a published release.

- Web: `onRender` now fires after each painted frame (idle frames stay silent); it previously never fired.
- Web: clearing a selection (API, typing, resize, reset) now fires `onSelectionChange`, so listeners no longer see a stale selection.
- Insert Line and Delete Line now return the cursor to the left margin, and character, line and display edits clear a pending wrap, matching xterm. A character printed after an edit at the last column no longer wraps to the next row.
- Turning reverse video (DECSCNM, `CSI ?5h`/`?5l`) on or off now repaints clients that request incremental snapshots, so visual bells show.
- An unterminated title or other forwarded OSC followed by a shell-integration OSC no longer hides all later output.
- Replacing an unnamed image by its auto-assigned id no longer releases its memory twice, which wrapped the session's image budget and corrupted the shared limit.
- Shrinking the terminal's row count keeps the cursor on its own line; rows below it that no longer fit are dropped instead of moving the cursor onto a different line.
- Ctrl+/ sends 0x1F and Ctrl+~ sends 0x1E in legacy key encoding, and modifyOtherKeys level 2 leaves Shift+printable text unencoded, as xterm does.
- macOS: Ctrl+Backspace sends ^H instead of ^_ (readline undo).
- macOS: wheel and trackpad scrolling in mouse-reporting programs and on the alternate screen sends one report per scrolled line instead of one per event.
- macOS: switching apps or windows now sends focus-out/in reports and releases held Kitty keys, so modifiers no longer get stuck after Cmd-Tab.
- macOS: dragging a tab no longer clears another tab's bell or finished mark or sends it focus events.
- macOS: paste errors no longer stay stuck in the status line, and minimized windows refresh at the hidden rate.
- macOS: Home and End follow application cursor mode, and Shift, Option and Control on Home, End, Page Up/Down, Insert, Delete and the function keys send xterm modifier sequences (for example `CSI 1;5H`, `CSI 5;2~`) instead of being dropped.
- macOS: a window ordered out after being shown (such as a hidden quick terminal) refreshes at the hidden rate.
- Agent-injected commands start with Ctrl-U, so text typed while the previous command ran can no longer be prepended to the injected command at the new prompt.
