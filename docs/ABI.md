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
| snapshot | id; optional since, compact | Current snapshot, changed=false, or a partial snapshot (below) |
| input | id, text; optional paste | UTF-8 input with optional bracketed-paste protection |
| input_bytes | id, bytes | Raw byte input for terminal protocols, bounded to 64 KiB + delimiters |
| resize | id, cols, rows | Resize kernel PTY and terminal state in worker order |
| scroll | id, lines | Bounded scrollback movement |
| select | id, start_row, start_col, end_row, end_col | Visible cell coordinates; return selected text |
| find | id; text, or clear; optional direction | Literal search. `latest` (default) lands on the rightmost hit of the bottom-most matching line; `next` and `previous` move and wrap. `clear` drops the highlight. Query is 1–256 bytes, case sensitive, and does not cross a row |
| feed | id, text | Parser input for headless sessions only |
| cell_size | id, width, height | Cell size in pixels (1–256 by 1–512), used for graphics placement and size reports |
| chrome | id; optional clear, status, mark, progress, sprite | Replace the session chrome document. Applies even when program chrome is off |
| program_chrome | id, enabled | When false, `OSC 771` no longer changes the document |

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
as APC strings: queries (`a=q`), direct (`t=d`) raw RGB/RGBA (`f=24|32`) and PNG
(`f=100`) transmission with optional zlib (`o=z`) and `m=` chunking, image numbers
(`I=`; `i=` and `I=` are mutually exclusive, replies echo `i=...,I=...`), placement
(`a=T|p`) with source rectangles (`x`,`y`,`w`,`h` in image pixels, offsets `X`,`Y`
inside the first cell, spans derived from the source aspect ratio unless both `c`
and `r` are given) and deletion (`a=d`). PNG is checked against the pixel limit
from its header before any frame is allocated, normalized to RGBA8 from every
colour type and bit depth, and APNG yields only the default image; direct `o=z` PNG
inflates with the `S=` limit when given (else 32 MiB) and queries decode the
header only. Files (`t=f`), temp files (`t=t`) and shared memory (`t=s`) follow
Kitty's rules: the payload is the base64 path or object name, `O=`/`S=` select the
byte window, reads are bounded by what the format needs, temp files must sit in a
temp directory with `tty-graphics-protocol` in their name and are deleted after
the read, shared memory is unlinked, and `t=f` reads only regular files outside
/dev, /proc and /sys (checked on the opened descriptor) and never deletes them.
Every media failure answers `EBADF:failed to read image data`. Queries through
any medium read their (tiny) probe data, so clients can pick a transfer mode.
`U=1` stores a virtual placement that is never drawn itself: cells holding
U+10EEEE with the image id in the foreground colour (24-bit or 256-colour), the
placement id in the underline colour and row/column/high-id diacritics show the
matching slice of the image, fitted into the placement's `c`x`r` cells; missing
diacritics continue the left neighbour's run. `P=`,`Q=` with `H=`,`V=` place an
image relative to another placement on the same screen (`ENOPARENT`, `ECYCLE`, `ETOODEEP` beyond 8
links); children move with their parent and are deleted with it. Animation
follows Kitty: `a=f` composes a frame (base frame `c=`, edit frame `r=`, offset
`x=`,`y=`, background `Y=`, `X=1` overwrite, gap `z=`, 40 ms default, negative
gapless), `a=a` sets `s=` state (1 stop, 2 loading, 3 run), `c=` current frame,
`r=`+`z=` a frame's gap and `v=` loops (1 infinite), `a=c` copies a rectangle
between frames, and `d=f`/`d=F` delete a frame (`d=F` on a still image deletes
it). At most 512 frames per image count against the session pixel budget; the
image's pixels are always the frame on display, and each new displayed frame is
a new generation. Retransmitting an existing id
first deletes all of its placements; images sent with neither `i=` nor `I=` are
freed as soon as their last placement goes away. When a new image would exceed
the limits the core first evicts images without placements (oldest first), then
those whose placements are all in scrollback, before failing with `ENOSPC`;
placement overflow evicts scrollback placements first. Images are at most 8 Mi
pixels, one session holds at most 128 MiB of pixels and 256 placements, and zlib
output is capped at the declared size and a hard 128 MiB ceiling. Deletes implement every `d=` mode
(a/A visible-only, i/I and n/N by id or number with optional `p=`, c/C at the
cursor, p/P and q/Q at 1-based x=,y= coordinates (q adds z=), x/X by column,
y/Y by row, z/Z by z-index, r/R by id range, f/F animation frames), affect only the
current screen, cancel a pending chunked upload, and free unreferenced image
data when uppercase (lowercase still frees idless images); unknown modes reply
EINVAL. The snapshot lists visible placements in `images` (`id`, `gen`
generation, pixel `w`/`h`, viewport `row`/`col`, `cols`/`rows` in cells, `z`,
and the additive schema-1 fields `sx`,`sy`,`sw`,`sh` for the source rectangle in
image pixels, `ox`,`oy` for the device-pixel offset inside the first cell, and
`dw`,`dh` for the destination size in device pixels when it is not the cell
rectangle, as for Unicode-placeholder slices; the top-level `animating` flag is
true while a placed animation is playing);
unknown keys are ignored. Pixels do not travel in JSON: `akitty_image_read_v1(session,
image, out, capacity)` copies `w*h*4` RGBA bytes and returns the count, or 0 on
any error. Placements follow the text: scrolling (including scroll regions, RI,
IL/DL and a full scrollback buffer), ED, and reset move or delete them with the
content on the current screen. Alternate-screen images are removed when that
screen is left. Primary device attributes (`CSI c`) answer `CSI ? 62 ; 22 c` (VT220
with ANSI colour), which clients such as `kitten icat` use to end their graphics
probe. `CSI 16 t` (cell size in pixels) is answered from the cell size
the host reports via `cell_size`, and the kernel window size reports pixel
dimensions derived from it; `cell_size` also pushes a PTY resize so the ioctl
updates without a grid change. Before a host reports cell metrics, `CSI 14 t`
(window pixels) and `CSI 16 t` use 8×16 pixels per cell. `CSI 14 t` reports the
full dimensions even when they exceed 16-bit values; the kernel ioctl remains
clamped to its 16-bit fields.

