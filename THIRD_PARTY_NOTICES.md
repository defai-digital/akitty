# Third-party acknowledgments

Akitty's own code is MIT licensed. Dependencies are not relicensed by Akitty.

- **Ghostty** — https://github.com/ghostty-org/ghostty — MIT, copyright 2024
  Mitchell Hashimoto and Ghostty contributors. Akitty is a Rust/Swift revamp
  inspired by and developed with the Ghostty source as a reference, not a
  drop-in source translation. The original MIT notice is preserved in LICENSE.
- **Alacritty terminal engine 0.26.0** — https://github.com/alacritty/alacritty —
  Apache-2.0. See third_party/alacritty/LICENSE-APACHE. Its parser/grid is linked
  into the Rust library; no engine ABI is exposed by Akitty.
- **portable-pty 0.9.0 / WezTerm** — https://github.com/wezterm/wezterm — MIT.
- **AX TUI** — https://github.com/defai-digital/ax-tui — MIT, copyright 2025
  opentui and 2026 DEFAI Digital. Adapted fuzzy command ranking only; see
  third_party/ax-tui/NOTICE.md and LICENSE.

Cargo.lock and package-lock.json pin the complete dependency graphs. The
release build also includes THIRD_PARTY_LICENSES.txt, generated from the exact
locally resolved Cargo sources and their license/notice files. TypeScript and
esbuild are build tools, not runtime components of the Mac app.

- Sparkle 2.10.1: MIT and bundled third-party notices; see `third_party/sparkle/LICENSE`. The app embeds its framework and update helpers.
- **AkiTTY Web** (`packages/akitty-web`) — derived from coder/ghostty-web v0.4.0 (MIT, copyright 2025 Coder) and
  includes its prebuilt `ghostty-vt.wasm`, built from Ghostty (MIT). Licenses are in `packages/akitty-web/LICENSE` and
  `LICENSE-GHOSTTY`; provenance and local changes are in `packages/akitty-web/UPSTREAM.md`. Rebuilding the wasm needs
  Zig 0.15.2, which is not required to build or run Akitty itself.
