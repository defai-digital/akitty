# Unreleased

- Encode Backtab with extra modifiers (Ctrl+Shift+Tab, Alt+Shift+Tab) as modified
  Backtab instead of a bare Tab that applications cannot tell apart.
- Treat an explicit zero in the Kitty keyboard stack pop (`CSI < 0 u`) as popping
  nothing, as the protocol specifies.
- Stop polling Kitty graphics animations at the display rate once a one-shot
  animation parks on its final frame.
- Act on the pane the find bar belongs to while it holds the focus: Close Pane,
  font commands and Restart, and the profile and directory a new tab or split
  inherits no longer fall to the leftmost pane.
- Keep `akitty-agent list` answering when many panes report long working
  directories: pane entries are bounded by their JSON-encoded size, so a full
  page always fits the local 16 KiB frame instead of failing with a frame error.
