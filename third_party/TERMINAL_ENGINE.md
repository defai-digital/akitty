# AkiTTY-maintained terminal engine

AkiTTY owns maintenance of the local `alacritty_terminal` and `vte` packages in
this directory. Their package names and original copyright notices preserve
attribution. They are derived from Alacritty terminal 0.26.0 and VTE 0.15.0;
they are not a claim that AkiTTY is the upstream Alacritty application.

Both are Cargo workspace members and resolve by local path. Building AkiTTY
never fetches these two packages from crates.io or a Git branch. Other ordinary
Rust dependencies remain external and locked in `Cargo.lock`.

Each `ORIGIN.json` records the original registry archive checksum and SHA-256
hashes of imported files before local edits. These are historical provenance,
not a requirement to keep our implementation byte-identical. Git history tracks
our changes. The initial local changes wire VTE by path and address Rust 1.99
Clippy compatibility; terminal integration fixes live in `akitty-core`.

Upstream is an optional source of ideas, fixes and regression cases. There is no
automatic synchronization. Review and adapt individual changes, preserve their
attribution, and run the local gates before accepting them. Local ownership lets
us fix problems independently; it does not remove inherited bugs or maintenance
responsibility. The C ABI remains the app boundary; engine types stay internal.

`cargo test --workspace --locked` includes the retained upstream unit and recorded
terminal tests. `scripts/check-engine-source.py` rejects external resolution or
duplicate copies. `scripts/verify.sh` includes these checks and workspace Clippy.
The release license collector includes both local packages. The Apache-2.0 and
VTE MIT license texts remain alongside the source.
