# Unreleased changes

Changes after AkiTTY 1.3.11; these are not yet part of a published release.

- Keep drag selection endpoints stable when auto-scroll reaches a scrollback boundary.

- Preserve the primary terminal failure when child cleanup is deferred. Cleanup failures still reach the caller and remain visible when there is no earlier terminal error.

- Show the five most recent distinct prefix matches on zsh Tab and Up/Down, from the current folder first and then all other folders, replacing frequency ranking. Commands typed in folders whose names contain tabs or newlines are now saved. Existing saved commands and settings remain compatible.
