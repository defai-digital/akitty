# Unreleased

- A tab shows the title of its focused pane only, so programs in the other
  panes of a split tab no longer take turns renaming it. Spinner frames at the
  start or end of a title are dropped, and a title that changes many times a
  second updates the tab at most twice a second, ending on the latest.
- Returning to a tab focuses the pane that was focused when you left it,
  instead of its first pane.
- Dropping a tab on another window's title bar past its tabs adds the tab
  there instead of returning it to the window it came from.
- The empty title bar of a background window moves the window on the first
  click and drag, as a standard title bar does.
- Moving a split tab between windows keeps its last focused pane. The tab
  revealed in the source window also returns focus to its last focused pane.
