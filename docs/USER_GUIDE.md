# AkiTTY user guide

AkiTTY is a terminal for Apple Silicon Macs running macOS 27.2 or later.
Open the app and start with your usual shell. Use **⌘T** for a tab, **⌘D**
for a split, and **⌘,** for Settings. [Install AkiTTY](../README.md#quick-start)

## Open folders and programs

- **Open a folder.** Drop it onto the AkiTTY Dock icon or run
  `open -a Akitty /path/to/project`. Passing a file to `open -a` opens its
  containing folder, including when the file is executable.
- **Open a program from Finder.** Choose **Akitty → Make Akitty the Default
  Terminal** and confirm the file associations in macOS. When Finder, the Dock,
  or a launcher opens a Unix executable or an executable `.command` or `.tool`
  file, AkiTTY offers **Run**, **Open Folder**, and **Cancel**. **Run** starts a
  shell in the file's folder and keeps the shell open so you can read the output.
  **Open Folder** starts a shell there with an empty command line.
- **Start from the Dock.** Control-click the AkiTTY icon and choose **New Window**
  or **New Tab**. **New Tab** opens in the frontmost terminal window and leaves
  a hidden Quick Terminal hidden. With no terminal open, it opens a window.

AkiTTY accepts up to eight folders and programs in one open request. **Run**
supports sh, bash, zsh, dash, ksh, and fish. Integrated bash and zsh sessions
wait up to 30 seconds for a ready prompt. With integration off or unavailable,
AkiTTY sends the launch line after two seconds, so a shell startup question may
receive it. Typing or pasting into the new pane first cancels the pending launch.
[Shell startup and prompt hooks](AGENT_WORKFLOWS.md#local-shell-integration)

## Organize a project

- **Keep related tasks together.** Open a tab for each project or split a
  tab into side-by-side panes for a shell, a build, or a log. Click a pane
  to focus it. **⌘W** closes the active pane.
- **Move a running shell.** Drag a tab to another AkiTTY window's tab bar.
  The tab brings its split panes, processes, and scrollback. Drag above or
  below the tab bar to detach it into its own window.
- **Use project defaults.** In **Settings → Profiles**, click **+** and
  set the desired font, colours, shell, starting directory, and scrollback.
  Click **Apply**, then pick the profile under **Shell → New Window with
  Profile** or **New Tab with Profile**. Tabs and splits opened from a
  profiled pane inherit its profile. An ordinary new tab uses the pane's
  reported working directory if it still exists, then falls back to the folder
  the pane started in. **New Tab with Profile** uses the selected profile's
  starting folder.

## Find and copy output

Press **⌘F** to search the focused pane's scrollback, then **⌘G** or **⇧⌘G**
to move between matches. If you remember the output but forgot which pane
printed it, press **⌥⌘F**. Pick **This Window** or **All Terminals**, enter
the text, and double-click a result or select it and press **Return** to open
its pane at that match. Search covers retained output in open terminals; a
result can expire as old output scrolls out.

While the find field has focus, **⌘C** and **⌘V** edit the query. Pane commands
such as **Close Pane**, **Restart Terminal**, and font size changes act on the
pane being searched. New tabs use that pane for profile and directory
inheritance, and new splits use its profile.

Drag to select text, double-click to select a word, or triple-click to select
a line. Hold **Option** to select locally when a terminal program handles
mouse clicks. Use **⌘C** to copy and **⌘V** to paste. **Command-click** a
supported hyperlink to open it.

Drop local files or folders into a pane to insert shell-quoted paths at
the prompt. Review the command line and press **Return** when ready.
Use **Settings → Sessions → Clipboard** to manage confirmation for
multiline pastes and clipboard writes requested by terminal programs.

## Save and reopen a workspace

| To… | Choose this under **Shell → Window Layouts** | What opens |
| --- | --- | --- |
| Save a workspace by name for later | **Save Windows as Layout…**, then choose the saved name from the same menu | The saved regular windows, tabs, and splits with fresh shells and the recorded folders and profiles. You can select **Include recent scrollback** when saving to keep a short text excerpt. |
| Reopen your workspace automatically | **Reopen Windows and Agent Conversations at Launch** | The last saved regular windows with fresh shells. Each pane that has a reported conversation can offer to resume it. |

To continue a reported conversation, focus its pane at an empty integrated
shell prompt and choose **Shell → Resume Agent Conversation**, or select
that pane in **Agent Overview** and choose **Resume Conversation**.
The agent starts a new process using its saved conversation ID.
**Remove Stored Scrollback** clears an excerpt from a named layout.
**Clear Saved Workspace** clears the automatic restore and turns it off.
[Agent resume setup and states](AGENT_NATIVE.md#reopen-windows-and-resume-agent-conversations)

## Keep a shell within reach

Choose **Shell → Toggle Quick Terminal** to show or hide a separate terminal
window. To toggle it from any app, open **Settings → Keyboard**, turn on
**Enable global quick terminal**, select a shortcut, then click **Apply**.
The window appears on the display under the pointer. Hiding it keeps its
shells, tabs, and scrollback available next time you show it.

## Make the terminal work the way you want

| Setting | Where to find it |
| --- | --- |
| Default font, CJK font, size, colours, and cursor | **Settings → Appearance**. Use **⌘+**, **⌘−**, and **⌘0** for the current pane's zoom. |
| Shell, starting directory, and scrollback for new sessions | **Settings → Sessions → New Terminals** |
| Shell integration and folder-aware command suggestions | **Settings → Sessions → New Terminals**. Shell integration supports bash and zsh. |
| Terminal bell and clipboard prompts | **Settings → Sessions → Alerts** and **Clipboard** |
| Option-as-Alt and status messages from programs | **Settings → Keyboard** |
| Update reminders | **Settings → Updates**, or **Akitty → Check for Updates…** for a manual check. |

### Folder-aware command history

For folder-aware history in an integrated zsh 5.9+ shell, type the start of
a command and press **Tab**. Matches from this folder come first. Use
**↑/↓** to preview, **Return** to place a match on the command line, and
**Return** again to run it. Toggle **Command history on Tab and Up/Down
(zsh)** or select **Clear History** in Sessions to manage these suggestions.
[History behavior and storage](ARCHITECTURE.md#zsh-command-history)

## Work with an agent

Open **Akitty → Agent Integrations…** to install hooks or MCP setup for a
supported CLI. Enable **Local Agent Requests**, then start the agent in a pane.
Use **⌥⌘A** to open Agent Overview. Select a row and choose **Show Terminal**
to see its output. The overview labels agent-reported status and enforced
input ownership separately.

When the approval sheet appears, review the command and pane. For a local
command request, **Run Command** queues the command at the target shell's
empty integrated prompt. Inspect the output and use **Edit → Reclaim Terminal
Control** to type in the pane again. For a supported Claude Code or Codex Bash
prompt, **Allow Once** returns the decision to the agent.
[Agent setup and approvals](AGENT_NATIVE.md#set-up-an-agent)

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Settings | ⌘, |
| New window / new tab | ⌘N / ⌘T |
| Split / close pane | ⌘D / ⌘W |
| Select tab 1–8 / select last tab | ⌘1–⌘8 / ⌘9 |
| Restart terminal | ⇧⌘R |
| Command palette | ⇧⌘P |
| Find in current pane | ⌘F |
| Find next / previous | ⌘G / ⇧⌘G |
| Find in All Terminals | ⌥⌘F |
| Increase / decrease / reset pane font size | ⌘+ / ⌘− / ⌘0 |
| Agent Overview | ⌥⌘A |

The command palette searches command names and keywords. For example, type
`zoom` to find the font size commands. Matches on consecutive letters rank
before matches that skip letters. The accessibility guide covers keyboard and
screen-reader use in Agent Overview, approval sheets, and terminal panes.
[Accessibility](ACCESSIBILITY.md) · [Siri and Shortcuts](SIRI.md) ·
[Terminal compatibility](COMPATIBILITY.md)
