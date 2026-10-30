# Akitty architecture and implementation plan

Akitty's native macOS app uses the unmodified `alacritty_terminal` 0.26.0 engine
with Akitty's own Rust integration, Swift/AppKit interface, CoreText/Metal
rendering, and a small TypeScript feature layer. Its own source is MIT licensed.
Windows and Linux are reached through the separate AkiTTY Web browser terminal.

| Component | Technology |
| --- | --- |
| AkiTTY native Mac app | Alacritty terminal engine + Akitty-owned Rust/Swift code |
| AkiTTY Web | Ghostty VT parser compiled to WebAssembly + Canvas rendering |
| Ghostty app (separate upstream project) | Ghostty's own Zig core and native platform interfaces |

Ghostty is a design and source reference for the native app, not its runtime
engine. The Mac app does not reuse Ghostty's Zig core or renderer or inherit their
performance characteristics. Web parser reuse does not establish native-app
performance or feature parity. See [the roadmap](ROADMAP.md) for planned work.

## Decisions

- Pin alacritty_terminal 0.26.0 for VT state and parsing; keep its types private.
  Directly translating Ghostty's Zig core would recreate a substantial correctness
  burden. Dependencies keep their own licenses (the engine is Apache-2.0).
- Rust owns PTY lifecycle, input backpressure, grid, and terminal protocol events.
  One nonblocking worker owns each PTY. Session state is mutex protected; logical
  serialization does not assume DispatchQueue calls stay on one OS thread.
  Shutdown sends HUP, then KILL, and polls child status with a bounded deadline;
  it never blocks in `wait()`. If macOS delays reaping, one shared reaper retains
  ownership, with a 64-child limit including pending cleanup. Swift marks a
  session closed before calling Rust cleanup and releases its lock, so late UI
  events cannot block the main thread behind child termination. Repeated view
  shutdown requests wait for the same cleanup. Close/quit confirmations are
  guarded, asynchronous window sheets; Cancel and Escape preserve the session.
- ABI v1 uses bounded UTF-8 JSON, integer session handles, explicit buffer freeing,
  version checks, errors and panic containment. Both sides validate dimensions.
- Swift owns AppKit windows/tabs/splits, IME, text accessibility, pasteboard policy,
  CoreText rasterization and Metal presentation. A renderer failure switches to a
  visible software fallback. No GTK/OpenGL code is carried over.
  The rasterizer keeps its bitmap and glyph cache between frames and repaints only the rows the core marked dirty
  (plus the old and new cursor rows); a new size, font or scale, any image, or an unknown change repaints everything.
  The Metal texture is updated in place for the changed pixel rows when no GPU frame is pending. Software fallback
  frames are always full.
  Cells holding one box-drawing, block or braille scalar are drawn by `CellGlyphs` as whole-device-pixel fills inside
  the cell box rather than through the font (rows are taller than glyphs, so font strokes leave gaps). Other
  non-ASCII text is fitted into its cell: wide glyphs are centred and shrunk to fit, and `GlyphClusters` joins emoji
  ZWJ sequences and regional-indicator pairs into one drawn glyph without changing the core's wcwidth column layout.
  ASCII keeps the plain CoreText path. Every face carries a CJK-first cascade list (`GlyphFonts`) chosen from the CJK
  font preference or the system language.
- Clipboard reads from terminal applications are denied. OSC 52 text writes need
  user approval; images are unsupported, so confirmation never decodes images.
- TypeScript ranks native commands through bundled JavaScriptCore code. Swift is
  the command authority. No Node runtime, shell bridge, dynamic plugin loading,
  AX TUI native renderer, or arbitrary user JavaScript is included.
- Adapt only AX TUI's fuzzy ranking algorithm, with pinned provenance and license.
  The original registry imports Node and renderer classes and is not copied whole.

## Independent advice

