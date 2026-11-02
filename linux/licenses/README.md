# Missing crate notice files

These unmodified notices fill omissions in the exact crates.io archives listed
in `manifest.json`. The generator accepts only those package versions and file
hashes. Upstream commit IDs come from each archive's `.cargo_vcs_info.json`.

`selectors` declares MPL-2.0 in its package metadata and source headers but ships
no license text; the copy here is Mozilla's canonical MPL 2.0 text. Its source is
unmodified and the generated notice includes the exact source archive URL.

The libappindicator bindings offer Apache-2.0 OR MIT; the generated notice uses
the MIT option and retains the upstream Apache notice here as well.

The Windows WebView2 binding crates also omit their MIT text from crates.io
archives. Their notices are pinned to each archive's source commit and included
by the Windows lockfile audit.
