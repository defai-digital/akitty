# Akitty architecture and implementation plan

Akitty's native macOS app uses the independently authored `akitty-vt` Rust
terminal engine with its own Rust PTY integration, Swift/AppKit interface,
CoreText/Metal rendering and TypeScript feature layer. Its own source is MIT licensed.
Windows and Linux are reached through the separate AkiTTY Web browser terminal.
The Experimental Linux and Windows Tauri desktops shipped in 1.3.5 are discontinued
and removed from the tree; git history retains them.

The product focus is visible, human-controlled AI agent workflows: program-reported
identity, trusted-host execution approval, and observable terminal sessions.
Agent Overview and text accessibility already exist; current work improves their
focus, navigation, and validation. These controls govern input through AkiTTY's host
boundary, not operating-system process permissions. See [host workflows](AGENT_WORKFLOWS.md)
and [accessibility](ACCESSIBILITY.md).

Native agent development adds a separate bounded OSC 7501 record model, an opt-in
same-user request-only Unix socket, the bundled `akitty-agent` client, and a private
bounded event store. The app retains command approval authority; no ABI control
operations are exposed over IPC. Requests queue exact terminal input, not verified
process execution. See [native agent contracts and scope](AGENT_NATIVE.md).

| Component | Technology |
| --- | --- |
| AkiTTY native Mac app | Owned akitty-vt engine + Rust PTYs + Swift/AppKit/CoreText/Metal |
| AkiTTY Web | Same owned Rust engine compiled to WebAssembly + DOM/Canvas |

No Ghostty, Alacritty or VTE implementation is compiled or bundled. Historical
notices and test origins are documented in the [provenance ledger](../third_party/TERMINAL_ENGINE.md).
Native and browser platform behavior and performance require separate qualification.

## Decisions

- Own the streaming parser, screens/history, protocol modes, mutation events and
  keyboard encoder in `akitty-vt`. It has no PTY, filesystem or wall-clock access;
  hosts supply time and enforce clipboard/process policy. Unicode libraries and
  other ordinary dependencies retain their own licenses.
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
   Full external esctest qualification remains outstanding. VoiceOver operation
   testing is planned; automated accessibility tests do not establish user validation.

Version 1.1.0 adds opt-in bash/zsh shell observations, trusted host command control,
a persistent quick terminal, quoted file/text drops and a deep-dark default background.
See [host workflows](AGENT_WORKFLOWS.md).
Performance/stability and broader platform/workflow qualification remain in [the roadmap](ROADMAP.md).

## Compatibility scope

Shell integration (on by default for bash/zsh since 1.2.0) and the opt-in quick terminal are native features;
they do not automatically update the separate Web package or its host. Ghostty configuration compatibility, third-party plugins and a
public extension ecosystem are outside the current roadmap. Sixel, image clipboard
protocols, and custom shaders remain unsupported. Existing macOS accessible text/selection
APIs and Agent Overview are maintained features. VoiceOver testing and focused
accessibility improvements are P1; user validation is not complete.

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
its generation changes (an image wider or taller than Metal's 16384-pixel texture side is skipped, not a
renderer failure); an image-only update skips the CPU raster entirely. A display
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
The installable app stays Apple Silicon and macOS 14 or later. Web uses the same
Rust VT engine as native through its owned WASM ABI; the native C ABI and Swift
app are separate. A reauthored DOM/Canvas frontend provides an xterm.js-style API.
It runs in browsers on Windows, Linux and macOS. Version 0.6 changes the old
engine-specific exports; see the package README migration notes.

The package does not spawn a PTY. The host starts the shell on that operating system, writes output into the
terminal, and receives keystrokes from the terminal. Browser keyboard events supply Ctrl, Alt, and Meta. Ctrl+C is
the interrupt on every platform, and links open on Ctrl-click or Command-click. A Windows `file://` wasm path is
normalized (`/C:/…` to `C:/…`); browsers load the module with `fetch`. There is no Windows or Linux installer.

- **Platforms:** Windows and Linux support is this browser terminal, including on macOS inside AX Code Desktop. The
  native app has no Windows or Linux build. CI type-checks the package and runs Vitest on macOS. Playwright exercises Chromium, Firefox and WebKit on macOS, with Windows/Linux browser jobs also configured.
