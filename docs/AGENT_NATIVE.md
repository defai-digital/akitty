# Native agent workflows

Introduced in 1.3.0, these native workflows make program
activity visible and input ownership explicit. Supported execution requests
remain subject to human approval. No AX product or cloud account is required.

## Responsibilities and scope

| Component | Responsibility |
| --- | --- |
| AkiTTY UI | Terminal UX, report presentation, approval and human input reclaim |
| Native trusted host | Validates the local request, acquires input control, binds and dispatches an exact one-shot authorization |
| Local event store | Bounded metadata, sources, command fingerprints, retention/gap markers and human export |
| Optional future policy provider | Policy decisions under an explicit command-operation contract |
| Optional future evidence integration | Correlates executor observations and independent validation results |

The existing ax-trust governance contract concerns `llm://` resources; it is not
an installed shell-command policy engine. AX Code evidence records its own runtime;
third-party events need an explicit integration. Neither integration is required or
claimed here. Cloud orchestration and a remote/persistent PTY server are deferred.

## Observe programs

AkiTTY accepts [OSC 7501 revision 0.4](https://www.superlogical.com/rex/docs/build/program-status)
independently of OSC 771. A program can report `idle`, `working`, `blocked`, `done`
or `error`, with hierarchy, app identifier, description and progress. `clear` removes
a record subtree. Reports are not authenticated identities or verified results.

The pane status line prioritizes OSC 7501 reports, then falls back to OSC 771 text.
Tabs show reported waiting, failure, completion or work. OSC 771 sprites remain
available while work is reported. Agent Overview separates program reports,
host input ownership, the execution-request entry and the shell's state. Its
execution column does not imply interception of ordinary program operations.

The existing **Allow programs to set the status bar** preference gates new OSC
7501 reports and capability replies as well as OSC 771 updates. Existing records
retain their normal lifecycle. Protocol details are in [ABI.md](ABI.md).

## Request a command from a local agent

1. In the running native app, choose **Akitty → Enable Local Agent Requests**.
   This is off at every app launch unless you choose **Turn on when AkiTTY
   starts** in **Settings → Agents** (off by default).
2. Use the bundled companion to list panes:

   ```sh
   "$HOME/Applications/Akitty.app/Contents/MacOS/akitty-agent" list
   ```

3. Choose the opaque `pane` value (`<launch-id>/<number>`, copied exactly as
   printed), then request the complete shell command:

   ```sh
   "$HOME/Applications/Akitty.app/Contents/MacOS/akitty-agent" request '<pane-id>' 'git status'
   ```

4. Review the exact command, target terminal and unverified shell directory in the
   native sheet. Deny is default. Long commands have selectable, scrollable text.
   Requests require an integrated, unedited local bash/zsh prompt; a pane occupied
   by a TUI, password prompt or other foreground work is not a supported target.
5. An accepted receipt means the bytes were queued once, not that the command
   succeeded. Review the terminal, then **Reclaim Terminal Control**. Input remains
   leased until human reclaim or an explicit trusted-host release. Reclaim does
   not stop the command; interrupt or close the pane separately when necessary.

Any agent able to run the companion can use this opt-in path without changing its
core. For example, ask an agent to list AkiTTY panes, select an idle integrated
shell and submit a command through `akitty-agent request`. This is an adapter
example, not automatic interception or a claim of vendor-certified integration.
The same agent's normal subprocesses and file tools remain outside this path.

### Several agents at once

Requests for different panes wait in one approval queue. Each pane keeps its own
first-in, first-out list of at most 8 requests, and AkiTTY holds at most 64 in
total; a request beyond either limit is refused with that reason and nothing is
queued. Only a pane's oldest request is shown. One window shows one sheet at a
time, so split panes in the same window take turns. A queued request holds no
input lease: the pane stays usable until its sheet appears, and the shell must be
an idle integrated prompt at that moment. After an approved command, the pane
stays leased until you reclaim it; its next request waits for that (still within
its 120 seconds) instead of failing.

A request may name another pane than the one its program runs in, for example an
agent in one pane asking for a command in an idle shell pane. It queues on the
pane it names, and the sheet says where it came from and where it runs:
**Requested by a program started in this pane** (and that it runs there),
**… started in another pane, Terminal N** (and that it runs in the named pane, not
the requesting one), or **Requested by a program outside every AkiTTY pane**.
Program-set titles are not shown there, since any program can set one. The
source is the pane whose terminal the caller, or its nearest ancestor with a
terminal (up to 16 levels), uses, as for hooks, never what the request says, so
a server an agent started counts as that agent's pane. The event timeline records
`source_pane_session_id`, or `source: outside_panes`.

The first visible approval brings its window forward. While one approval is on
screen, later ones attach to their own windows without taking focus; the app asks
for attention instead. **Agent Overview** lists each pane's waiting count and the
oldest wait in **Approvals (host)**, and **Show Terminal** opens the pane with its
sheet. Every request expires 120 seconds after it was queued. Waiting does not
extend that time; when less than 10 seconds would remain for review, the request
expires as `expired` instead of showing a sheet.

Pass `--id <request-id>` (1–64 letters, digits, `.`, `_`, `:` or `-`) to choose
the request's ID; otherwise AkiTTY assigns one. Replies to a request carry
`request_id` once it is known: the assigned ID, or a valid ID the caller supplied. Reusing an ID in the same launch never queues or dispatches again,
even after the first request finished. `akitty-agent status <request-id>` reports
`queued`, `awaiting_approval`, `dispatched`, `denied`, `expired`, `cancelled`,
`failed` or `outcome_unknown` (a permission decision ends as `allowed` or `denied`), with the pane and queue position; it never
returns the command or its fingerprint. `dispatched` means input was queued, not that the command succeeded.
The most recent 256 finished requests are kept in memory only and end with the
app; caller-chosen IDs stay reserved for the whole launch even after their status
is gone. IDs are not secrets: any same-user process can query or reuse a
guessable ID such as `job-1`, so prefer a random one such as a UUID.

List pages contain at most 16 panes. If `next_offset` is an integer, use
`akitty-agent list <offset>` to fetch the next page. Pane identifiers are scoped
to the running app instance and become invalid after restart. A request for a
closed pane, or an identifier from an earlier launch, fails with a message to run
`list` again; older builds printed `\/` inside identifiers, which is still accepted. `--socket <path>`
before the subcommand selects a different local test/instance endpoint.

## Agent integrations

**Settings → Agents** (**Akitty → Agent Integrations…**) lists Claude Code, Codex
and AX Code. For each it shows where the CLI was found (the inherited PATH, then
the usual install folders such as `~/.local/bin` and `/opt/homebrew/bin`), the
version `--version` prints, and what AkiTTY offers: status and conversation
reports, Bash command approval, and resuming a conversation by ID. A missing CLI
links to its install instructions. **Install**, **Reinstall** and **Remove**
change only AkiTTY's hook entries and apply at once. **Connected** shows the
newest conversation the agent reported from an open pane, which confirms the
integration works. For AX Code, **Install** adds AkiTTY's MCP server (`akitty`,
running `akitty-agent mcp`) to `~/.config/ax-code/ax-code.json`
(`$XDG_CONFIG_HOME/ax-code`), or run `akitty-agent ax-code-mcp install`. AX Code
merges that plain-JSON file with the commented `ax-code.jsonc` people edit, so
AkiTTY never rewrites the commented file; a server named `akitty` that AkiTTY did
not add is never replaced or removed. AX Code then asks for commands through the
MCP `request_command` tool, and each waits in the approval queue. **Install**
also writes a small AX Code plugin, `~/.config/ax-code/plugin/akitty.js`, whose
`event` hook starts `akitty-agent ax-code-report start|end <id>` when a
conversation is created or becomes busy, is deleted, or AX Code exits. A fork you
continue is reported; a sub-agent session, which runs while its parent is busy,
is not. The companion finds the pane from its terminal, as
for hooks. A `plugin/akitty.js` AkiTTY did not write is never replaced or
removed. AX Code has no permission hook, so its own approval prompts stay in
AX Code. AX Code 7.31.2 connects to the server (`ax-code mcp list` shows `akitty
connected`) and loads the plugin, which reported start and end for a real
`ax-code run`.

