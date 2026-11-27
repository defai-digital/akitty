# Akitty architecture and implementation plan

Akitty's native macOS app uses the independently authored `akitty-vt` Rust
terminal engine with its own Rust PTY integration, Swift/AppKit interface,
CoreText/Metal rendering and Rust command-palette ranking. Its own source is MIT licensed.
Windows and Linux are reached through the separate AkiTTY Web browser terminal.
The Experimental Linux and Windows Tauri desktops shipped in 1.3.5 are discontinued
and removed from the tree; git history retains them.

The product focus is visible, human-controlled AI agent workflows: program-reported
identity, trusted-host execution approval, and observable terminal sessions.
Agent Overview and text accessibility already exist; current work improves their
focus, navigation, and validation. These controls govern input through AkiTTY's host
boundary, not operating-system process permissions. See [host workflows](AGENT_WORKFLOWS.md)
and [accessibility](ACCESSIBILITY.md).

The native app uses a bounded OSC 7501 record model, an opt-in same-user
Unix socket, the bundled `akitty-agent` client, and a private bounded event store.
AkiTTY 2.0.0 shares one per-pane approval queue across local command requests,
Siri and Shortcuts, and supported Claude Code and Codex permission prompts.
The app owns the approval decision. Approved command requests queue exact
terminal input, and the hook integrations return an allow or deny decision to
the agent. [Native agent contracts and scope](AGENT_NATIVE.md)

| Component | Technology |
| --- | --- |
| AkiTTY native Mac app | Owned akitty-vt engine + Rust PTYs + Swift/AppKit/CoreText/Metal |
| AkiTTY Web | Same owned Rust engine compiled to WebAssembly + DOM/Canvas |

No Ghostty, Alacritty or VTE implementation is compiled or bundled. Historical
notices and test origins are documented in the [provenance ledger](../third_party/TERMINAL_ENGINE.md).
Native and browser platform behavior and performance require separate qualification.
The [throughput plan and measurements](PERFORMANCE.md) document the ASCII-run and
PTY read-batching implementation and its measured scope.

The [contributor guide](../CONTRIBUTING.md) maps these components to their source,
tests, build commands, and generated artifacts. `akitty-core` composes `akitty-vt`
with the shared protocols, authority primitives, and Unix child cleanup in
`akitty-agent-core`; the VT engine depends on neither host crate.

## Decisions

- Own the streaming parser, screens/history, protocol modes, mutation events and
  keyboard encoder in `akitty-vt`. It has no PTY, filesystem or wall-clock access;
  hosts supply time and enforce clipboard/process policy. Unicode libraries and
  other ordinary dependencies retain their own licenses.
  The parser lends printable UTF-8 runs to the terminal, skipping whole eight-byte
  words of printable ASCII where a run opens and after each multi-byte scalar. Plain
  ASCII uses packed spans, stored without destructor checks on rows certified
  heap-free; ordinary narrow/wide Unicode codepoints use batched cells with each grapheme
  class carried into the next pair decision. Insert mode, character-set shifts,
  contextual grapheme joins, wrapping and wide-cell repair retain scalar handling.
  A per-terminal 16-slot, fixed-key cache reuses exact cluster break/width analyses;
  it has no unbounded map or per-key heap allocation. A synchronized frame whose
  exact `?2026l` arrives in the same chunk as its `?2026h` is applied as it arrives,
  which a host cannot tell from a replayed queue. Otherwise synchronized output retains
  the same bounded action queue, holding printable text as runs in one shared buffer
  that replay through the row writer when the queue flushes, and copying deferred
  CSIs into recycled records; each item keeps its scalar-action charge against the
  queue bound. A CSI whose introducer arrives whole has its ordinary body (prefix,
  digits, `;`, final byte) collected in one loop before the byte machine resumes.
