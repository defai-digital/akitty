# AkiTTY terminal SDK

`@ax-code/akitty-sdk` is a dependency-free TypeScript/JavaScript client for programs
running **inside** a terminal, including AX Code TUI. It emits standard OSC 2/1
titles and AkiTTY's existing OSC 771 program chrome protocol. It does not load the
native library, create sessions, decode video, or render a terminal.

The C ABI remains the interface for hosts embedding the native terminal. AkiTTY
Web is a separate implementation; its identity alone does not establish OSC 771
support. Kitty graphics and ASCII/text animations in the terminal grid remain
with the application's existing renderer and graphics capability probes.

## Use

```ts
import { createSprite, createTerminalClient, detectCapabilities } from "@ax-code/akitty-sdk"

const client = createTerminalClient({
  capabilities: detectCapabilities(process.env, process.stdout.isTTY === true),
  write(sequence) {
    // In a TUI, enqueue this whole string through its renderer's serialized writer.
    // Node's false return means queued backpressure, not rejection.
    process.stdout.write(sequence)
    return true
  },
  reduceMotion: false,
})

client.setTitle("AX Code")
client.setStatus({ text: "Working", tone: "info" })
client.setProgress("indeterminate")
const sprite = createSprite(1, 1, [
  new Uint8Array([255, 0, 0, 255]),
  new Uint8Array([0, 0, 255, 255]),
])
client.playSprite({ sprite, intervalMs: 150 })
// On component teardown or normal exit:
client.dispose()
```

The injected writer returns **true if accepted**, false if rejected, and may
throw. The host owns serialization, stream health, backpressure and drain; the
SDK creates no output queue. Failed writes do not commit client state. There is
no terminal acknowledgement: accepted bytes do not prove the host displayed them.
Capability detection conservatively disables output on pipes, SSH and multiplexers.
For an explicitly supported host, inject capabilities rather than relying on an
inherited environment marker. It never grants Kitty graphics capability.

## State and bounds

- `setStatus`, `setProgress`, `setMark`, `setSprite` and `updateChrome` merge into
  one immutable document and emit the complete replacement. Omitted patch fields
  preserve state; `null` removes a field. `clearChrome` clears the whole document.
- Status is at most 128 Unicode scalars, with control characters removed. Title
  controls become spaces and titles are capped at 128 scalars. Status tones are
  `info`, `warn`, `error`; optional `expires` is Unix milliseconds.
- Progress is 0..1 or `indeterminate`. Marks are `idle`, `busy`, `error`, or a
  frame index 0..3. Sprite edges are 1..32 pixels, with 1..4 inline base64 RGBA8
  frames. Paths, URLs, unknown fields and malformed payloads are rejected.
- `playSprite` selects frame 0 immediately and cycles at an integer interval of
  50..60000 ms. Reduce motion and one-frame sprites never start a timer. Timers
  are unreferenced in Node. This is SDK-managed playback, not a native timeline.
- `stopSprite` leaves the last frame visible. Manual mark/sprite updates stop
  playback. Status/progress updates preserve playback. Replacement, clear and
  disposal invalidate already queued ticks. A failed animation write stops the
  timer; thrown errors go to `onError`, or rethrow if no handler was provided.
- `dispose` is idempotent, stops playback and attempts to clear owned chrome and
  title. Afterwards the client cannot emit again. It does not restore a prior
  application's title or status. Hosts need a separate best-effort crash reset.

Invalid inputs throw `RangeError` before writing. Public state and nested values
are frozen. The package exports compiled ESM and explicit `.d.ts` declarations;
there are no runtime dependencies or native binaries.

## Build and verify

```sh
npm ci --ignore-scripts
npm test
npm pack
```

Tests include an isolated packed consumer with declaration checks. The repository's
`scripts/verify.sh` also feeds actual SDK output through the native C ABI/parser,
checks snapshots and cleanup, and verifies that OSC payloads never enter the grid.
See [the protocol contract](../../docs/ABI.md).

## Trusted host command management (SDK 0.2.0 / native app 1.1.0)

The main import remains a program-side presentation client. It lets each program
show its own tab sprite/activity and background completion indicator, with text
and progress in the pane status line. Ordinary CLIs must integrate it explicitly.
It does not prove a command's execution or result.

A separate `@ax-code/akitty-sdk/host` entry is for trusted embedding hosts:

```ts
import { createCommandHost } from "@ax-code/akitty-sdk/host"

const host = createCommandHost({
  session: sessionId,
  // Return schema-1 data, after validating the ABI envelope. Transport and
  // caller authentication belong to your host, not the terminal output stream.
  request: requestNativeCore,
  approve: async request => showCommandApproval(request),
})
const receipt = await host.execute("coding-agent", "npm test")
// Poll history after receipt.afterCommandId, then read output by command id.
// Shell-reported completion and output are untrusted metadata.
const history = await host.history(receipt.afterCommandId)
// After reviewing completion, release explicitly; reclaim() is human takeover.
await host.release(receipt.lease)
```

The native `AgentCommandHost` offers the same policy boundary; the Mac view's
`runAgentCommand` presents a confirmation sheet. One exclusive agent lease blocks
human typing/paste/drop until release or **Edit → Reclaim Terminal Control**.
Approvals bind the exact command, session lease and displayed directory, expire
after 30 seconds and can be consumed only once. An integrated, unedited local
bash/zsh prompt is required. Shell completion never grants another approval.

The host policy callback can call an authenticated ax-trust adapter; none is
configured or deployed by this SDK. Never expose the transport directly to
terminal programs, remote agents or the read-only WebMCP tools. AkiTTY Web and
AX Code Desktop's PTY host must adopt/enforce their own integration separately.

`history`, `output` and `audit` return bounded pages. History retains 64 commands,
output the first 16 KiB per command (`output_base64`, `truncated`), and audit the
last 64 events with sequence cursors for loss detection. The host must persist
pages before eviction/close for durable auditing. Commands may contain secrets;
retention and access control belong to the host. A transport failure after dispatch
can mean the command already ran: do not blindly retry. See the complete
[host contract](../../docs/AGENT_WORKFLOWS.md) and [ABI](../../docs/ABI.md).
