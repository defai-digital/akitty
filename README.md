<p align="center"><img src="assets/icon-source.png" width="160" alt="AkiTTY cat terminal logo"></p>

# AkiTTY

A native macOS terminal powered by [Alacritty](https://github.com/alacritty/alacritty),
with AkiTTY's own Rust integration, Swift/AppKit interface, CoreText/Metal rendering,
and a small TypeScript feature layer. The app runs on Apple Silicon and macOS 14
or later; no Zig compiler or runtime is required. Windows and Linux use
**AkiTTY Web**, the separate browser-canvas terminal inside AX Code Desktop.

| Component | Technology |
| --- | --- |
| AkiTTY native Mac app | Alacritty terminal engine + AkiTTY's own Rust/Swift implementation |
| AkiTTY Web | Ghostty VT parser compiled to WebAssembly + Canvas rendering |
| Ghostty app (separate upstream project) | Ghostty's own Zig core and native platform interfaces |

Ghostty informed AkiTTY's design and served as a source reference. The native Mac
app does not use Ghostty's Zig core or renderer, and does not inherit their
performance characteristics. AkiTTY Web reuses Ghostty's VT parser; the native
app and the web terminal have separate engines and rendering paths.

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

You can also [download the v1.1.2 ZIP](https://download.automatosx.com/akitty/releases/download/v1.1.2/AkiTTY-1.1.2-macOS-arm64.zip)
or visit the [GitHub release](https://github.com/defai-digital/akitty/releases/tag/v1.1.2).
Unzip it, move **Akitty.app** into **Applications**, and open it.

## What makes AkiTTY useful

AkiTTY gives each participating program a visible identity in its own tab:
its own small animated icon, working state, and a completion indicator that stays
until you view the tab. Imagine three AX Code sessions: a translation agent with
its own sprite and progress, a coding agent showing activity, and a test agent
leaving a finished dot when its background work ends.

Programs opt in through the dependency-free [terminal SDK](packages/akitty-sdk/README.md),
which writes OSC 771 through their existing stdout queue. The native app renders
the tab icon and activity, with text/progress in the pane status line; no separate
Python status-bar script is needed. Ordinary CLI programs do not gain this behavior
automatically, and these reports are program-supplied presentation, not verified
command results. Default detection disables these SDK updates through SSH and
multiplexers unless a host explicitly integrates them.

A second integration convenience is AkiTTY Web's ready-made, **read-only** agent
adapter: `list_sessions`, `read_screen`, and `read_output` expose terminal text,
including from a Canvas renderer. The host registers the tools; WebMCP additionally
needs a supporting browser. This is Web-only, and neither the tools nor terminal
output grant command execution or input ownership.

These are AkiTTY's integration strengths, not a claim that other terminals cannot
show progress or be automated. [Ghostty supports OSC 9;4 progress](https://ghostty.org/docs/install/release-notes/1-2-0),
and [iTerm2 has a scriptable status bar](https://iterm2.com/documentation-status-bar.html)
and [Python automation](https://iterm2.com/python-api/). AkiTTY emphasizes the
combination of program-selected tab identity, activity and completion, with direct
AX ecosystem integration. See [product scope and host integration](docs/AGENT_WORKFLOWS.md).

## New in 1.1.0

- Opt-in bash/zsh shell integration records command boundaries, timestamps,
  reported working directories and exit status, with bounded per-command output.
- Trusted native and JavaScript embedding hosts can use exclusive agent control,
  exact-command one-shot approvals, human reclaim and a bounded audit history.
  **Window → Agent Overview** lists every pane's controller and program reports.
  A native sheet asks for approval. The separate SDK `/host` entry accepts a host
  policy callback; an ax-trust deployment must supply its own authenticated adapter.
  There is no built-in ax-trust service connection.
- A persistent quick terminal can be shown/hidden from the Shell menu or an opt-in
  global shortcut selected in Settings. Hiding preserves its shell session.
- Drag files/folders into a terminal pane to insert shell-quoted paths; drag text
  to paste it with the same confirmation policy as the clipboard. Dropping onto
  the Dock/app continues to open a window at the requested folder.
- The native default background is deep dark (`#080A0D`), consistently across
  the core, Metal presentation and software rendering.

The new host API does not automatically upgrade AX Code Desktop's vendored Web
terminal or its PTY service. Shell metadata is untrusted; remote/multiplexer,
physical IME, sleep/wake and multi-day reliability need their own qualification.

## Why AkiTTY exists

AkiTTY began with [AX Code Desktop](https://github.com/defai-digital/ax-code-desktop),
where we used [ghostty-web](https://github.com/coder/ghostty-web) for the embedded
terminal. That gave us a foundation for bringing a terminal into the desktop app.

As AX Code evolved, we wanted deeper integration and more powerful capabilities,
including WebMCP support. Those goals led us to build an independent native Mac
client around Alacritty and maintain a separate web terminal using Ghostty's VT
parser. [Ghostty](https://github.com/ghostty-org/ghostty) informed the native app's
design as a source reference. WebMCP is part of this direction; [What is
implemented](#what-is-implemented) describes what the current release implements.

Our focus is our **macOS client** and its integration with AX Code. Windows and
Linux support is [AkiTTY Web](#windows-and-linux), described below. We thank the
Alacritty, Ghostty, and ghostty-web contributors for the engines and reference
work that helped make these two implementations possible.

## Windows and Linux

The downloadable app is macOS-only: Apple Silicon, macOS 14 or later. Windows and
Linux run AkiTTY through **AkiTTY Web** (`packages/akitty-web`), the canvas terminal
embedded in [AX Code Desktop](https://github.com/defai-digital/ax-code-desktop).

AkiTTY Web is a separate implementation from the Mac app. It draws on an HTML canvas
and parses terminal output with Ghostty's VT parser compiled to WebAssembly. The
same library runs in a browser on Windows, Linux, and macOS. It has no shell of its
own. AX Code Desktop starts the process on that operating system, writes the
output with `term.write()`, and takes keystrokes from `term.onData()`.

In the browser, Ctrl+C is the interrupt on every platform. Links open with
Ctrl-click or Command-click. The wasm loader accepts a Windows `file://` path
(`/C:/…` becomes `C:/…`) and a normal browser fetch.

There is no AkiTTY installer for Windows or Linux. This repository type-checks
AkiTTY Web and runs its unit tests on macOS. Playwright runs Chromium, Firefox
and WebKit on macOS, with additional Ubuntu and Windows browser CI jobs. Details are in [the package README](packages/akitty-web/README.md).

## What is implemented

- Native windows, tabs and split panes with interactive login shells; a visible
  **+** opens a new tab. Normal shell exit closes its pane, then any empty tab/window.
- Opening a folder (Finder **Open With**, a Dock drop, or `open -a Akitty <folder>`) starts
  a window in that folder; a file opens in its folder. A new tab opens after the current tab,
  in the focused pane's reported directory when that path still exists, and in the opened
  folder otherwise. Splits start in the opened folder.
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

**AkiTTY Web** (`packages/akitty-web`) is the Windows, Linux, and in-browser terminal
described in [Windows and Linux](#windows-and-linux). It is a private source package.

**Program integration:** [`@ax-code/akitty-sdk`](packages/akitty-sdk/README.md) is a
lightweight TypeScript/JavaScript SDK for terminal titles, status text, progress
and small title-bar sprites. It writes the existing terminal protocols through a
host-supplied output queue; native embedding continues to use the C ABI.

**Status: 1.1.2.** This is not a drop-in Ghostty replacement.
Bash/zsh shell integration is on by default (other shells start normally; turn it off
in Settings); quick terminal is opt-in.
Ghostty configuration compatibility and third-party plugins are outside the current
roadmap. Sixel, image clipboard protocols, and custom shaders remain unsupported.
The Kitty graphics protocol is supported with bounded limits: raw RGB/RGBA and PNG with zlib
and chunking over direct, file, temp-file and shared-memory transfer, image numbers, source rectangles and cell offsets, z-index
layers, every delete mode, Unicode placeholders, relative placements and animation (frames, composition, playback and loops).
Placements follow scrolling, scroll regions and resizes, programs see the window's pixel size (TIOCGWINSZ, CSI 14 t and CSI 16 t),
and on Metal each image is its own GPU texture composited between two text layers, so an animation frame re-uploads one texture
instead of repainting the window. `kitten icat` (every transfer mode and `--unicode-placeholder`), chafa, timg and viu are
exercised by `cargo test --test real_tools -- --ignored` when installed, and AX Code's opening and ending scenes run; OSC 8
hyperlinks open with Command-click, and underline styles and strikethrough render.
The Kitty keyboard protocol is implemented (all five flags, press/repeat/release events,
modifier-only keys); base-layout alternate keys are reported only for US-position keys. Find keeps a bar open,
highlights every visible literal match, and moves to the next or previous one.
Full external esctest qualification and dedicated VoiceOver development/user testing
are outside the current roadmap. Existing accessible text and selection remain
implemented; VoiceOver behavior is not qualified. Performance parity and testing
on every supported Mac version are not claimed.

## Planned work

- **Performance and stability:** measure parser/snapshot/rendering costs, reduce
  unnecessary idle and hidden-pane work, and expand malformed-input and PTY
  lifecycle stress coverage.
- **Shell integration qualification:** broaden startup-hook compatibility and remote/multiplexer coverage beyond the default-on local bash/zsh implementation.
- **Quick terminal qualification:** expand sleep/wake, Spaces and multi-display checks for the implemented persistent window and configurable global shortcut.

These are remaining qualification goals for the implemented features. See the
[implementation roadmap](docs/ROADMAP.md) for acceptance criteria and exclusions.

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
| Find next / previous | Command-G / Command-Shift-G |
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

We acknowledge **Mitchell Hashimoto and the [Ghostty](https://github.com/ghostty-org/ghostty)
contributors** for the terminal design and source reference that informed AkiTTY,
and for the VT parser used by AkiTTY Web. AkiTTY is an independent project, not an
official Ghostty release or a port of Ghostty's native terminal core.

The macOS app's terminal engine is **[Alacritty](https://github.com/alacritty/alacritty)**.
We thank **the Alacritty contributors** for `alacritty_terminal`, which provides
terminal escape-sequence parsing, the cell grid, and terminal state. AkiTTY uses
version 0.26.0 under Apache-2.0, maintained locally together with VTE, with its own Swift/AppKit interface and rendering. See [engine ownership](third_party/TERMINAL_ENGINE.md).
Alacritty is also credited in the app's **About Akitty** panel and the bundled
[third-party notices](THIRD_PARTY_NOTICES.md).

We also read **[iTerm2](https://github.com/gnachman/iterm2)** and
**[Kitty](https://github.com/kovidgoyal/kitty)** to understand how those terminals
are structured. Thank you to **George Nachman**, **Kovid Goyal**, and their
contributors for the architectural ideas that informed AkiTTY's own design.
Their source stays in their repositories under their own licenses (iTerm2 is
GPL-2.0, Kitty is GPL-3.0). The Kitty graphics and keyboard protocols AkiTTY
speaks follow Kovid Goyal's published specifications, in AkiTTY's own code.

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