**Turn on when AkiTTY starts** (off by default) turns Local Agent Requests on at
launch, so integrations work without the menu each time. **Turn On** / **Turn
Off** changes it for the running app. Every command still needs approval.

## Claude Code permission prompts

AkiTTY can answer Claude Code's own Bash permission prompts in its approval
queue. Claude Code still runs every command itself, under its own sandbox and
permission rules; AkiTTY returns only allow or deny and never types into the pane
or takes its input lease. This uses Claude Code's documented `PermissionRequest`,
`SessionStart` and `SessionEnd` hooks.

1. In **Settings → Agents** (**Akitty → Agent Integrations…**), choose
   **Install** under Claude Code, or run
   `akitty-agent claude-hooks install`. This adds three hooks that run
   `akitty-agent claude-hook` to `~/.claude/settings.json`. Enabling twice keeps
   one copy; other settings and hooks stay. The file must be a JSON object whose
   `hooks` entries are lists; anything else is reported and left unchanged. A
   symlinked file is written through, and its permissions are kept. The file is
   reformatted with sorted keys, and the edit is not locked against another
   program writing it at the same moment. The first change saves the original as
   `settings.json.akitty-backup`. **Remove** (`claude-hooks uninstall`) deletes only
   AkiTTY's entries; `claude-hooks status` reports `installed`, `partial` or
   `notInstalled`. `--settings <path>` selects another file. Restart running
   Claude Code sessions to load the change.
