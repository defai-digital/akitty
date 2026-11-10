# Unreleased changes

Changes after AkiTTY 1.3.14; these are not yet part of a published release.

- Web: `onRender` now fires after each painted frame (idle frames stay silent); it previously never fired.
- Web: clearing a selection (API, typing, resize, reset) now fires `onSelectionChange`, so listeners no longer see a stale selection.
