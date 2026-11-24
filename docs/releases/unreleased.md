# Unreleased

- A tab shows the title of its focused pane only, so programs in the other
  panes of a split tab no longer take turns renaming it. Spinner frames at the
  start or end of a title are dropped, and a title that changes many times a
  second updates the tab at most twice a second, ending on the latest.
- Returning to a tab focuses the pane that was focused when you left it,
  instead of its first pane.
