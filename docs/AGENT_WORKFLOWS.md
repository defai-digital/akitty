# Program identity, shell observations, and trusted host control

This document describes the native workflow and SDK host additions in AkiTTY 1.1.0.
The separate Web terminal and its embedding host retain their own adoption and release process.

Post-1.2.5 source development adds [OSC 7501 reports, local execution requests and
bounded durable event metadata](AGENT_NATIVE.md). These do not change the trust
boundary below: status and shell observations are not execution authority or proof.

## Product strengths and scope

The native app's distinctive workflow is **per-program tab identity**: an integrating
program supplies a small sprite, activity and progress, and a background completion
dot remains until that tab is viewed. Status text and progress appear in the pane;
the tab shows the activity mark/sprite and completion indicator. This uses the
existing stdout writer, OSC 771, and the SDK's main entry (its only dependency is Zod). Programs
must integrate it; ordinary CLI applications are unchanged. No status-bar Python
script needs installing. Presentation is not proof a command ran or succeeded.

Generic progress, status displays and automation are not exclusive capabilities:
[Ghostty 1.2 added OSC 9;4 progress](https://ghostty.org/docs/install/release-notes/1-2-0),
while iTerm2 offers a [scriptable status bar](https://iterm2.com/documentation-status-bar.html)
and [Python API](https://iterm2.com/python-api/). We do not claim competitors cannot
reproduce this combination or that AkiTTY is a universal replacement.

AkiTTY Web supplies ready-made bounded text tools (`list_sessions`, `read_screen`,
`read_output`) and an optional WebMCP adapter. The browser and host must support
and register them. This is Web-only and read-only. The private Web source package
neither starts a PTY nor executes commands; native OSC 771 support is not implied
by the AkiTTY Web name. AX Code Desktop must adopt source changes and its own PTY,
authorization and lifecycle integration separately.

## Local shell integration

**Settings → Sessions → Shell integration** is on by default for new terminals and
can be turned off there (preferences saved before 1.2.0 held the old off default and
move to on once). Only bash and zsh are integrated; the app starts any other
shell as an ordinary login shell and does not pretend it is integrated. The app loads bundled resources;
no user startup file is edited. Hosts using the ABI supply an absolute
`shell_integration_dir` pointing at these trusted resources, or omit it to disable.
The resources can also be explicitly sourced in an existing interactive shell:
`source /path/to/shell-integration/akitty.zsh` (or `akitty.bash`).

Zsh runs as an interactive login shell. A bundled ZDOTDIR `.zshenv` restores the
user's ZDOTDIR and sources their `.zshenv`, so the system and user `.zprofile`,
`.zshrc` and `.zlogin` run as usual (a system `compinit` or `HISTFILE` default never
writes into the app bundle); the hooks load at the first prompt, after those files, from
`precmd_functions`. A `.zshrc` that assigns that array instead of appending to it drops
the loader and should source `akitty.zsh` itself. Bash uses an interactive `--rcfile` wrapper and explicitly sources
`/etc/profile` and the first user login profile; its `login_shell` flag is not set.
A bashrc sourced by that profile still runs normally. When bash-preexec (used by
tools such as Atuin) is loaded before the hooks, as it is from any startup file in an
app session, the hooks join its `preexec_functions`/`precmd_functions` instead of
taking the DEBUG trap. Any other pre-existing DEBUG trap is preserved and integration
is declined at the first prompt: quietly in app sessions, with a warning when the
hooks are sourced by hand. Prompt frameworks,
custom traps, nested shells and nonstandard startup policies need separate checks.
Existing bash prompt hooks, including bash 5.1+ `PROMPT_COMMAND` arrays, run once
per prompt before the prompt is marked ready, and each sees the command's exit status
as bash gives it. Hooks added to `PROMPT_COMMAND` later (a re-sourced rc file, a
lazily loaded tool) are adopted at the next prompt; until then only a command that
reaches history is recorded, so a hook is never reported as a command. A line that
is only a subshell, such as `(cd dir && make)`, runs no DEBUG trap in the shell; bash
4.4+ records it through `PS0` (appended to any existing `PS0`) when it reaches history.
Bash 3.2–4.3 has no `PS0`, so the hooks turn on functrace (`set -T`) when they own the
DEBUG trap: the subshell inherits the trap and reports the line before its first
command, and the shell ends it at the next prompt. Functrace also makes functions
inherit DEBUG and RETURN traps; the hooks ignore commands run inside functions. A
line such as `(a) | b` can then be started by the subshell and again by the shell.
At the next prompt the shell restates a line that reached history but ran no DEBUG
trap in the shell itself, and the core keeps one record when the same command starts
again before a prompt; a line that runs no command (a comment, a function definition)
is therefore recorded as well, with no output and a duration of the prompt turnaround.
bash-preexec does not record subshell-only lines when the hooks join it. The hooks are tested with bash 3.2, 4.3, 4.4 and 5.1–5.3. When history omits a command, bash
falls back to the first simple command text; a compound line may therefore have
partial descriptive text. Host approval/audit still binds the full exact requested
command independently of this untrusted shell description.

Hooks emit OSC 133 A/B/C/D, OSC 7 directory URIs and bounded OSC 772 base64 command
text. Like Ghostty's title feature, they also set the OSC 2 title: at each prompt the
directory (zsh keeps the last three components, bash shows the home directory as `~`),
and while a command runs its text, with control characters removed. `AKITTY_SHELL_TITLE=0`
in the environment leaves the title to the user's own hooks. A command starts at C and ends at D; missing completion followed by a new
prompt/start marks it interrupted. A missing D has unknown exit status. Captured
output is the ordered raw terminal byte stream between these boundaries, excluding
intercepted shell/chrome metadata; ANSI bytes remain. It is not separated stdout
and stderr, and is not a durable transcript. Retain up to 64 records and 16 KiB per
command; `truncated` reports clipping and evicted ids return errors. History metadata
and output explicitly report `untrusted:true`. The shell child's exit code in a
snapshot remains distinct from each observed command's exit status.

zsh integration also keeps a shared command history across folders, windows and sessions.
Pressing Tab at the end of a typed prefix lists the five most recent distinct commands that
start with it: those run in this folder first (by its logical or physical path), then matches
from other folders, newest first within each. Prefix matching is case-sensitive; filtering and
deduplication happen before the five-result limit. Record order breaks timestamp ties.
Up/Down choose (the line previews the choice), Enter keeps it on the line without
running it, Esc restores the prefix, Tab inside the list completes as usual, and any other
key closes the list and is typed. Up/Down on a typed prefix step through the same matches.
With no match, each key runs the widget it was bound to after the user's startup files
(compinit, fzf-tab, history search). Up/Down outside the menu can cycle through up to twenty
recent matches. Existing stored commands are reused; native `.zsh_history` is not imported.

A line is saved only when zsh itself keeps it in history: the user's `zshaddhistory`
hooks run once and decide first; memory-only lines (hook status 2) are not persisted.
Hook names and ordering remain visible to native registration, so `add-zsh-hook` can
remove and deduplicate them. Replaced arrays and redefined functions take effect at
the next prompt; autoloaded hooks load under their original names before wrapping.
If a hook cannot load, history persistence waits until its decision can be observed.
Lines starting with a space, matching `HISTORY_IGNORE`, spanning
several lines or over 1 KiB are skipped. Entries go to the owner-only file
`~/Library/Application Support/Akitty/folder-history` (`AKITTY_FOLDER_HISTORY_FILE`
overrides it with an absolute path) under a POSIX lock shared by shells and Settings.
Appends compact oversized files to at most 512 KiB; queries inspect at most that many bytes
and the newest 3000 rows. Symlinks, hard links and files without owner-only permissions
are refused. A failed lock never permits an unlocked write and produces a warning.
Safe nonblocking opens are required (available in macOS's zsh 5.9); older shells keep
native history and keys with an explicit warning rather than using unsafe storage.
Settings turns the feature off for
new terminals (the core's `create.folder_history`, which sets `AKITTY_FOLDER_HISTORY=0`) and
clears the file under the same lock, reporting unsafe paths or a busy writer. The legacy folder-history
file name, environment variables and preference keys remain compatible. bash has no shared history menu: `bind -x` cannot hand Tab back to Readline
completion, and macOS bash 3.2 cannot edit the line from a key binding at all.

Every program in the PTY can forge these notifications. They support navigation
and result interpretation; they never prove command execution, create approvals,
change ownership, or authorize host actions. SSH/tmux propagation is not configured
by this local integration. SDK capability detection likewise disables title/chrome
updates through SSH and multiplexers unless the host explicitly opts in.

## Host control and approval

Native embedders use `AgentCommandHost` or `TerminalView.runAgentCommand` (native
confirmation sheet). JavaScript hosts import `@defai-digital/akitty-sdk/host` and supply
an authenticated transport to the native ABI (or a host enforcing the same contract).
This interface is separate from the stdout/status SDK and read-only Web tools.

1. Acquire one exclusive lease for an actor. Human input is rejected while leased.
2. Read the integrated, unedited prompt and reported directory. Ask the user or the
   host's authorization policy about the exact session, actor, command and context.
3. On approval, mint one authorization bound to that session's lease, exact command
   and directory. It expires after 30 seconds; replacing it revokes the older grant.
4. Dispatch the same command once. Replay, mismatch, changed directory, expired
   lease or failed prompt checks reject execution. Dispatch consumes the grant even
   when queueing fails; a retry requires fresh approval. A command is at most 4096
   UTF-8 bytes, on one line, without control characters; shell syntax is permitted
   because the complete command is what the host approves.
5. Read history/output after the receipt's `after_command_id`. Shell completion is
   untrusted and does not release control or authorize the next command. Explicitly
   release the lease after reviewing results. **Edit → Reclaim Terminal Control**
   revokes the agent lease and outstanding grant; it does not kill the running
   process. The human can then send an interrupt or close the pane normally.

The C ABI is a trusted embedding boundary, not an authentication endpoint. Do not
expose its approval/control operations directly to terminal programs, browser agent
text, remote callers or the public read-only tools. A host service must authenticate
callers and enforce its approval policy before reaching this API. The JavaScript
`approve` callback is the integration point for an ax-trust-backed policy, but this
repository does not include an authenticated ax-trust deployment or claim a cutover.
The native UI remains the local approval authority.

Audit events have monotonic session-local sequence numbers and timestamps, bounded
to 64 entries, with oldest/last cursors for loss detection. They include acquisition,
authorization, denial, dispatch/failure, untrusted shell completion, blocked human
input, release and reclaim. Commands can contain secrets: the host controls access
and retention. These records disappear when the session closes. Durable/tamper-resistant
or organization-wide auditing requires a host sink; it is not established by this
in-memory ring. Read/export pages before eviction and close. A transport failure
following dispatch is an uncertain outcome: never blindly retry the command.

**Window → Agent Overview** (⌥⌘A, or the command palette) lists every pane in every window, including the quick
terminal. For each it shows the controller from the core's control lease (host state),
the program chrome mark, status and progress (reported by programs, unverified), the
shell-reported directory (untrusted) and whether the shell exited. It reads only these
snapshot fields, never terminal text, so it does not infer agent status from output.
**Show Terminal** focuses the pane; **Reclaim Control** is the same human action as
the Edit menu item. The overview cannot approve, execute or send input.

Current development preserves accessible cells during status updates and clears a
removed pane's selection, so actions cannot silently move to another pane. Opening
the overview focuses the table; arrow keys select a row and Return shows it. The
Reclaim button explains that running processes continue. Native command approval
shows the exact command, actor and shell-reported directory, with Deny as the default.
These are accessibility improvements to existing features. [VoiceOver user
validation is not complete](ACCESSIBILITY.md).

## Quick terminal and input

**Shell → Toggle Quick Terminal** shows or hides a persistent terminal window.
Enable a global shortcut in Settings → Keyboard and choose one of the three
combinations. A registration conflict is shown in Settings and the existing
shortcut stays registered. The window appears in the current Space on the display
under the pointer, including alongside full-screen apps where macOS permits it.
Hiding (hotkey/menu/close button) retains PTYs, tabs and scrollback and restores
prior application/window focus. Exiting the last shell closes it; showing again
creates a new session. App quit retains ordinary live-session confirmation and
bounded cleanup, including hidden quick terminals. Display/Space transitions and
sleep/wake should also be checked on the target macOS version.

Drop local files/folders into a pane to insert POSIX-shell-quoted absolute paths
with no execution newline (up to 64 items / 64 KiB). Apostrophes, spaces and shell
metacharacters are quoted. Plain text drops use clipboard paste protection;
control/multiline text follows the paste-confirmation preference (on by default). Remote file URLs and mixed file/text
items are rejected. Agent ownership also blocks drops until human reclaim. A Dock
or application drop instead opens a window in the folder; it does not paste a path.
The native default background is `#080A0D`; explicit application-selected ANSI
background colors remain respected.

## Validation boundary

The canonical `scripts/verify.sh` covers the native ABI, actual local bash/zsh PTYs,
lease/approval regressions, Swift UI policies and Web tests. Playwright exercises
Chromium/Firefox/WebKit on macOS; the workflow adds Ubuntu and Windows browser jobs.
These are browser component tests, not proof of AX Code Desktop's packaged PTY,
physical IME, every OS/font combination, accessibility or multi-day stability.