- Rust owns PTY lifecycle, input backpressure, grid, and terminal protocol events.
  Each PTY is a bounded two-stage pipeline. A reader thread owns every `read(2)`
  and a worker thread owns the model, replies, writes, resize and child status, so
  no read runs with the terminal state held and no parse waits on the kernel.
  Reads move through a fixed ring of four 64 KiB slots whose ownership passes
  between the stages, so a read is never copied and a parser that falls behind
  stops the reader instead of growing memory. Every read that is available at once
  fills one slot up to its full size, which is published when it is full and
  otherwise on would-block, EOF or a read error. macOS hands a PTY master at most
  1 KiB per read, so a slot holding less than 1 KiB is published on its first
  would-block: a prompt, bell or query still arrives with the reads that produced
  it. A saturated stream instead bridges the writer's refill gaps: 16 immediate
  re-reads, then 1 ms polls while the parser still has published bytes, within
  3 ms per slot. The parser interrupts a bridge through a ring-owned idle pipe the
  moment it runs dry, and a stop or hangup publishes at once, so bridging only
  overlaps parse time and never delays an idle terminal. Bytes gathered before a
  failure are applied before it is reported. The
  worker applies at most one ring (256 KiB) per pass, with each model lock covering
  at most 8 KiB, so input and resize keep their turn, and it wakes the host once
  per applied batch rather than once per parsed chunk.
  Session state is mutex protected; logical serialization does not assume
  DispatchQueue calls stay on one OS thread. A close or child exit ends the reader
  with a bounded drain, and a hangup or read failure still flushes its tail.
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
  Ordered cell arrays let partial snapshots copy unchanged spans in bulk and let the rasterizer locate dirty rows
  with binary searches rather than scanning every retained cell. Metadata-only updates share the retained cell array.
  Integer-pixel text scrolls move retained bitmap rows and repaint exposed rows, cursor damage and complex or
  decorated text. Coalesced updates relocate their pending dirty rows too. Images, composition, cropped grids
  and fractional geometry retain the full repaint path. Metal receives the moved pixel rows as well.
  Automatic refreshes of visible unfocused panes coalesce at 30 Hz, retaining one trailing update. Focused panes,
  recent local input and grid resizing bypass this pacing; explicit scroll/selection refreshes remain immediate.
  Hidden panes retain their 4 Hz cadence. Live PTY panes are driven primarily by the core notification pipe, while
  the display link remains active for animation ticks and sessions without a notification descriptor. Panes that
  become hidden, occluded, minimized, or detached stop rasterizing, release window-sized bitmap/texture retention,
  and force a full repaint when they become visible again. Focus/visibility changes re-evaluate the pending deadline,
  and shutdown invalidates it before closing the session.
  The Metal texture is updated in place for the changed pixel rows when no GPU frame is pending. Software fallback
  frames are always full.
  Cells holding one box-drawing, block or braille scalar are drawn by `CellGlyphs` as whole-device-pixel fills inside
  the cell box rather than through the font (rows are taller than glyphs, so font strokes leave gaps). Other
  non-ASCII text is fitted into its cell: wide glyphs are centred and shrunk to fit, and `GlyphClusters` joins emoji
  ZWJ sequences and regional-indicator pairs into one drawn glyph without changing the core's wcwidth column layout.
  ASCII keeps the plain CoreText path. Every face carries a CJK-first cascade list (`GlyphFonts`) chosen from the CJK
  font preference or the system language.
  Frames of plain single-scalar ASCII, geometric cell glyphs, fitted monochrome single-scalar text in one or two
  columns, single-cell colour clusters, and single underline/strikethrough decorations on narrow cells can be drawn
  from a glyph atlas when they contain no images, IME text, wide geometric glyphs, decorations on wide cells,
  multi-scalar text, colour clusters that span cells, complex underline styles, or fractional geometry
  (`MetalText.swift`). A two-column cell is fitted into a box twice
  as wide and centred in it, exactly as the CPU rasterizer places it. What the colour eligibility excludes is a
  superset of what `GlyphClusters.merge` joins on — any ZWJ or regional indicator, not only a trailing ZWJ or an
  indicator pair — and every join merge can make starts at a cell carrying one, so on an eligible frame
  merging is the identity and the atlas may iterate raw cells instead of merged clusters.
  Each distinct font glyph is rasterised once by CoreText into one bounded coverage texture and uploaded only when
  new, and the GPU composites per-row instance buffers of cell fills, glyph quads, decoration strips and cursor
  quads. Box, block and braille scalars reuse the same `CellGlyphs` geometry to make colour-independent coverage
  tiles. Colour clusters draw from a second BGRA page of the same bounded side — 16 MiB rather than 4, so it is
  allocated only for a frame that reports it may sample the page (`TextFrame.usesColourPage`) and dropped on any
  atlas reset, which means an emoji-free epoch never pays for it. A colour tile is the whole cell box rather than
  cropped ink, so its instance maps the tile with no offset arithmetic, and it shares the fitted path's CoreText
  placement so it lands exactly where the equivalent mask would. One page suffices because a cluster is a single
  CoreText line and cannot be split across the two; the tile key still carries the foreground colour, because a
  COLR palette may reference it. Only the rows the core marked dirty are
  re-encoded and uploaded; while a frame is still on the GPU the upload publishes a complete replacement buffer
  from a bounded pool instead of rewriting the one it may read, so a frame never samples a half-updated revision.
  The atlas texture is tied to the glyph mask cache: frames drawn by other paths leave it alone, and it is released
  only with that cache. Atlas rebuilds are rationed per font/scale/grid/theme epoch, and a frame needing more masks
  than an empty atlas holds is refused, so an adversarial colour workload degrades to the software rasterizer
  instead of churning masks every frame. Standing down is not permanent: after a fixed number of refused frames the
  composer is allowed one probation rebuild, so a repertoire that outgrew the atlas and then shrank recovers without
  a resize, font or theme change, while a sustained storm still pays at most one wasted rebuild per interval. Because macOS text smoothing depends on the text colour at 1x and 2x, font
  masks are keyed by style, scalar, column count and foreground colour; geometric and decoration masks omit style and
  colour. Keying by scalar rather than by text matters for CJK: Swift compares strings by canonical equivalence, so a
  compatibility ideograph (U+FA10) equals and hashes like its unified form (U+585A) while CoreText draws different
  ink for each. The CoreText line analysis behind a fitted mask is cached separately and keyed by style and text
  alone, since it does not depend on the column count; a full analysis cache is dropped and rebuilt rather than
  refused, so a large CJK repertoire cannot pin the path to the software rasterizer for the rest of the epoch.
  Fitted text masks are anchored to the cell box and use the same CoreText placement as the CPU rasterizer. Content the atlas does not
  reproduce pixel-for-pixel (wide geometric glyphs, decorations on wide cells, multi-scalar text, colour clusters
  that join cells or exceed the bounded scalar count,
  complex underline styles, IME composition, Kitty images, backing scales outside 1x-3x) keeps the software
  rasterizer unchanged. A successful full
  content scan certifies
  atlas eligibility; a no-scroll incremental frame rechecks only its damaged rows, while scrolling, unknown damage,
  layout changes, fallback recovery and resource release require a fresh full scan. Snapshot damage is merged before
  any host callback can request a redraw, and CPU bitmap completion invalidates atlas reuse before frame observers run,
  so reentrant callbacks cannot render new cells with stale damage or eligibility. Frame-start observers run after the
  older frame has captured its state and damage, leaving newer snapshot damage intact for the queued redraw. Suspended
  atlases validate content before changing layout epochs, so an unsupported frame cannot re-arm their rebuild budget.
