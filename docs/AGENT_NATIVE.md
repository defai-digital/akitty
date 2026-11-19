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
   This is off at every app launch; it is not a persisted grant.
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

## Claude Code permission prompts

AkiTTY can answer Claude Code's own Bash permission prompts in its approval
queue. Claude Code still runs every command itself, under its own sandbox and
permission rules; AkiTTY returns only allow or deny and never types into the pane
or takes its input lease. This uses Claude Code's documented `PermissionRequest`,
`SessionStart` and `SessionEnd` hooks.

1. Choose **Akitty → Claude Code Integration…** and **Install**, or run
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
from the pane's PTY; the request cannot name a pane. A process outside every pane
is refused. When AkiTTY cannot answer (requests disabled, AkiTTY not running, a
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
Overview, and AkiTTY clears the line (Ctrl-U) and types `claude --resume <id>`
at that pane's prompt. The shell must be at an empty, idle integrated prompt
(nothing typed since it was drawn), and its input under your control. The Shell
menu item acts only on the pane with keyboard focus.
Each pane resumes its own ID, so several conversations in the same folder never
swap, and AkiTTY never picks "the most recent" one.

The resume is shown as **(resumed)** only when Claude Code reports the same
conversation ID from that pane (Claude Code 2.1.327 keeps the ID when resuming).
That report needs Claude Code Integration and Local Agent Requests on. Otherwise,
or if the CLI is missing, the conversation was deleted or the folder moved, Agent
Overview shows **(resume not confirmed)** after 30 seconds, or as soon as a
different conversation starts in that pane. The CLI's own output in the pane
says why, and you can choose Resume again; a later report of the same ID still
confirms it. Once resumed or never started, a different conversation in the pane
replaces the offer. Approvals that were waiting, earlier approvals and input
leases end with the app and are never replayed. Only Claude Code conversations
can be resumed so far.

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
regressions. `scripts/build-app.sh` bundles and audits both native executables.
Tests establish bounded behavior and observed effects, not complete terminal
conformance, multi-day stability, vendor hook compatibility or VoiceOver user
qualification. Native and Web share the Rust VT engine, while their rendering,
input and host integrations remain separate. Web and AX Code Desktop hosts do not
inherit this native request/approval service.
