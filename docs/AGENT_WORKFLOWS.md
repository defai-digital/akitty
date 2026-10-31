# Program identity, shell observations, and trusted host control

This document describes the native workflow and SDK host additions in AkiTTY 1.1.0.
The separate Web terminal and its embedding host retain their own adoption and release process.

## Product strengths and scope

The native app's distinctive workflow is **per-program tab identity**: an integrating
program supplies a small sprite, activity and progress, and a background completion
dot remains until that tab is viewed. Status text and progress appear in the pane;
the tab shows the activity mark/sprite and completion indicator. This uses the
existing stdout writer, OSC 771, and the zero-dependency SDK's main entry. Programs
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

Zsh runs as an interactive login shell. A bundled ZDOTDIR wrapper loads the user's
`.zshenv`, `.zprofile` and `.zshrc`, restores their ZDOTDIR, then lets ordinary login
startup continue. Bash uses an interactive `--rcfile` wrapper and explicitly sources
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
Bash 3.2–4.3 has no `PS0` and does not record such a line, nor does bash-preexec when
the hooks join it. The hooks are tested with bash 3.2, 4.3, 4.4 and 5.1–5.3. When history omits a command, bash
falls back to the first simple command text; a compound line may therefore have
partial descriptive text. Host approval/audit still binds the full exact requested
command independently of this untrusted shell description.

Hooks emit OSC 133 A/B/C/D, OSC 7 directory URIs and bounded OSC 772 base64 command
text. A command starts at C and ends at D; missing completion followed by a new
prompt/start marks it interrupted. A missing D has unknown exit status. Captured
output is the ordered raw terminal byte stream between these boundaries, excluding
intercepted shell/chrome metadata; ANSI bytes remain. It is not separated stdout
and stderr, and is not a durable transcript. Retain up to 64 records and 16 KiB per
command; `truncated` reports clipping and evicted ids return errors. History metadata
and output explicitly report `untrusted:true`. The shell child's exit code in a
snapshot remains distinct from each observed command's exit status.

Every program in the PTY can forge these notifications. They support navigation
and result interpretation; they never prove command execution, create approvals,
change ownership, or authorize host actions. SSH/tmux propagation is not configured
by this local integration. SDK capability detection likewise disables title/chrome
updates through SSH and multiplexers unless the host explicitly opts in.

## Host control and approval

Native embedders use `AgentCommandHost` or `TerminalView.runAgentCommand` (native
confirmation sheet). JavaScript hosts import `@ax-code/akitty-sdk/host` and supply
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
control/multiline text needs confirmation. Remote file URLs and mixed file/text
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