2. Enable Local Agent Requests. Start Claude Code in an AkiTTY pane.
3. A Bash permission prompt appears as an **Allow Once** / **Deny** sheet on that
   pane, queued with the pane's other requests. Deny is default. The command may
   span lines; the directory and reason are what Claude Code reported.

The pane is found from the hook process's controlling terminal, which it inherits
from the pane's PTY; the request cannot name a pane. A hook started in a new
session has no terminal (Codex starts hooks that way), so AkiTTY uses the nearest
ancestor process that has one: the agent running in the pane. Each ancestor must
have started no later than its child, so a reused PID is never followed. A
process outside every pane is refused. When AkiTTY cannot answer (requests disabled, AkiTTY not running, a
non-Bash tool, an empty command, one over 4096 bytes or with control characters
other than line breaks and tabs, unreadable hook input, a full queue, the
120-second lifetime expired, or the pane, its window or the caller went away),
the hook prints nothing and Claude Code shows its own
prompt. A human **Deny** is final: it is returned to Claude Code as a denial, not
retried another way. The hook's 150-second timeout exceeds AkiTTY's deadlines.

`SessionStart` reports the conversation ID, which **Agent Overview** shows under
**Agent session (reported)**, marked ended after `SessionEnd`. Any program in the
pane could send such a report, so it is labeled unverified. The event timeline
records `permission_requested`, `permission_allowed` and `permission_denied` with
a command fingerprint, never the command.

| Request | Fields |
| --- | --- |
| Decide | `{"version":1,"op":"decide","agent":"claude-code","tool":"Bash","command":"…","cwd":"…","reason":"…"}`; `cwd`, `reason`, `request_id` optional. Returns `{decision, request_id, executor, akitty_sent_input: false}` with `decision` `allow` or `deny` |
| Report | `{"version":1,"op":"report","agent":"claude-code","event":"session_start","session_id":"…"}`; `event` is `session_start` or `session_end` |

`agent` is `claude-code` or `codex`.

## Codex permission prompts

Codex uses the same hook contract, so the same queue answers its Bash
permission prompts, such as a command that asks to run outside Codex's sandbox.
Codex still runs the command under its own sandbox and approval policy, and
AkiTTY never types into the pane. `apply_patch`, MCP tools and network approvals
stay with Codex's own prompt.

1. In **Settings → Agents**, choose **Install** under Codex, or run
   `akitty-agent codex-hooks install`. This adds the same three hooks, running
   `akitty-agent codex-hook`, to `$CODEX_HOME/hooks.json` (default
   `~/.codex/hooks.json`), with the installer behavior described above; the
   first change saves `hooks.json.akitty-backup`. `SessionEnd` uses Codex's
   3-second maximum, and session reports wait at most 1.5 seconds for AkiTTY.
   Apps opened from the Finder do not see a `CODEX_HOME` set in your shell; if
   you set one, run the command from that shell. A relative `CODEX_HOME` is
   ignored with a warning.
2. In Codex, run `/hooks` and trust the new hooks. Codex skips new or changed
   hooks until they are trusted, so until then it shows its own prompts.
3. Enable Local Agent Requests and start Codex in an AkiTTY pane.