Muse CLI recommended a mature Rust engine, narrow versioned ABI, bounded process
shutdown, permission-first clipboard behavior, native IME/accessibility and
blocking regressions. Grok CLI and Muse CLI independently recommended declarative
TypeScript palette results validated and dispatched by Swift. Grok's first architecture call timed out; a shorter retry completed and agreed on
engine reuse, while highlighting render data cost, character-width authority and
PTY cleanup. Raw discussions are private and excluded from publication.

Advice is not test evidence. In particular, a serial queue is not a fixed OS
thread, and a JavaScriptCore time-limit API must not be assumed public/available.
Only bounded, bundled trusted code is evaluated; no untrusted JavaScript runs.

## Implementation order and acceptance

1. Rust engine, ABI, PTY lifecycle: terminal escape behavior, split UTF-8/escape
   input, alternate screen, resize, output replies, stale handles, bounds, process
   cleanup and backpressure regressions must pass.
2. Swift app: interactive shell, tabs/splits, scrollback, copy/paste/find, IME and
   accessible text. Test native policy and Unicode selection behavior.
3. Metal presentation: check each creation/encoding/completion stage; exercise
   fallback by injected device/pipeline failure and verify the app still draws.
4. TS palette: deterministic ranking, bounded inputs, schema/ID validation,
   exception fallback and native execution. Typecheck and run JSCore integration.
5. macOS CI runs the complete local verification command with no ignored test
   failures. Public files are checked for secrets, machine paths and agent files.
6. Build and smoke-test the app before committing/pushing. Signing/notarization,
   release publication and independent artifact verification are separate gates.
   Full external esctest qualification and dedicated VoiceOver development/user
   testing are outside the current roadmap, not release gates.

The next planned work is performance/stability qualification, shell integration,
and quick terminal. Their acceptance criteria are recorded in [the roadmap](ROADMAP.md);
they are not implemented by the architecture or existing test results alone.

## Compatibility scope

Shell integration and quick terminal are planned native-app features and are not
implemented yet. Ghostty configuration compatibility, third-party plugins and a
public extension ecosystem are outside the current roadmap. Sixel, image clipboard
protocols, and custom shaders remain unsupported. Dedicated VoiceOver work and
user testing are outside this roadmap; existing macOS accessible text/selection
APIs remain part of the implementation.

The Kitty keyboard protocol is advertised because
`KittyKeyboard.swift` encodes every flag; Option-as-Alt governs whether Option
is a modifier or composes text, and input-method text still composes. CoreText rendering is not a claim of Ghostty's
performance or shaping parity. Full esctest results are not inferred from the
curated conformance suite.

Kitty graphics follows the protocol with hard limits. The core strips APC strings from the
byte stream before the VT parser, keeps decoded RGBA images under hard limits
(8 Mi pixels per image, 128 MiB and 256 placements per session) and reports visible
placements in the snapshot, including source rectangles and pixel offsets. Pixels
cross the boundary through `akitty_image_read_v1`, not JSON, so 1080p animation
frames stay clear of the 8 MiB response cap. Raw RGB/RGBA and PNG (`f=100`, normalized
to RGBA8) arrive in-band or through files, temp files and shared memory under Kitty's
rules (`media.rs`): bounded reads, regular files outside /dev, /proc and /sys only, temp
files and shared memory consumed. Unicode placeholders (`placeholder.rs`) decode U+10EEEE
cells per row into image slices of a virtual placement; relative placements resolve
through their parent chain when the snapshot is built; animation frames, composition and
playback live in `graphics.rs`, ticked before each snapshot, with `animating` telling the
app to poll at the display rate. Placements
stay attached to their text: a `tracker` handler sits between the parser and the
terminal, forwards every callback unchanged and mirrors scroll regions, linefeeds,
autowrap, reverse index, insert/delete lines, erase display, resets and resizes into
the placement list, so images keep moving with the content even once scrollback is
full. Swift fetches pixels off the main thread. With Metal, frames without images keep
the single CPU bitmap; frames with images render the text as two transparent layers
(cell fills, then glyphs and cursor) with the same rasterizer code and draw every image
as its own texture in Kitty's three z bands around them, re-uploading a texture only when
its generation changes; an image-only update skips the CPU raster entirely. A display
link polls while `animating` is set or images changed in the last second. The software
fallback still composites images in the CPU bitmap.

