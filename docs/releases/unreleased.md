# Unreleased changes

Changes after AkiTTY 1.3.18; these are not yet part of a published release.

## Terminal

- Fixed an unresponsive pane after typing `exit` when the previous command failed. Shell exits now close their pane for any reported exit status; engine and PTY errors remain visible for restart.
