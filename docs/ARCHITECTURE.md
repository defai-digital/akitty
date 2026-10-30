# Akitty architecture and implementation plan

Akitty is an independent, macOS-only Rust/Swift revamp of Ghostty, with a small
TypeScript feature layer. Its own source is MIT licensed. It is not a mechanical
port and does not promise Ghostty protocol or configuration parity.

## Decisions

- Pin alacritty_terminal 0.26.0 for VT state and parsing; keep its types private.
  Directly translating Ghostty's Zig core would recreate a substantial correctness
  burden. Dependencies keep their own licenses (the engine is Apache-2.0).
- Rust owns PTY lifecycle, input backpressure, grid, and terminal protocol events.
  One nonblocking worker owns each PTY. Session state is mutex protected; logical
  serialization does not assume DispatchQueue calls stay on one OS thread.
- ABI v1 uses bounded UTF-8 JSON, integer session handles, explicit buffer freeing,
  version checks, errors and panic containment. Both sides validate dimensions.
- Swift owns AppKit windows/tabs/splits, IME, text accessibility, pasteboard policy,
  CoreText rasterization and Metal presentation. A renderer failure switches to a
  visible software fallback. No GTK/OpenGL code is carried over.
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
   release publication and full external esctest qualification are separate gates.

## Compatibility scope

Unsupported initially: sixel, PNG/file/shared-memory Kitty graphics, image
clipboard protocols, custom shaders, Ghostty config compatibility, shell integration, quick terminal and a
public extension ecosystem. The Kitty keyboard protocol is advertised because
`KittyKeyboard.swift` encodes every flag; Option-as-Alt governs whether Option
is a modifier or composes text, and input-method text still composes. CoreText rendering is not a claim of Ghostty's
performance or shaping parity. Full esctest results are not inferred from the
curated conformance suite.

Kitty graphics is a deliberately small subset. The core strips APC strings from the
byte stream before the VT parser, keeps decoded RGBA images under hard limits
(8 Mi pixels per image, 128 MiB and 256 placements per session) and reports visible
placements in the snapshot. Pixels cross the boundary through
`akitty_image_read_v1`, not JSON, so 1080p animation frames stay clear of the 8 MiB
response cap. Only direct transmission is accepted: a program can never make Akitty
read a file or shared-memory segment. Swift fetches pixels off the main thread and
draws them in the grid rasterizer by z-index.

## macOS 0.6 release additions

The deliberately small settings surface covers appearance, new-terminal startup,
scrollback and Option-key behavior. Preferences remain in local UserDefaults.
Native tab controls expose an accessible plus button. Successful shell exit closes
the associated pane and any empty tab/window; failed startup remains visible.

Sparkle owns signed update verification and installation. A gentle titlebar reminder
keeps scheduled checks out of the user's typing flow. Automatic downloads/installations
are disabled, and live terminal sessions retain their termination confirmation.
AkiTTY has its own R2 bucket and route under the shared download hostname. AX Code
and Desktop informed immutable artifact/readback gates; their implementation and
cross-platform release policy are not imported. See RELEASING.md for publication order.

## AkiTTY Web

`packages/akitty-web` is a separate terminal for AX Code Desktop's web UI. It does not use the Rust core, the C ABI or
the Swift app. It renders to a canvas and uses Ghostty's VT parser as a prebuilt WebAssembly module, behind an
xterm.js-style API. It started from coder/ghostty-web v0.4.0 and is now maintained independently.

- **Scope:** it was migrated from `ax-code-desktop`, which keeps its own copy for now. Neither side syncs automatically.
- **Distribution:** private source package, never published. Consumers compile its TypeScript.
- **Zig:** only rebuilding the wasm needs Zig 0.15.2. The macOS app, the Rust core and the normal build do not.
- **Independence:** it is no longer a tracked fork. Nothing is synced from ghostty-web; fixes are made directly in
  `lib/`. `packages/akitty-web/PROVENANCE.md` records only the origin, licenses and the wasm/patch pins and hashes.
  Clipboard, link and mouse behavior has not had Akitty's native clipboard policy review.
- **Verification:** type-check and Vitest run in `scripts/verify.sh`; there is no browser or end-to-end test in this repo.

## macOS folder opening

Finder "Open With", Dock drops and `open -a Akitty <path>` create one window per existing folder (a file uses its
parent folder), up to 8 per request. Missing paths and non-file URLs are counted and reported, not ignored silently.
The folder applies to every tab and split in that window; Settings supplies the directory otherwise.