The sheet shows the command, its folder and Codex's reason
(`tool_input.description`) when Codex gives one. Agent Overview shows the
conversation ID Codex reports, and a restored workspace resumes it with
`codex resume <id>` (Codex 0.170.0 keeps the ID when resuming). The hook
contract follows Codex's published hooks documentation; it has not been
qualified end to end against a running Codex with trusted hooks.

## Reopen windows and resume agent conversations

**Shell → Window Layouts → Reopen Windows and Agent Conversations at Launch**
(off by default) saves the open windows, tabs, splits and each pane's folder,
plus the last conversation ID an agent reported in that pane. AkiTTY saves when
an agent reports a conversation, every 30 seconds, and when you quit, so a crash
or forced quit keeps the most recent save. No terminal text, command, prompt or
approval is saved. Closing the last window while AkiTTY keeps running keeps the
previous save. **Clear Saved Workspace** removes the save and turns the option
off, so the next autosave cannot write it back.

At the next launch the windows reopen with fresh shells. Each pane that had a
conversation shows a line naming it, and Agent Overview marks it
**(can resume)**. Nothing starts on its own. Choose **Shell → Resume Agent
Conversation** for the focused pane, or **Resume Conversation** in Agent
Overview, and AkiTTY clears the line (Ctrl-U) and types the agent's resume command
with that ID at the pane's prompt. The shell must be at an empty, idle integrated prompt
(nothing typed since it was drawn), and its input under your control. The Shell
menu item acts only on the pane with keyboard focus.
Each pane resumes its own ID, so several conversations in the same folder never
swap, and AkiTTY never picks "the most recent" one.

The resume is shown as **(resumed)** only when the agent reports the same
conversation ID from that pane (Claude Code 2.1.327 keeps the ID when resuming).
That report needs the agent's integration and Local Agent Requests on. Otherwise,
or if the CLI is missing, the conversation was deleted or the folder moved, Agent
Overview shows **(resume not confirmed)** after 30 seconds, or as soon as a
different conversation starts in that pane. The CLI's own output in the pane
says why, and you can choose Resume again; a later report of the same ID still
confirms it. Once resumed or never started, a different conversation in the pane
replaces the offer. Approvals that were waiting, earlier approvals and input
leases end with the app and are never replayed. Conversations of three agents
can be resumed: Claude Code with `claude --resume <id>`, Codex with
`codex resume <id>`, and AX Code with `ax-code --session <id>`.

## Local request protocol and trust boundary

The optional [local MCP bridge](MCP.md) exposes these same list/request operations
through `akitty-agent mcp`. It adds no native authority, output access, or automatic
retry. Pending approval is abandoned when the MCP call is canceled or stdin closes.

`AgentIPC` is a separate native transport library, not the core ABI. The socket is
`~/Library/Application Support/Akitty/agent/requests.sock`. Its directory is 0700,
the socket and ownership lock are 0600, and the server checks kernel peer UID and
PID. One server instance holds the ownership lock. No TCP/HTTP listener is created.

Same-user local processes may **ask**, not grant permission. The PID identifies
the process that opened the connection; it does not attest the current executable,
Agent brand, or who subsequently holds a passed descriptor. There is no per-client
enrollment policy. A user approval is required for every command. These controls
are not an OS sandbox or protection against same-user programs that already have
Accessibility permission or equivalent control of the app/PTY/filesystem.

Each connection carries one length-prefixed UTF-8 JSON request and response: a
4-byte unsigned big-endian length, then 1..16384 bytes. A full incoming frame has
a 3-second deadline. Keep both directions open until the reply; half-closed writes
are deliberately treated as canceled requests. Pending approval expires 120 seconds
after it was queued and is canceled on disconnect, pane removal or disabling the
service. Up to 72 connections are handled at once. A request beyond the 64-request
queue limit is refused at once and does not keep its connection, so at least 8
remain for list and status. Extra connections get a busy rejection
after their bounded frame is consumed, so closing cannot reset a client still writing.
An extra connection that supplies an invalid frame or stalls beyond one second is
closed without dispatch or a reply. After a sheet closes, its window waits
3 seconds before showing the next one, so a click meant for one approval cannot
land on the next. Failure is
reported; no request is automatically retried.

| Request | Fields |
| --- | --- |
| List | `{"version":1,"op":"list","offset":0}`; offset optional, 0..64 |
| Request | `{"version":1,"op":"request","pane":"<opaque-id>","command":"git status","request_id":"job-1"}`; `request_id` optional |
| Status | `{"version":1,"op":"status","request_id":"job-1"}` |