- Window chrome stays out of the grid. Tabs share the title bar (full-size content view, hidden title text that
  remains set for the Window menu and accessibility), and the window takes the focused pane's theme background and
  matching light or dark appearance. Pane status is a floating capsule over the pane rather than a reserved row, so
  a status appearing or clearing never resizes the PTY. Its style comes from the message source in Swift: program
  reports are neutral and click-through, and only the core's control record produces the agent style.
- Clipboard reads from terminal applications are denied. OSC 52 text writes need
  user approval by default; the prompt's Always allow choice (restorable in
  Settings) lets later writes through with a status capsule note. Images are
  unsupported, so confirmation never decodes images.
- Rust ranks native commands through the bounded `command_palette` ABI operation.
  Swift validates the closed command IDs and dispatches native actions, falling back
  to its native catalog on failure. No Node runtime, JavaScript engine, shell bridge,
  dynamic plugin loading, or arbitrary user JavaScript is included.

## Independent advice

Muse CLI recommended a mature Rust engine, narrow versioned ABI, bounded process
shutdown, permission-first clipboard behavior, native IME/accessibility and
blocking regressions. Grok CLI and Muse CLI independently recommended declarative
palette results validated and dispatched by Swift. Grok's first architecture call timed out; a shorter retry completed and agreed on
engine reuse, while highlighting render data cost, character-width authority and
PTY cleanup. Raw discussions are private and excluded from publication.

Advice is not test evidence. In particular, a serial queue is not a fixed OS thread.

## Implementation order and acceptance

1. Rust engine, ABI, PTY lifecycle: terminal escape behavior, split UTF-8/escape
   input, alternate screen, resize, output replies, stale handles, bounds, process
   cleanup and backpressure regressions must pass.
2. Swift app: interactive shell, tabs/splits, scrollback, copy/paste/find, IME and
   accessible text. Test native policy and Unicode selection behavior.
3. Metal presentation: check each creation/encoding/completion stage; exercise
   fallback by injected device/pipeline failure and verify the app still draws.
