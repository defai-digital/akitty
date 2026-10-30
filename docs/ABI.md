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
| snapshot | id; optional since | Current snapshot or changed=false |
| input | id, text; optional paste | UTF-8 input with optional bracketed-paste protection |
| input_bytes | id, bytes | Raw byte input for terminal protocols, bounded to 64 KiB + delimiters |
| resize | id, cols, rows | Resize kernel PTY and terminal state in worker order |
| scroll | id, lines | Bounded scrollback movement |
| select | id, start_row, start_col, end_row, end_col | Visible cell coordinates; return selected text |
| find | id, text | Latest literal matching line in history; bounded query |
| feed | id, text | Parser input for headless sessions only |

Dimensions: 2–512 columns, 1–256 rows, at most 32,768 visible cells. At most 64
sessions and 5,000 scrollback lines per session. Input/reply queues are bounded.
Snapshots include authoritative Rust cell coordinates, colors, flags, cursor,
mode state, visible text, title, clipboard requests and lifecycle/error status.
Swift converts cells to UTF-16 offsets only for macOS text/accessibility APIs.

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