Unknown fields/operations and boolean versions are rejected. Commands are at most
4096 UTF-8 bytes, one nonempty line without control or Unicode format characters.
Shell syntax is permitted: approval concerns the entire string, not a command-name
allowlist. A response is `{version:1,ok:true,data:...}` or
`{version:1,ok:false,error:...}`. No core lease/grant, raw input, reclaim, screen,
history or audit-read endpoint is exposed. The CLI exits zero only for `ok:true`.

The host uses existing exact-command/lease/directory binding and issues the
30-second grant only after approval. A transport failure after dispatch may mean
the command ran. Missing/invalid execution receipts are reported as unknown, leave
input leased, and require human inspection; never blindly resubmit.

Shell readiness, directory and completion signals can be forged by PTY programs.
They do not establish the foreground process or a verified execution result. The
receipt is specifically an input-dispatch receipt, not execution attestation.

## Timeline, storage and export

Choose **Akitty → Agent Event Timeline** to inspect retained local events, or
**Export Agent Events** for JSONL. Recording runs locally while the app runs, even
when local requests are disabled. It never makes the PTY session persistent.

The private `~/Library/Application Support/Akitty/agent-events/` directory uses
0700 permissions and 0600 regular, non-symlink, single-link files. A writer lock
prevents multiple app instances from rotating the same store. Two segments retain
at most 4 MiB each; older segments are discarded with a retention marker. Individual
events are at most 8 KiB. An incomplete final line is removed before the next append
with a loss marker. Core-ring eviction is recorded as a source gap. Polling can
miss intermediate program reports, so this is not a complete activity transcript.

Records include schema version, recorder instance, sequence, timestamp, a durable
session UUID, event, source and bounded fields. Sources are `host`,
`program_untrusted` or `shell_untrusted`. Core event sequence/time are retained.
Command contents, raw terminal output, status messages and directories are not
persisted; command text is replaced with SHA-256 and byte length. These unsalted
fingerprints permit correlation and dictionary guesses; they are not strong
secret anonymization. The existing in-memory core audit still contains commands.

The store survives app exit but is locally editable, bounded and incomplete. It
does not establish tamper resistance, non-repudiation, complete observation, or
semantic success. AX Code replay integration and independent result validation
remain separate work. Exports contain the same fingerprinted metadata, not a
re-executable command stream. Treat exported actor labels as descriptive host data.

If recording fails, the Timeline menu shows a warning and subsequent managed
requests fail closed. Restore storage and restart AkiTTY; failure remains latched
for that app run because prior observations may be missing. An accepted command
followed by recording failure is reported as uncertain rather than retried.

## Acceptance and remaining qualification

The canonical `scripts/verify.sh` includes parser/ABI conformance, native socket,
actual zsh PTY approval and denial, input reclaim, record rotation and file-safety
regressions. `AgentAcceptanceTests` covers the multi-agent release cases: 8 panes
each sending 8 requests (each admitted to its pane's queue, which Agent Overview
counts, with a p95 of about 30 ms from submission on the development Mac against
a 250 ms target; the 65th refused as full; an unanswered pane never holds up the
others), three panes answered out of order with a real
zsh dispatch that runs exactly once, and a request from one pane for another.
`AgentLiveTests` (opt-in: `AKITTY_LIVE_AGENTS=1 AKITTY_LIVE_AXCODE_MODEL=<model>`)
runs the installed Claude Code, Codex and AX Code at once in real panes: Claude
Code's and Codex's permission prompts (Codex with AkiTTY's hooks, trusted for
that run only) and AX Code's MCP request are answered through AkiTTY, each
command runs, and all three report their conversations. It changes no global
agent configuration. `AgentAccessibilityAuditTests` walks the accessibility tree
of the approval sheets (names of every control, the source and target panes, the
whole command, Deny as default). A VoiceOver user session, including Settings →
Agents, is still outstanding. `scripts/build-app.sh` bundles and audits both native executables.
Tests establish bounded behavior and observed effects, not complete terminal
conformance, multi-day stability, vendor hook compatibility or VoiceOver user
qualification. Native and Web share the Rust VT engine, while their rendering,
input and host integrations remain separate. Web and AX Code Desktop hosts do not
inherit this native request/approval service.
