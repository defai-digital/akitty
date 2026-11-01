# Accessibility in AkiTTY

AkiTTY's native macOS app already exposes terminal text, selected text and ranges,
UTF-16 character counts, range reads and the cursor's row through AppKit accessibility.
Tabs have accessible labels and selection actions. Agent Overview already lists
panes across windows, tabs, splits and the quick terminal, including when hidden.
**VoiceOver user validation is not complete.** This page describes current development;
it does not claim these improvements are in the published 1.2.5 binary.

## Agent Overview

Open **Window → Agent Overview (⌥⌘A)**. Focus starts in the table. Use arrow keys to
select a terminal and Return or **Show Terminal** to focus it. Tab moves to available
actions; macOS Keyboard Navigation settings may affect standard Tab behavior.
When a pane disappears, its selection clears and actions are disabled until another
pane is selected. Status updates preserve existing cell objects.

The **Control (host)** column describes enforced input ownership. **Program reports
(unverified)** and **Shell directory (unverified)** are information supplied by terminal
programs. They do not authenticate an agent or prove that work succeeded.

**Reclaim Control** returns terminal input to you and revokes unused approvals.
It does not stop a running process. You can then interrupt that process normally.

## Command approval

A trusted embedding host can request an approval sheet. It exposes the actor,
terminal, exact command and shell-reported directory as text. **Deny** is the default
button and receives initial keyboard focus; **Run Command** requires deliberate
activation. The sheet explains that the directory is unverified and reclaiming input
does not terminate commands. No approval capability is added to WebMCP.

## Terminal reading

Current development adds line/index accessibility queries using UTF-16 offsets,
including CJK, emoji and combining text. It exposes the currently displayed grid;
this is not a complete scrollback document. Accessible selection remains available.

Text-change notifications are coalesced over 250 ms rather than posted for every
rendered frame. The app does not submit terminal output as a spoken announcement. In the key
terminal window, concise announcements describe input ownership changes, shell exit,
and program-reported transitions from busy to idle or into error. Progress and animation frames do
not generate announcements. Assistive technology controls how notifications are spoken.

## Validation status

Automated checks cover Overview membership and selection, accessible cell identity,
Unicode line reads and invalid indices, state-transition messages, and the approval
sheet's command context and default. These checks establish API behavior, not what
a person hears from VoiceOver.

Keyboard/VoiceOver sessions still need to validate reading order, focus restoration,
tabs and split panes, Settings, exact command pronunciation, selection, scrollback,
and behavior during sustained output. Full range geometry and scrollback/cursor
navigation remain follow-up work. Report the app version, macOS version, VoiceOver
settings and the steps that failed when filing an accessibility issue.
