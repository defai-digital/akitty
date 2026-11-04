# Third-party acknowledgments

Akitty's own code is MIT licensed. Dependencies are not relicensed by Akitty.

The native and Web terminal engine is the independently authored **akitty-vt**
(MIT). No Ghostty, Alacritty or VTE implementation is linked or bundled. See
[engine ownership and provenance](third_party/TERMINAL_ENGINE.md).

- **Unicode data** — https://www.unicode.org — Unicode License V3. The Kitty
  placeholder alphabet is generated from Unicode 6.0.0 protocol data. Notice:
  `third_party/unicode/LICENSE`; bundled as `UNICODE_LICENSE` in the Mac app.
- **portable-pty 0.9.0 / WezTerm** — https://github.com/wezterm/wezterm — MIT.
- **AX TUI** — https://github.com/defai-digital/ax-tui — MIT, copyright 2025
  opentui and 2026 DEFAI Digital. Adapted fuzzy command ranking only; see
  third_party/ax-tui/NOTICE.md and LICENSE.

Cargo.lock and package-lock.json pin the complete dependency graphs. The
release build also includes THIRD_PARTY_LICENSES.txt, generated from the exact
locally resolved Cargo sources and their license/notice files. TypeScript and
esbuild are build tools, not runtime components of the Mac app.

- Sparkle 2.10.1: MIT and bundled third-party notices; see `third_party/sparkle/LICENSE`. The app embeds its framework and update helpers.
- **AkiTTY Web** (`packages/akitty-web`) — production terminal code was reauthored
  around the owned Rust engine. Historical regression tests and helpers originated
  from coder/ghostty-web v0.4.0 (MIT, copyright 2025 Coder); their MIT notice remains
  in `packages/akitty-web/LICENSE`. The previous Ghostty engine has been removed.
  `PROVENANCE.md` distinguishes current authorship from historical origins.
- **Historical acknowledgments:** Ghostty (Mitchell Hashimoto and contributors),
  Alacritty and VTE informed earlier versions. Historical MIT notices remain in
  root/package licenses and `packages/akitty-web/LICENSE-GHOSTTY`; they do not
  describe the current engine or imply an upstream affiliation.