## macOS 0.6 release additions

The deliberately small settings surface covers appearance, new-terminal startup,
scrollback and Option-key behavior. Preferences remain in local UserDefaults.
The tab bar follows native macOS tabs (as Ghostty uses): tabs share the bar's width
equally, each has a close button (confirming when a process is running), drags to
reorder, has a Close Tab / Close Other Tabs / Close Tabs to the Right menu, and shows
its ⌘1–⌘8 shortcut (⌘9 is the last tab). The plus button and close buttons are
accessible. Successful shell exit closes
the associated pane and any empty tab/window; failed startup remains visible.

Sparkle owns signed update verification and installation. A gentle titlebar reminder
keeps scheduled checks out of the user's typing flow. Automatic downloads/installations
are disabled, and live terminal sessions retain their termination confirmation.
AkiTTY has its own R2 bucket and route under the shared download hostname. AX Code
and Desktop informed immutable artifact/readback gates; their implementation and
cross-platform release policy are not imported. See RELEASING.md for publication order.

## AkiTTY Web

`packages/akitty-web` is how AkiTTY supports Windows and Linux. AX Code Desktop embeds this terminal in its web UI.
The installable app stays Apple Silicon and macOS 14 or later, and this package is a separate implementation: it does
not use the Rust core, the C ABI, or the Swift app. It renders to an HTML canvas and uses Ghostty's VT parser as a
prebuilt WebAssembly module, behind an xterm.js-style API. The same library runs in a browser on Windows, Linux, and
macOS. It started from coder/ghostty-web v0.4.0 and is now maintained independently.

The package does not spawn a PTY. The host starts the shell on that operating system, writes output into the
terminal, and receives keystrokes from the terminal. Browser keyboard events supply Ctrl, Alt, and Meta. Ctrl+C is
the interrupt on every platform, and links open on Ctrl-click or Command-click. A Windows `file://` wasm path is
normalized (`/C:/…` to `C:/…`); browsers load the module with `fetch`. There is no Windows or Linux installer in
this repository. People on those systems use the host that embeds AkiTTY Web.

- **Platforms:** Windows and Linux support is this browser terminal, including on macOS inside AX Code Desktop. The
  native app has no Windows or Linux build. CI type-checks the package and runs Vitest on macOS. There is no Windows
  or Linux browser run in this repo.
- **Scope:** it was migrated from `ax-code-desktop`, which keeps its own copy for now. Neither side syncs automatically.
- **Distribution:** private source package, never published. Consumers compile its TypeScript.
- **Zig:** only rebuilding the wasm needs Zig 0.15.2. The macOS app, the Rust core and the normal build do not.
- **Independence:** it is no longer a tracked fork. Nothing is synced from ghostty-web; fixes are made directly in
  `lib/`. `packages/akitty-web/PROVENANCE.md` records only the origin, licenses and the wasm/patch pins and hashes.
  Clipboard, link and mouse behavior has not had Akitty's native clipboard policy review.
- **Agent access:** `lib/agent` gives programs bounded, read-only text access (`readScreen`, `readOutput`), plain JSON
  tool definitions and an optional WebMCP adapter. Input and command execution are intentionally not offered: they need
  a host PTY service, authorization and an input-control rule that the browser package cannot enforce. Terminal text
  is untrusted and tool results say so.
- **Verification:** type-check and Vitest run in `scripts/verify.sh`; there is no browser or end-to-end test in this repo.

## macOS folder opening

Finder "Open With", Dock drops and `open -a Akitty <path>` create one window per existing folder (a file uses its
parent folder), up to 8 per request. Missing paths and non-file URLs are counted and reported, not ignored silently.
The folder applies to every tab and split in that window; Settings supplies the directory otherwise.
