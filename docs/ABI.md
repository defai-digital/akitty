# Akitty ABI and schema 1

The public header is `include/akitty.h`. Swift's mirrored header is checked byte
for byte during verification. `akitty_abi_version()` must equal 1 before any call.
No Rust layout, engine type or pointer to a session crosses this boundary.

`akitty_request_v1(data,len)` borrows up to 1 MiB of UTF-8 JSON for the call. The
caller must provide a valid readable slice. The result is an owned buffer of up
to 8 MiB. Pass that exact pointer and length to `akitty_buffer_free_v1` once; never
free it with another allocator, change its length, use it after freeing, or free
it twice. Null output indicates failure to produce a response.

Every response is `{ "version": 1, "ok": true, "data": ... }` or
`{ "version": 1, "ok": false, "error": "..." }`. An oversized snapshot returns
an error, never truncated terminal data. Inputs reject unknown fields. `op`
selects the request; `id` is a nonreused integer returned by `create`.

| Operation | Additional fields | Behavior |
| --- | --- | --- |
| version | none | Version/platform information |
| create | cols, rows; optional shell, cwd, headless | Create session; absolute shell path; default login shell |
| close | id | Stop/reap the child; idempotent |
| snapshot | id; optional since | Current snapshot, changed=false, or a partial snapshot (below) |
| input | id, text; optional paste | UTF-8 input with optional bracketed-paste protection |
| input_bytes | id, bytes | Raw byte input for terminal protocols, bounded to 64 KiB + delimiters |
| resize | id, cols, rows | Resize kernel PTY and terminal state in worker order |
| scroll | id, lines | Bounded scrollback movement |
| select | id, start_row, start_col, end_row, end_col | Visible cell coordinates; return selected text |
| find | id, text | Latest literal matching line in history; bounded query |
| feed | id, text | Parser input for headless sessions only |
| cell_size | id, width, height | Cell size in pixels (1–256 by 1–512), used for graphics placement and size reports |

Dimensions: 2–512 columns, 1–256 rows, at most 32,768 visible cells. At most 64
sessions and 5,000 scrollback lines per session. Input/reply queues are bounded.
Snapshots include authoritative Rust cell coordinates, colors, flags, cursor,
mode state, visible text, title, clipboard requests and lifecycle/error status.
Swift converts cells to UTF-16 offsets only for macOS text/accessibility APIs.

**Kitty keyboard protocol.** The core answers the protocol's flag stack (`CSI > u`
push, `CSI < u` pop, `CSI = u` set, `CSI ? u` query), separately for the main and
alternate screens, and reports the active flags as the snapshot integer `kitty_flags`
(1 disambiguate, 2 event types, 4 alternate keys, 8 all keys as escape codes,
16 associated text). The Swift app encodes keys from those flags; with 0 the
legacy encoding is unchanged byte for byte. The flags are as fresh as the last
snapshot, so a key typed within one poll interval of a flag change may use the old mode.

**Kitty graphics.** The core answers a subset of the Kitty graphics protocol sent
as APC strings: queries (`a=q`), direct (`t=d`) raw RGB/RGBA (`f=24|32`)
transmission with optional zlib (`o=z`) and `m=` chunking, placement (`a=T|p`)
and deletion (`a=d`: all, by image id, by z-index; capitals also free image data).
Files, shared memory and PNG are refused with `ENOTSUP`, so terminal output can
never make the core read a local file. Images are at most 8 Mi pixels, one session
holds at most 128 MiB of pixels and 256 placements, and zlib output is capped at the
declared size. The snapshot lists visible placements in `images` (`id`, `gen`
generation, pixel `w`/`h`, viewport `row`/`col`, `cols`/`rows` in cells, `z`; at most
64). Pixels do not travel in JSON: `akitty_image_read_v1(session, image, out,
capacity)` copies `w*h*4` RGBA bytes and returns the count, or 0 on any error.
Main-screen placements follow scrolling only while scrollback is growing (the core
sees scrolling as history growth), so with scrollback 0, a full scrollback buffer, or
on the alternate screen an image stays on its viewport row when text scrolls past it.
Programs that animate (such as AX Code) redraw in place and delete explicitly.
Alternate-screen images are removed when that screen is left.

**Delta snapshots.** Blank cells on the default background are not listed in `cells`;
`lines` holds every column, and a missing cell is one space. When `since` equals the
revision of the last snapshot the core sent for that session and the grid size is
unchanged, the core may reply with `"partial": true` and `"dirty": [rows]`. Then
`cells` holds only the dirty rows' cells and `lines` only their text, in `dirty`
order; the client replaces those rows in the snapshot it holds and keeps the rest.
Rows are compared by a 64-bit content hash (characters, colours, attributes,
selection, links), so a hash collision at worst delays one row's repaint. Any other
`since`, a resize, or a snapshot where every row changed gets a full snapshot, so a
client that lost state can always recover by asking again without `since`. The `links`
table is complete in every snapshot and keeps its indices across partial ones.

Optional per-cell fields are omitted when unset: `ustyle` (1 single, 2 double,
3 curly, 4 dotted, 5 dashed; `underline` stays true for any of them), `ucolor`
(RGB underline colour), `strike`, and `link`, an index into the snapshot `links`
array of OSC 8 targets. `links` holds at most 256 unique targets of at most 2,048
bytes with no control characters; others are dropped. The core does not judge
schemes: Swift opens only http, https and mailto targets, and only on Command-click.

Calls may move between threads. The registry lock only looks up/creates/removes
handles; session state is separately protected. Closing removes future lookup
access while existing calls retain ownership until completion. Panics do not
unwind into C; a poisoned session reports an error and can still be closed and
recreated without disabling other sessions.

Schema 1 is Akitty's contract, independent of the pinned terminal dependency.
Removing or changing a documented field/semantic requires a new ABI/schema major.
Additive response fields must be tolerated; unknown operations must fail.

`create` accepts optional `scrollback` in the range 0..20000 lines (default 5000).
Normal PTY termination reports the child exit code; the native UI closes successful
sessions and leaves failures visible.
