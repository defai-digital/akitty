<p align="center"><img src="assets/icon-source.png" width="160" alt="AkiTTY cat terminal logo"></p>

# AkiTTY

A **macOS-only terminal app revamped from [Ghostty](https://github.com/ghostty-org/ghostty)**,
with a Rust terminal core, native Swift/AppKit interface, and a small TypeScript
feature layer. No Zig compiler or runtime is required. Windows and Linux are not
application targets.

## Quick start

Requires an **Apple Silicon Mac running macOS 14 or later**.

```sh
curl -fsSL https://download.automatosx.com/akitty/install -o install.sh
bash install.sh
open "$HOME/Applications/Akitty.app"
```

The installer downloads the latest release, verifies its checksum, code signature
and notarization, then installs it into `~/Applications`.

Click **+** or press **⌘T** for a new terminal tab. Open **Settings… (⌘,)** to
choose your font, shell and starting directory.

Updates appear as a quiet reminder in the title bar. Use **AkiTTY → Check for
Updates…** to check manually; you choose when to install and restart. Automatic
checks can be changed in Settings.

For a shared installation in `/Applications`, run the downloaded installer with
`bash install.sh --system` instead; that directory must be writable.

## Manual download

You can also [download the v0.9.0 ZIP](https://download.automatosx.com/akitty/releases/download/v0.9.0/AkiTTY-0.9.0-macOS-arm64.zip)
or visit the [GitHub release](https://github.com/defai-digital/akitty/releases/tag/v0.9.0).
Unzip it, move **Akitty.app** into **Applications**, and open it.

## Why AkiTTY exists

AkiTTY began with [AX Code Desktop](https://github.com/defai-digital/ax-code-desktop),
where we used [ghostty-web](https://github.com/coder/ghostty-web) for the embedded
terminal. That gave us a foundation for bringing a terminal into the desktop app.

As AX Code evolved, we wanted deeper integration and more powerful capabilities,
including WebMCP support. Those goals led us to start AkiTTY as a revamp based on
[Ghostty](https://github.com/ghostty-org/ghostty), with a native Mac client and a
separately maintained web terminal. WebMCP is part of this direction; the feature
list below describes what the current release implements.

Our focus is our **macOS client** and its integration with AX Code. For other
platforms, we recommend trying **[Ghostty](https://github.com/ghostty-org/ghostty)**
where it is available. It is an excellent project, and we are grateful to its
contributors for the work that helped make AkiTTY possible.

## What is implemented

- Native windows, tabs and split panes with interactive login shells; a visible
  **+** opens a new tab. Normal shell exit closes its pane, then any empty tab/window.
- Opening a folder (Finder **Open With**, a Dock drop, or `open -a Akitty <folder>`) starts
  a window whose tabs and splits begin in that folder; a file opens in its folder.
- Native **Settings… (⌘,)** for font/size, a separate CJK font, shell, starting directory, scrollback,
  Option-as-Alt and update checks. Appearance changes apply to open terminals;
  shell, directory and scrollback changes apply to new terminals. Any installed fixed-pitch font can be chosen.
- Rust-owned PTYs, bounded input, terminal parsing, configurable scrollback (5,000 lines by default), alternate
  screens, ANSI/truecolor output, Unicode cell widths and selection.
- CoreText text rasterization and Metal presentation, with visible software
  fallback when Metal fails. Snapshot processing and rasterization run off the UI thread.
- Box drawing, block elements and braille (U+2500–U+259F, U+2800–U+28FF) are drawn from geometry to the exact cell,
  so borders, tables and block graphics join across rows without gaps.
- Chinese, Japanese and Korean text on a two-column grid: the CJK font follows the system language (or the CJK font
  setting) so unified Han characters take regional shapes, and wide glyphs are centred and fitted inside their cells.
  Emoji ZWJ sequences and flags are drawn as one glyph; layout stays on wcwidth rules (grapheme-cluster mode 2027 is
  reported as unsupported), so cursor maths in apps stays aligned.
- IME marked text, accessible terminal text/selection, text copy/paste, clipboard
  write approval, scrollback search and font-size controls.
- SGR and legacy mouse reporting; hold Option to select/scroll locally.
- Open a folder from Finder (**Open With**), a Dock drop or `open -a Akitty <path>` to start a window there. Files
  open in their folder, and at most 8 folders open per request; skipped items are reported.
- A native command palette ranked by bundled TypeScript through JavaScriptCore.
  It adapts AX TUI's fuzzy ranking without importing its Zig-backed renderer.
- A versioned C ABI, explicit memory ownership, panic containment and tests across
  Rust, C, Swift and TypeScript.

**AkiTTY Web** (`packages/akitty-web`) is a separate, browser-canvas terminal used by AX Code Desktop. It started
from ghostty-web, is now maintained independently, and runs Ghostty's VT parser as WebAssembly. It is not part of the Mac app and is not published as a
package. See [its README](packages/akitty-web/README.md).

**Status: early 0.9.0 implementation.** This is not a drop-in Ghostty replacement.
Sixel, file/shared-memory and Unicode-placeholder Kitty graphics, Kitty animation frames, image clipboard protocols, custom shaders,
Ghostty configuration compatibility, shell integration, quick terminal and third-party plugins are not implemented. A bounded Kitty
graphics subset (direct raw RGB/RGBA and in-band PNG with zlib and chunking, image numbers, source rectangles and cell offsets,
z-index layers and every delete mode) is supported, placements follow scrolling, scroll regions and resizes, and programs see the
window's pixel size (TIOCGWINSZ, CSI 14 t and CSI 16 t), so PNG-based image tools and AX Code's opening and ending scenes can run; OSC 8
hyperlinks open with Command-click, and underline styles and strikethrough render.
The Kitty keyboard protocol is implemented (all five flags, press/repeat/release events,
modifier-only keys); base-layout alternate keys are reported only for US-position keys. Search currently finds the
latest literal match. Full external esctest qualification, VoiceOver user testing,
performance parity and testing on every supported Mac version remain separate work.

## Build and run

Requires macOS 14+, Xcode/Command Line Tools with Swift 6, rustup and Node 22+. Zig is not needed; it is only used
to rebuild AkiTTY Web's prebuilt wasm file.
Rust 1.99.1 and dependency lockfiles are pinned. Build scripts select the rustup
compiler explicitly to avoid mixing in a different Homebrew Rust standard library.
Builds target the current Mac architecture.

```sh
rustup toolchain install 1.99.1 --profile minimal --component clippy --component rustfmt
scripts/build-app.sh release
open build/Akitty.app
```

For a development build, use `scripts/build-app.sh debug`. The app does not need
Node or npm at runtime. It starts your login shell in your home directory, or in
the Settings starting directory or an opened folder.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Settings | Command-Comma |
| New window / tab | Command-N / Command-T |
| Split / close pane | Command-D / Command-W |
| Command palette | Command-Shift-P |
| Copy / paste | Command-C / Command-V |
| Find in scrollback | Command-F |
| Font larger / smaller / reset | Command-Plus / Command-Minus / Command-0 |

Closing a live terminal asks for confirmation. Terminal-initiated clipboard reads
receive an empty reply; text writes require approval. Images are never decoded by
the clipboard confirmation path. Only the bundled, bounded TypeScript code runs;
it has no shell, filesystem or network bridge.

## Verification and distribution

```sh
scripts/verify.sh
```

This covers Rust, TypeScript, the C ABI, Swift, the release scripts and AkiTTY Web (type-check and tests).
The macOS workflow runs all behavioral tests, lint, cross-language ABI checks and
the public-file audit without suppressing failures. The curated conformance suite
is a required check; passing it is not a claim of full xterm/esctest conformance.

`AKITTY_FORCE_METAL_UNAVAILABLE=1` and `AKITTY_FORCE_SHADER_ERROR=1` exercise renderer
fallback when launching the executable directly. Software rendering remains usable.

Distribution signing and notarization use existing local credentials:

```sh
AKITTY_SIGNING_IDENTITY='Developer ID Application identity or certificate hash' \
AKITTY_NOTARY_PROFILE='existing-keychain-profile' scripts/notarize.sh
```

See [release and R2 delivery](docs/RELEASING.md) for the complete publication flow.

The script signs, submits to Apple, verifies acceptance, staples and assesses the
app, then writes `build/Akitty-macOS.zip`. Credentials and submission receipts are
never committed. This command does not publish a GitHub release.

## Acknowledgments and MIT license

AkiTTY is a revamp of **[Ghostty](https://github.com/ghostty-org/ghostty)**. We
acknowledge **Mitchell Hashimoto and the Ghostty contributors** for the original
project, its native terminal design, and the source used as the starting reference.
AkiTTY is an independent project, not an official Ghostty release.

AkiTTY's own code is **MIT licensed**; see [LICENSE](LICENSE). Original notices are
preserved for adapted code. Third-party dependencies retain their own licenses;
MIT does not relicense them. The Rust terminal engine is
[alacritty_terminal](https://github.com/alacritty/alacritty) (Apache-2.0).
The command-ranking adaptation comes from [AX TUI](https://github.com/defai-digital/ax-tui)
(MIT); see [provenance](third_party/ax-tui/NOTICE.md) and
[third-party notices](THIRD_PARTY_NOTICES.md).

The supplied [full logo](assets/logo.png) is retained; the
[Mac icon](assets/README.md) uses the cat emblem without the wordmark.
See [architecture and compatibility scope](docs/ARCHITECTURE.md) for the decisions.

Private agent instructions, `.internal`, raw reviews, credentials and machine paths
are excluded. `scripts/check_public.py` audits the exact Git index or committed tree
before publication, in addition to `.gitignore`.
