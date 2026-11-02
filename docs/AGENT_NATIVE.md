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

3. Choose the opaque `pane` value, then request the complete shell command:

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

List pages contain at most 16 panes. If `next_offset` is an integer, use
`akitty-agent list <offset>` to fetch the next page. Pane identifiers are scoped
to the running app instance and become invalid after restart. `--socket <path>`
before the subcommand selects a different local test/instance endpoint.

## Local request protocol and trust boundary

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
are deliberately treated as canceled requests. Pending approval expires after
120 seconds and is canceled on disconnect, pane removal or disabling the service.
Only one connection is dispatched at a time. Extra connections get a busy rejection
after their bounded frame is consumed, so closing cannot reset a client still writing.
An extra connection that supplies an invalid frame or stalls beyond one second is
closed without dispatch or a reply. A
3-second cooldown after a prompt prevents repeated focus stealing. Failure is
reported; no request is automatically retried.

| Request | Fields |
| --- | --- |
| List | `{"version":1,"op":"list","offset":0}`; offset optional, 0..64 |
| Request | `{"version":1,"op":"request","pane":"<opaque-id>","command":"git status"}` |

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
qualification. The native/Web terminal implementations remain separate; Web and
AX Code Desktop hosts do not inherit this service.