4. Rust palette: deterministic ranking, bounded inputs, schema/ID validation,
   failure fallback and native execution. Run Rust conformance and Swift ABI integration.
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

## macOS app surface

Settings covers appearance (font, a separate CJK font, theme and cursor), named
profiles, sessions (silent mode, paste and OSC 52 confirmation, shell integration,
zsh command history, shell, starting directory and scrollback), keyboard behavior
(quick terminal, Option-as-Alt and program status) and update checks. **Agents**
shows the installed CLIs, configures their integrations, and controls whether
Local Agent Requests starts with the app. Preferences remain in local UserDefaults.
The title bar shares space between width-capped tab controls, a new-tab button,
and a window drag area. Each tab remembers its last focused pane and uses that
pane's title. Swift strips spinner frames at the title edges and coalesces
rapid program updates to two displayed changes per second, keeping the latest
pending title. Close buttons and tab labels are accessible. Shell exit with a
reported status closes the pane and any empty tab or window. Failed startup
remains visible.

Drag a tab above or below the strip to detach it. Dropping anywhere along
another regular window's title bar transfers it, with free space after the
last tab appending the item. The context menu also offers **Move Tab to New
Window**. Transfers retain the split tree, terminal views, session handles,
profiles, and agent control state. The destination rebinds callbacks, restores
divider shares, and focuses the moved tab's remembered pane. An active Find
target in the moved tab takes precedence. The source window restores focus in
the tab it reveals or closes when empty. Escape and app deactivation cancel
the drag. Quick terminals, sheets, modal sessions, and app termination block
transfers. Custom tabs disable AppKit's native window tab groups.

Sparkle owns signed update verification and installation. A gentle titlebar reminder
keeps scheduled checks out of the user's typing flow. Automatic downloads/installations
are disabled, and live terminal sessions retain their termination confirmation.
AkiTTY has its own R2 bucket and route under the shared download hostname. AX Code
and Desktop informed immutable artifact/readback gates; their implementation and
cross-platform release policy are not imported. See RELEASING.md for publication order.

## AkiTTY Web

`packages/akitty-web` is how AkiTTY supports Windows and Linux. AX Code Desktop embeds this terminal in its web UI.
The installable app stays Apple Silicon and macOS 27.2 or later. Web uses the same
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

Finder's **Open With**, Dock drops, and `open -a Akitty <path>` can open a window
for an existing folder. A file sent by `open -a` opens its containing folder.
An ordinary file or a script without executable permission follows the same
folder path. Each request admits up to eight folders and programs together.
The app reports missing paths, non-file URLs, and items beyond the cap.

### Program confirmation and shell startup

A Unix executable or an executable `.command` or `.tool` file can take the
program path when the open event identifies a live sender with an application
bundle and bundle identifier. The `open` tool and an unavailable sender take
the folder path. On cold launch, the app opens admitted folders and waits
until it is active to present program confirmations. Pending programs share
an eight-program cap across cold-launch deliveries. Repeated programs are
deduplicated by resolved path while pending, being confirmed, or waiting for
their shell.

The prompt offers **Run**, **Open Folder**, and **Cancel**. **Run** opens a
shell in the program's directory and queues a quoted launch line. The shell
stays open after the program exits. The app checks device, inode, size,
modification time, and status-change time after approval and again before
sending the line. A change at either point cancels the launch.

- Integrated bash and zsh wait for a ready prompt for up to 30 seconds. Without
  integration, the launch line is sent after two seconds. An active modal
  dialog or a sheet on the terminal window pauses the wait.
- Typed input, a paste, active IME composition, or an edited integrated prompt
  cancels the pending launch. Focus and key-release reports can arrive while
  waiting. The launch line starts with Ctrl-U to clear the line editor and
  ends with CR to submit it. A shell that exits while waiting is reported.
- sh, bash, zsh, dash, and ksh use POSIX single-quote escaping. Fish also escapes
  backslashes. Quoting operates on Unicode scalars. Unsupported shells and
  paths with hidden control or format characters can still use **Open Folder**.
  Refused paths with hidden characters are omitted from the alert.