- **Scope:** it was migrated from `ax-code-desktop`, which keeps its own copy for now. Neither side syncs automatically.
- **Distribution:** private source package, never published. Consumers compile its TypeScript.
- **Build:** pinned Rust 1.99.1 compiles the owned WASM; no Zig or upstream terminal checkout.
- **Ownership:** production frontend and engine implementations are AkiTTY-authored.
  `packages/akitty-web/PROVENANCE.md` records historical test provenance and artifact hashes.
  Clipboard, link and mouse behavior still needs host-specific policy qualification.
- **Agent access:** `lib/agent` gives programs bounded, read-only text access (`readScreen`, `readOutput`), plain JSON
  tool definitions and an optional WebMCP adapter. Input and command execution are intentionally not offered: they need
  a host PTY service, authorization and an input-control rule that the browser package cannot enforce. Terminal text
  is untrusted and tool results say so.
- **Verification:** type-check and Vitest run in `scripts/verify.sh`; real-browser canvas pixel, keyboard, resize and disposal tests also run there. These do not qualify physical IME input or every font/platform combination.

## macOS folder opening

Finder "Open With", Dock drops and `open -a Akitty <path>` create one window per existing folder (a file uses its
parent folder), up to 8 per request. Missing paths and non-file URLs are counted and reported, not ignored silently.
The first tab and every split start in that folder. A new tab is inserted after the current tab and starts in the focused pane's reported working directory when that path still exists; otherwise it uses the opened folder. Settings supplies the directory when no folder was opened and the shell has not reported one.

## zsh folder command history

The bundled zsh integration stores accepted single-line commands with a timestamp and both the logical and
physical working directory. Tab offers five prefix matches, while Up/Down can cycle through up to twenty;
ranking combines frequency with recency. Suggestions only edit the command line. Enter from the suggestion
menu keeps a choice for review before a second Enter executes it. Existing widgets handle keys with no match.

Readers, appends, compaction and Settings' Clear History share a POSIX lock. Files and locks must be private,
owned regular files without links; the directory must be owned and not writable by others. Reads are bounded
to 512 KiB and 3,000 records, and appends compact files exceeding the byte limit. Commands are limited to
1,024 UTF-8 bytes; leading whitespace, multiline input and HISTORY_IGNORE matches are skipped. Builds
without safe nonblocking opens leave native history and keys active without installing folder storage.

Native `zshaddhistory_functions` retains its registered names and order, so `add-zsh-hook` can deduplicate
and remove hooks normally. Status-capturing wrappers let zsh invoke each hook itself; a final writer only
persists lines whose named and array hooks accepted persistence. Autoloaded functions load under their
original names before wrapping. Registration, removal and redefinition are reconciled before each prompt;
wrapper bookkeeping uses private names so dynamically scoped user variables remain visible and writable.
Handled failures inside nested function calls do not become history rejections. Storage errors never change
the native history result. `scripts/test_shell_integration.py` covers these behaviors on isolated interactive PTYs.

## Selection and input state

Selection extraction follows soft wraps, preserves significant spaces and includes overlapping wide glyphs.
The Web adapter resolves opaque retained-row identities once per core revision and clears selections after
their rows are evicted or the terminal is resized. Native resizing relocates both live and saved cursors,
including delayed wrap, and retains the scrolled viewport through height changes and line reflow.

The shared keyboard encoder handles functional-key repeat/release events, keypad identities, lock modifiers
and alternate keys according to the requested progressive flags. Legacy mouse releases retain modifier bits,
UTF-8 mouse coordinates respect their encoding limit, and horizontal or stationary wheel events do not emit
vertical reports. Regression evidence and protocol references are recorded in [the engine migration audit](ENGINE_MIGRATION.md#selection-resize-and-input-protocol-audit).

Native clipboard shortcuts run before enhanced keyboard encoding, so Command-V remains a paste even when a
foreground TUI asks for all keys as escape codes. Edit menu Copy/Paste use standard responder-chain actions;
the command palette retains its explicit pane target. Multiline/control text requires confirmation by default.
The warning's Don't ask again checkbox persists only when Paste is chosen; Settings can re-enable it for open
terminals. Additional pastes wait for the current dialog to finish. Bracketed paste strips escape characters
that could terminate its delimiters. Actual-PTY regressions check Unicode payloads, both shortcut paths,
approval/cancellation and the disabled-confirmation path.
