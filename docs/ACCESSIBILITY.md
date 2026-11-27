# Accessibility in AkiTTY

AkiTTY 2.4.1 exposes terminal text, selected text and ranges,
UTF-16 character counts, line and index queries, range reads and the cursor's row
through AppKit accessibility. Tabs have accessible labels and selection actions.
Agent Overview lists panes across windows, tabs, splits and the quick terminal,
including when hidden. **VoiceOver user validation remains in progress.**
[Release notes](releases/2.4.1.md)

## Agent Overview

Open **Window → Agent Overview (⌥⌘A)**. Focus starts in the table. Use arrow keys to
select a terminal and Return or **Show Terminal** to focus it. Tab moves to available
actions; macOS Keyboard Navigation settings may affect standard Tab behavior.
When a pane disappears, its selection clears and actions are disabled until another
pane is selected. Status updates preserve existing cell objects.

The **Control (host)** column describes enforced input ownership. **Program reports
(unverified)** and **Shell directory (unverified)** are information supplied by terminal
programs. They do not authenticate an agent or prove that work succeeded.

**Approvals (host)** shows the pane's waiting count and oldest request.
**Agent session (reported)** shows the reported conversation or the state of
an offered resume. **Resume Conversation** applies to the selected pane.

**Reclaim Control** returns terminal input to you and revokes unused approvals.
It does not stop a running process. You can then interrupt that process normally.

## Command approval

The native command approval sheet exposes the source, target pane, exact
command and shell-reported directory as text. **Deny** is the default and
receives initial keyboard focus. **Run Command** requires deliberate activation.
Supported Bash permission prompts from Claude Code and Codex use
**Allow Once** and **Deny** and identify the agent that will run the command.

## Agents settings

Open **AkiTTY → Agent Integrations…** to find CLI status, integration controls
and the **Turn on when AkiTTY starts** switch. The switch has an explicit
accessible name and defaults to off.

## Pane status and focus

Navigating back to a split tab restores its last focused pane. The tab's
accessible label follows that pane's displayed title. Moving a tab to another
window keeps its remembered pane, including when the moved tab was in the
background.

A pane's status capsule names its source to assistive technology: program reports
are read as "Program reports, unverified", and AkiTTY's own input-lease and error
states as "AkiTTY". **Reclaim** in the capsule is a button with the same effect as
**Edit → Reclaim Terminal Control**. With Reduce Transparency or Increase Contrast
on, the capsule and the command palette use opaque backgrounds instead of glass.
In a split tab the focused pane has an accent outline; Increase Contrast
thickens it and removes the dimming of other panes, which would lower their text
contrast. Reduce Motion turns off the dimming fade and shows the first frame of
animated tab status icons. Changing Reduce Motion updates open tabs immediately.

## Terminal reading

The terminal exposes line and index queries using UTF-16 offsets,
including CJK, emoji and combining text. It exposes the currently displayed grid;
this is not a complete scrollback document. Accessible selection remains available.

Text-change notifications are coalesced over 250 ms rather than posted for every
rendered frame. The app does not submit terminal output as a spoken announcement. In the key
terminal window, concise announcements describe input ownership changes, shell exit,
and program-reported transitions from busy to idle or into error. Progress and animation frames do
not generate announcements. Assistive technology controls how notifications are spoken.

## Validation status

Automated checks cover Overview membership and selection, accessible cell identity,
Unicode line reads and invalid indices, state-transition messages, and command and
permission sheet labels. The Agents settings audit exercises the system accessibility
tree when the test process has macOS Accessibility permission. Manual VoiceOver
sessions cover the spoken behavior.

Keyboard/VoiceOver sessions still need to validate reading order, focus restoration,
tabs and split panes, Settings, exact command pronunciation, selection, scrollback,
and behavior during sustained output. Full range geometry and scrollback/cursor
navigation remain follow-up work. Report the app version, macOS version, VoiceOver
settings and the steps that failed when filing an accessibility issue.
