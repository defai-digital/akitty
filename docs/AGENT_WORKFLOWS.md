# Shell integration and trusted host control

This reference covers three native contracts:

- [Program status](#program-status-osc-771): how a program shows its own title,
  status, progress, and tab sprite.
- [Local shell integration](#local-shell-integration): the bash and zsh hooks,
  what they report, and folder-aware zsh history.
- [Host control and approval](#host-control-and-approval): the lease and
  one-shot authorization contract for hosts that run commands in a pane.

The agent-facing features built on these contracts (OSC 7501 reports, local
command requests, approvals, and the event timeline) are in
[agent workflows](AGENT_NATIVE.md). None of them changes the trust boundary
below: status and shell observations are never execution authority or proof.

## Program status (OSC 771)

A program that integrates the [program SDK](../packages/akitty-sdk/README.md)
can give its tab a small sprite, an activity mark, and progress, and keep a
completion dot on a background tab until it is viewed. Status text and progress
appear in the pane's status capsule. The SDK writes OSC 771 through the
program's existing stdout writer; its only dependency is Zod. Ordinary CLI
programs are unchanged, and no status-bar script is installed.

**Settings → Keyboard → Allow programs to set the status bar** gates these
updates. Presentation is not proof that a command ran or succeeded.

AkiTTY Web is a separate implementation. It supplies bounded, read-only text
tools (`list_sessions`, `read_screen`, `read_output`) and an optional WebMCP
adapter, but it neither starts a PTY nor executes commands, and native OSC 771
support is not implied by the AkiTTY Web name. AX Code Desktop adopts source
changes and its own PTY, authorization, and lifecycle integration separately.

## Local shell integration

**Settings → Sessions → New Terminals → Shell integration (bash and zsh)** is on
by default. Only bash and zsh are integrated; any other shell starts as an
ordinary login shell. The app loads bundled resources and never edits a user
startup file. Hosts using the ABI pass an absolute `shell_integration_dir`
pointing at these trusted resources, or omit it to disable integration. The
hooks can also be sourced by hand in an interactive shell:
`source /path/to/shell-integration/akitty.zsh` (or `akitty.bash`).

### zsh startup

Zsh runs as an interactive login shell. A bundled ZDOTDIR `.zshenv` restores the
user's ZDOTDIR and sources their `.zshenv`, so the system and user `.zprofile`,
`.zshrc`, and `.zlogin` run as usual, and a system `compinit` or `HISTFILE`
default never writes into the app bundle. The hooks load at the first prompt,
after those files, from `precmd_functions`.

With `zsh/sched` available, a scheduled event emits OSC 133 A after the other
precmd hooks, so a hook waiting in `read` or `vared` finishes before the shell
reports readiness. The event preserves the command's exit status and supports
`KSH_ARRAYS`. Without `zsh/sched`, the integration emits readiness from its own
precmd hook. A `.zshrc` that replaces `precmd_functions` should source
`akitty.zsh` itself.

### bash startup

Bash uses an interactive `--rcfile` wrapper that sources `/etc/profile` and the
first user login profile; its `login_shell` flag is not set. A bashrc sourced by
that profile still runs normally.

- **DEBUG trap.** When bash-preexec (used by tools such as Atuin) is loaded
  first, the hooks join its `preexec_functions` and `precmd_functions` instead
  of taking the DEBUG trap. Any other existing DEBUG trap is preserved and
  integration is declined at the first prompt: quietly in app sessions, with a
  warning when the hooks are sourced by hand.
- **Prompt hooks.** Existing `PROMPT_COMMAND` hooks, including bash 5.1+ arrays,
  run once per prompt before the prompt is marked ready, and each sees the
  command's exit status as bash gives it. Hooks added later (a re-sourced rc
  file, a lazily loaded tool) are adopted at the next prompt; until then only a
  command that reaches history is recorded, so a hook is never reported as a command.
- **Subshell-only lines.** A line such as `(cd dir && make)` runs no DEBUG trap
  in the shell. Bash 4.4+ records it through `PS0` (appended to any existing
  `PS0`). Bash 3.2–4.3 has no `PS0`, so the hooks turn on functrace (`set -T`)
  when they own the DEBUG trap: the subshell inherits the trap and reports the
  line before its first command. Functrace also makes functions inherit DEBUG
  and RETURN traps; the hooks ignore commands run inside functions. A line such
  as `(a) | b` can then start twice, and the core keeps one record.
- **Lines that run nothing.** At the next prompt the shell restates a line that
  reached history without running a DEBUG trap (a comment, a function
  definition), so it is recorded with no output and a duration of the prompt
  turnaround. bash-preexec does not record subshell-only lines.
- **Command text.** When history omits a command, bash falls back to the first
  simple command, so a compound line may have partial descriptive text. Host
  approval and audit still bind the full requested command independently.

Prompt frameworks, custom traps, nested shells, and nonstandard startup
policies need separate checks.

### What the hooks report

Hooks emit OSC 133 A/B/C/D, OSC 7 directory URIs, and bounded OSC 772 base64
command text. They also set the OSC 2 title: the directory at each prompt (zsh
keeps the last three components, bash shows the home directory as `~`), and the
command text, with control characters removed, while it runs. Set
`AKITTY_SHELL_TITLE=0` to leave the title to your own hooks.

A command starts at C and ends at D. A missing D followed by a new prompt or
start marks it interrupted, with unknown exit status. Captured output is the
ordered raw byte stream between those boundaries, excluding intercepted shell
and chrome metadata; ANSI bytes remain, and stdout and stderr are not separated.
The core retains up to 64 records and 16 KiB per command; `truncated` reports
clipping and evicted IDs return errors. History and output report
`untrusted:true`. The shell child's exit code in a snapshot is distinct from
each observed command's exit status.

Every program in the PTY can forge these notifications. They support navigation
and result interpretation; they never prove execution, create approvals, change
ownership, or authorize host actions. SSH and tmux propagation is not configured
by this local integration, and SDK capability detection disables title and
chrome updates through SSH and multiplexers unless the host opts in.

### Folder-aware zsh history

zsh integration keeps a shared command history across folders, windows, and
sessions. Pressing Tab after a typed prefix lists the five most recent distinct
commands that start with it: those run in this folder first (by logical or
physical path), then other folders, newest first within each. Matching is
case-sensitive, and filtering and deduplication happen before the limit.

- **Keys.** Up/Down choose (the line previews the choice), Enter keeps it on the
  line without running it, Esc restores the prefix, Tab inside the list
  completes as usual, and any other key closes the list and is typed. Up/Down on
  a typed prefix cycle through up to twenty matches. With no match, each key
  runs the widget it was bound to after your startup files (compinit, fzf-tab,
  history search).
- **What is saved.** A line is saved only when zsh keeps it in history: your
  `zshaddhistory` hooks run once and decide first, and memory-only lines (hook
  status 2) are not persisted. `add-zsh-hook` can still remove and deduplicate
  hooks; replaced arrays and redefined functions take effect at the next prompt.
  Lines starting with a space, matching `HISTORY_IGNORE`, spanning several lines,
  or over 1 KiB are skipped. Native `.zsh_history` is not imported.
- **Storage.** Entries go to the owner-only file
  `~/Library/Application Support/Akitty/folder-history`
  (`AKITTY_FOLDER_HISTORY_FILE` overrides it with an absolute path) under a
  POSIX lock shared by shells and Settings. Files are compacted to at most
  512 KiB, and queries read at most that many bytes and the newest 3,000 rows.
  Symlinks, hard links, and files without owner-only permissions are refused,
  and a failed lock never permits an unlocked write. Shells without safe
  nonblocking opens (macOS ships zsh 5.9, which has them) keep native history
  with a warning.
- **Settings.** Turning the feature off sets `AKITTY_FOLDER_HISTORY=0` for new
  terminals (the core's `create.folder_history`). **Clear History** clears the
  file under the same lock. Legacy file names, environment variables, and
  preference keys remain compatible.

bash has no shared history menu: `bind -x` cannot hand Tab back to Readline
completion, and macOS bash 3.2 cannot edit the line from a key binding.
Implementation details are in [the architecture](ARCHITECTURE.md#zsh-command-history).

### Bash and zsh qualification

`scripts/test_shell_integration.py` runs the hooks in isolated interactive PTYs.
`AKITTY_TEST_BASH` and `AKITTY_TEST_ZSH` select other shell builds. CI runs it
with macOS bash 3.2, bash 5.1 and 5.2 on Ubuntu 22.04/24.04, and Homebrew bash
5.3 on macOS.

| Bash | Result | Subshell-only lines |
| --- | --- | --- |
| 3.2.57 (macOS) | pass | recorded (functrace) |
| 4.3.30 | pass, local only | recorded (functrace; also checked on 4.3.0) |
| 4.4.18 | pass, local only | recorded (`PS0`) |
| 5.1.16, 5.2.37, 5.3 | pass | recorded (`PS0`) |

The 2026-10-31 qualification fixed a defect reported on Linux bash 5.2, where a
second `PROMPT_COMMAND` array hook was recorded as the user's command. The zsh
ZDOTDIR wrapper was re-qualified on Ubuntu 26.04.1 with zsh 5.9, where an
earlier wrapper let `/etc/zsh/zshrc`'s `compinit` write `.zcompdump` into the
app bundle. macOS zsh 5.9 passes as well.

Remaining: on bash 3.2–4.3 functrace makes functions inherit RETURN traps, the
bash-preexec path keeps its own limits, and bash 4.3/4.4 run locally, not in CI.

## Host control and approval

Native embedders use `AgentCommandHost` or `TerminalView.runAgentCommand`, which
shows the native confirmation sheet. JavaScript hosts import
`@defai-digital/akitty-sdk/host` and supply an authenticated transport to the
native ABI, or to a host enforcing the same contract. This interface is separate
from the stdout status SDK and from the read-only Web tools.

1. Acquire one exclusive lease for an actor. Human input is rejected while leased.
2. Read the integrated, unedited prompt and reported directory. Ask the user or
   the host's authorization policy about the exact session, actor, command, and context.
3. On approval, mint one authorization bound to that session's lease, exact
   command, and directory. It expires after 30 seconds; replacing it revokes the older grant.
4. Dispatch the same command once. Replay, mismatch, a changed directory, an
   expired lease, or failed prompt checks reject execution. Dispatch consumes
   the grant even when queueing fails, so a retry requires fresh approval. A
   command is at most 4096 UTF-8 bytes on one line, without control characters;
   shell syntax is permitted because the complete command is what is approved.
5. Read history and output after the receipt's `after_command_id`. Shell
   completion is untrusted and does not release control or authorize the next
   command. Release the lease explicitly after reviewing results.
   **Edit → Reclaim Terminal Control** revokes the agent lease and any
   outstanding grant; it does not kill the running process.

The C ABI is a trusted embedding boundary, not an authentication endpoint. Do
not expose its approval or control operations to terminal programs, browser
agent text, remote callers, or the public read-only tools. A host service must
authenticate callers and enforce its approval policy before reaching this API.
The JavaScript `approve` callback is the integration point for an
ax-trust-backed policy; this repository does not include an ax-trust
deployment. The native UI remains the local approval authority.

Audit events have monotonic session-local sequence numbers and timestamps,
bounded to 64 entries, with oldest/last cursors for loss detection. They cover
acquisition, authorization, denial, dispatch or failure, untrusted shell
completion, blocked human input, release, and reclaim. Commands can contain
secrets, so the host controls access and retention. The records disappear when
the session closes; durable or organization-wide auditing needs a host sink.
A transport failure after dispatch is an uncertain outcome: never blindly retry.

**Agent Overview** reads only these snapshot fields (control lease, program
reports, shell directory, exit state), never terminal text. It cannot approve,
execute, or send input. See [agent workflows](AGENT_NATIVE.md#set-up-an-agent)
and [accessibility](ACCESSIBILITY.md#agent-overview).

## Quick Terminal and drops

**Shell → Toggle Quick Terminal** shows or hides a persistent terminal window.
Settings → Keyboard offers three global shortcut combinations; a registration
conflict is shown in Settings and the existing shortcut stays registered. The
window appears in the current Space on the display under the pointer, including
alongside full-screen apps where macOS permits it. Hiding it (shortcut, menu, or
close button) keeps its PTYs, tabs, and scrollback and restores the previous
app's focus. Exiting the last shell closes it; showing it again creates a new
session. Quitting the app keeps the usual live-session confirmation and bounded
cleanup, including hidden Quick Terminals.

Dropping local files or folders into a pane inserts POSIX-shell-quoted absolute
paths with no trailing newline (up to 64 items / 64 KiB). Plain text drops use
paste protection, so control or multiline text follows the paste-confirmation
preference. Remote file URLs and mixed file/text items are rejected, and an
agent's input lease blocks drops until you reclaim the pane. A Dock or
application drop opens a folder window or offers to run an eligible program.
[Open folders and programs](USER_GUIDE.md#open-folders-and-programs)

## Validation boundary

`scripts/verify.sh` covers the native ABI, real local bash and zsh PTYs,
lease and approval regressions, Swift UI policies, and Web tests. Playwright
runs Chromium, Firefox, and WebKit on macOS, and the workflow adds Ubuntu and
Windows browser jobs. These are component tests, not proof of AX Code Desktop's
packaged PTY, physical IME, every OS and font combination, accessibility, or
multi-day stability.