**Program chrome.** A session holds one chrome document: a one-line status, a mark, a progress value, and an optional sprite. Two entries share one validator. A program sends `OSC 771` as `ESC ] 771 ; <json> BEL` or `ESC ] 771 ; <json> ST` (`ESC \`). The JSON is the document itself (no `op` or `id`). A host sends the same fields to `akitty_request_v1` as `{ "op": "chrome", "id", ... }`. `OSC 771` is removed from the byte stream before the terminal parser, including when it is rejected or its body exceeds 64 KiB, so it never appears as grid text. That cap applies only to `OSC 771`. Every other OSC sequence, including title `OSC 0` and `OSC 2` and a clipboard `OSC 52` whose base64 is larger than 64 KiB, passes through unchanged. The shell title stays the window title and the tab label; chrome text does not replace it. There is no video decoder and no plugin or script runtime.

Each accepted update replaces the whole document. Omitted fields clear the previous ones. `"clear": true` removes the document and skips the other checks. An empty update is an error and does not replace anything. A rejected update, from either entry, leaves the previous document in place. `OSC 771` that fails validation is consumed and reported only by leaving the document unchanged. The ABI returns `{ "ok": false, "error" }`.

`status` is `{ "text", "tone", "expires"? }`. `tone` is `info`, `warn`, or `error`. Control characters are removed from `text` and the result is capped at 128 characters. `expires` is a Unix time in milliseconds. When `expires` is already past at snapshot time, the status and the progress value are not current; the mark and the sprite stay until a later replace or clear. `mark` is `idle`, `busy`, `error`, or a frame index `0` through `3`. `progress` is a finite number from 0 through 1, or the string `"indeterminate"`.

`sprite` is `{ "w", "h", "frames" }` with `frames` holding standard Base64 of raw RGBA8, one entry per frame. The image is 1 through 32 pixels on each edge and contains 1 through 4 frames, each exactly `w * h * 4` bytes. A path, file, URL, URI, or shared-memory source is rejected, as is any `source` other than `rgba` or `inline`. Unknown fields are rejected. Sprite pixels travel inline in the snapshot; `akitty_image_read_v1` is only for Kitty graphics placements.

The snapshot includes `chrome` only while something is still current: `status` (`text`, `tone`), `mark`, `progress`, and `sprite` (`w`, `h`, `frames`). A partial snapshot carries the same object, so merging it keeps or drops chrome with the core rather than with the previous frame. While status or progress is current, the macOS pane shows that text and progress in place of the column count. The sprite is a title-bar mark, separate from the update reminder. Reduce motion shows sprite frame 0. Otherwise a frame-index mark shows that frame when it exists, and a named mark shows frame 0.

`{ "op": "program_chrome", "id", "enabled" }` is the host switch, also exposed as the setting "Allow programs to set the status bar". It defaults to on. When it is off, `OSC 771` is still consumed but does not change the document, and `chrome` from `akitty_request_v1` still does.

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

By default, every cell is a keyed object with `row`, `col`, `text`, `fg`, `bg`,
`bold`, `italic`, `underline`, `selected`, and `wide`. Colours are three-byte RGB
arrays. This remains the schema-1 format used by existing clients. Optional fields
are `ustyle` (1 single, 2 double, 3 curly, 4 dotted, 5 dashed), `ucolor` (RGB),
`strike`, `link`, `search`, and `active_search`. The last two mark visible literal
find hits and the active hit; absent boolean fields mean false.

A client may explicitly request `"compact": true` to receive positional cells:
`[row, col, text, fg, bg, attrs]`. The native app uses this faster format. Here `fg`
and `bg` are packed `0xRRGGBB` integers; `attrs` bits are 1 bold, 2 italic,
4 underline, 8 selected, 16 wide, 32 strikethrough, 64 search, and 128 active search.
Bits 8–10 hold the underline style (0 none, otherwise the values above). The
underline bit stays set for any style. Two optional elements follow only when set:
`ucolor`, the packed underline colour (`null` when only a link is present), then
`link`. Omitting `compact` or setting it to false always selects keyed cells,
including in partial snapshots.

`link` indexes the complete snapshot `links` array, which is present even when empty.
It holds at most 256 unique OSC 8 targets of at most 2,048 bytes with no control
characters; others are dropped. The core does not judge schemes: Swift opens only
http, https and mailto targets, and only on Command-click.

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
