# Unreleased changes

Changes after AkiTTY 1.3.15; these are not yet part of a published release.

## SDK 0.3.0

- `@ax-code/akitty-sdk` validates input with [Zod](https://zod.dev) 4.6.7, its one runtime dependency, pinned exactly.
- New exports: `StatusSchema`, `MarkSchema`, `ProgressSchema`, `SpriteSchema`, `ChromeSchema` and `ChromePatchSchema` from the main entry; `ShellStateSchema` and `DispatchReceiptSchema` from `/host`.
- Invalid input still throws `RangeError` with the same messages; the Zod error is its `cause`. An object with an inherited enumerable property is now rejected as `unknown field`.
