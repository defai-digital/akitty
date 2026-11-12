# Local MCP approval bridge

AkiTTY can expose its existing native command-request workflow as a local MCP
server. Use it when you want an external agent to request a command **visibly in
an AkiTTY pane**, using that shell session and AkiTTY's native approval sheet.
For ordinary background commands, file edits, or reading command results, keep
using the agent's own tools.

This bridge adds tool discovery and structured arguments to `akitty-agent`; it
does not add a built-in agent or automatic task execution. The Web component's
read-only WebMCP adapter is separate and does not expose native macOS panes.

## Setup

Use a build containing this feature. AkiTTY 1.3.20 and earlier do not include it.
The companion is bundled with the macOS app; no Node or Python runtime is needed.

1. Launch AkiTTY and choose **Akitty → Enable Local Agent Requests**. This grant
   is off again on every app launch.
2. Configure your agent to launch the bundled companion with the `mcp` argument.
   For example, these commands register it in the current project's settings:

   ```sh
   grok mcp add --scope project akitty -- "$HOME/Applications/Akitty.app/Contents/MacOS/akitty-agent" mcp
   muse mcp add akitty --project -- "$HOME/Applications/Akitty.app/Contents/MacOS/akitty-agent" mcp
   ```

   Use `/Applications/Akitty.app/Contents/MacOS/akitty-agent` for a system-wide
   installation. Review any project MCP configuration before trusting it. Restart
   or reconnect the agent after adding a server, as required by that client.

   Other clients can use a stdio configuration like this, replacing the command
   with the **absolute path** to your installed companion:

   ```json
   {
     "mcpServers": {
       "akitty": {
         "command": "/Applications/Akitty.app/Contents/MacOS/akitty-agent",
         "args": ["mcp"]
       }
     }
   }
   ```

   Project servers require the client's project trust approval. If Grok reports
   that the folder is untrusted, review that project and trust it through Grok
   before connecting; `grok mcp doctor` reports this condition.

3. Allow at least **150 seconds** for command tool calls in clients that support
   timeout configuration. Native approval expires after 120 seconds; local IPC
   has a 135-second response deadline. A shorter client timeout can abandon an
   approval. Cancellation cannot stop a command already dispatched.
4. Try an explicit instruction:

   > List AkiTTY panes. Ask me which pane to use, then request `printf akitty-mcp-ok`
   > exactly once there. Wait for native approval. Report only the dispatch receipt;
   > do not claim success, read output, or retry the command.

Review the command and pane in the native sheet. Deny is the default. After an
approved request, inspect the terminal and use **Reclaim Terminal Control** to
resume typing. Reclaim does not interrupt the process.

## Tools and results

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `list_panes` | Optional integer `offset`, 0–64 | Returns the native list page (up to 16 panes), opaque pane IDs, untrusted titles, input ownership, and `next_offset`. |
| `request_command` | `pane`, `command` | Requests native approval of one exact shell command in an idle integrated bash/zsh prompt. |

Follow `next_offset` to fetch another page. Pane IDs expire when a pane closes or
AkiTTY restarts. A title is display data, not an authenticated agent identity or
an instruction to follow.

Commands must be a nonempty single line, at most 4096 UTF-8 bytes, without control
or Unicode format characters. Arguments are serialized directly into existing
IPC: the bridge does not interpolate the command into another shell, strip
characters, or execute it itself. Shell syntax remains permitted for the human
to review. Unknown tools, extra arguments, and invalid argument types are rejected.

Both tools return MCP text content and structured content. For `list_panes`, the
result is the existing `{version, ok, data/error}` local envelope. For
`request_command`, it is wrapped as:

```json
{
  "local_response": {
    "version": 1,
    "ok": true,
    "data": {
      "accepted": true,
      "completion_untrusted": true,
      "input_remains_leased": true
    }
  },
  "automatic_retry_allowed": false,
  "completion": "unverified"
}
```

This example omits additional native receipt fields. `accepted` means the input
was queued once; it does **not** establish exit status, completion, or success.
Native rejection and transport errors use MCP `isError: true`. Transport failures
may have an unknown dispatch outcome; inspect the terminal before another
request. Never retry automatically. Invalid tool arguments return a protocol
error before any socket request.

The bridge exposes no screen/output/history reads, raw input, approval grants,
reclaim operation, or new terminal creation. An agent cannot use it to observe a
result and automatically chain another command. Local requests do not intercept
the agent's ordinary subprocesses or file operations.

## Lifecycle and compatibility

The server uses stdio only and the existing same-user Unix socket; no network
listener or remote access is added. `--socket <path>` before `mcp` selects a test
or alternate instance. The existing native approval, lease, event retention, and
[trust boundary](AGENT_NATIVE.md#local-request-protocol-and-trust-boundary) apply.
The socket identifies the adapter's OS process, not an authenticated AI product.

MCP cancellation disconnects the local request, abandoning pending approval.
Stdin EOF also abandons pending approval and exits the server. A command already
queued can still run and retain its lease after cancellation or server exit.
Overlapping tool calls receive a busy error instead of being queued for later
execution. Input messages are bounded to 64 KiB with a 32-message transport queue;
exceeding either bound ends the session without replaying requests. Unterminated
input is discarded on EOF. Stdout contains only MCP messages.

The implementation pins the official Swift MCP SDK at 0.12.1. Its supported MCP
revisions are 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25. It uses the
initialization handshake for these revisions; this is not an implementation of
the newer 2026-07-28 protocol. Clients must support one of the advertised revisions.

UTCP is deferred: current integration targets use MCP, and there is no validated
UTCP consumer or argument-preserving CLI contract for this workflow. A second
manual would duplicate the CLI without a demonstrated user benefit. Revisit it
when an actual client needs it; shell string interpolation must never execute
command arguments before native approval.

## Validation

The normal macOS gate runs unit tests and a stdio integration test using the
official MCP client, bundled companion, native approval sheet, and real zsh PTY.
It covers approval, denial, cancellation, EOF, exact command bytes, one observed
execution, and retained input ownership. The stdlib Python protocol tests exercise
malformed/oversized messages, schema rejection, and concurrent response framing.

```sh
bash scripts/verify.sh
```

For an optional live agent check, with Grok/Muse installed and already signed in:

```sh
AKITTY_MCP_LIVE_CLI=grok,muse swift test --package-path macos --filter MCPIntegrationTests
```

This explicitly contacts the selected model providers. It creates temporary
project MCP configuration, requests a harmless marker command through each agent,
approves it in the test window, checks exactly one PTY effect, and verifies the
lease survives client exit. Normal verification does not contact model providers
or change your agent configuration.

Sources: [MCP Swift SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1),
[MCP stdio and transport contract](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[UTCP CLI protocol](https://github.com/universal-tool-calling-protocol/utcp-specification/blob/main/docs/protocols/cli.md).