See the [shell integration contract](AGENT_WORKFLOWS.md#local-shell-integration)
for prompt hook ordering, including the zsh scheduler fallback.

### Launch Services and Dock commands

**AkiTTY → Make AkiTTY the Default Terminal** configures the Launch Services
handlers for `public.unix-executable` and `com.apple.terminal.shell-script`.
Installing AkiTTY registers it as an alternate handler. The menu changes the
types still handled by another app and stays enabled when a change only partly
succeeds. macOS asks for confirmation. Declining a prompt ends the change.

The Dock menu adds **New Window**, **New Tab**, **New Window with Profile**,
**Toggle Quick Terminal**, and **Agent Overview** above the system window list.
The Dock badge reports how many approvals are waiting.
**New Tab** uses the frontmost visible terminal, including a visible Quick
Terminal. If no terminal is visible, it uses the frontmost regular terminal
when available. With no eligible terminal it opens a window. A hidden Quick
Terminal stays hidden.

### Pane targets and starting folders

The first tab of a folder window starts in the opened folder. New splits inherit
their source pane's profile and use the window's opened folder if it still
exists. An ordinary new tab is inserted after the current one. It and a
restarted pane use the target pane's existing reported directory, then its
original starting folder, and finally its profile or Settings default. A tab
opened explicitly with a profile starts in that profile's configured folder.

While the find field holds focus, the pane being searched is the target for
close, restart, and font actions. It also supplies the profile for a new tab
or split and the directory for a new tab. Copy and paste follow the find
field's text editing.

## Named window layouts

**Shell → Window Layouts → Save Windows as Layout…** stores every open window, its
tabs and vertical splits, each pane's folder and profile, and the split proportions.
The shell's reported directory is saved while that path still exists; otherwise the
folder the pane started with is kept. Reopening starts fresh shells. At most 20
named layouts are stored, and the whole store is capped at 4 MiB.

**Include recent scrollback** is unchecked in the save dialog. The text can contain
sensitive output. Capture reads at most 200 rows and 16 KiB per pane without
consuming snapshot events. A layout's saved text shares a 128 KiB budget. Restore
strips terminal controls and places the plain text in the model before the new PTY
starts, with markers between the saved text and fresh output. Commands are never
replayed. **Remove Stored Scrollback** keeps the saved geometry and folders.

The separate **Reopen Windows and Agent Conversations at Launch** option stores
a bounded layout and reported conversation IDs in local UserDefaults. Each
restored pane opens a fresh shell. The user can ask AkiTTY to type that pane's
resume command at an empty, idle integrated prompt. A matching report from the
agent confirms the resume. [Workspace restore](AGENT_NATIVE.md#reopen-windows-and-resume-agent-conversations)

## zsh command history

The bundled zsh integration stores accepted single-line commands with a timestamp and both the logical and
physical working directory in the existing shared store. Queries scan records newest first and rank this
folder's records (by its logical or physical path) before other folders', each newest first; they filter by a
case-sensitive prefix and deduplicate commands before applying the result limit. Paths containing tab, CR or LF
are stored empty so the command is still kept. Tab offers the five latest distinct matches, while Up/Down can
cycle through up to twenty. Record order resolves equal timestamps without frequency weighting. Legacy storage,
environment variables and preference keys remain compatible; native `.zsh_history` is not imported. Suggestions
only edit the command line. Enter from the suggestion menu keeps a choice for review before a second Enter
executes it. Existing widgets handle keys with no match.

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
vertical reports. Regression evidence and protocol references are recorded in [the engine migration audit](archive/ENGINE_MIGRATION.md#selection-resize-and-input-protocol-audit).

The Web input adapter pairs enhanced key releases with presses it actually sent. Clipboard shortcuts and
keys consumed by a host handler do not leak release events to the terminal. Release events retain the
reported key identity even if a layout modifier was released first. AltGraph text and Ctrl+Alt chords remain
terminal input rather than being mistaken for clipboard shortcuts.

Native clipboard shortcuts run before enhanced keyboard encoding, so Command-V remains a paste even when a
foreground TUI asks for all keys as escape codes. Edit menu Copy/Paste use standard responder-chain actions;
the command palette retains its explicit pane target. Multiline/control text requires confirmation by default.
The warning's Don't ask again checkbox persists only when Paste is chosen; Settings can re-enable it for open
terminals. Additional pastes wait for the current dialog to finish. Bracketed paste strips escape characters
that could terminate its delimiters. Actual-PTY regressions check Unicode payloads, both shortcut paths,
approval/cancellation and the disabled-confirmation path.

Double-click selects a word and triple-click selects a line, including wide and combining text.
Program mouse reporting keeps priority; Option selects locally. Alternate-screen wheel input sends
cursor keys only while DEC mode 1007 is enabled.

Web custom wheel handlers may reset or dispose their terminal. The adapter stops the current gesture when the handler replaces or closes the engine, so it cannot access released state or scroll a replacement terminal.
