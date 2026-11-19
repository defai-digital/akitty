# Unreleased

## Several agents can wait for approval at once

- Requests for different panes now wait in one approval queue instead of being
  refused while another approval is open. Each pane shows its oldest request
  first, holds up to 8, and AkiTTY holds up to 64. A queued request holds no
  input lease.
- Later approvals attach to their own windows without taking focus while one is
  already on screen. Agent Overview shows each pane's waiting count and oldest
  wait.
- Requests expire 120 seconds after they are queued. The 3-second cooldown now
  delays the next sheet in the same window instead of refusing the request.
- `akitty-agent request --id <id>` and the MCP `request_id` argument name a
  request; reusing an ID never runs a command again. `akitty-agent status <id>`
  and the MCP `request_status` tool report its state.

## Claude Code permission prompts in AkiTTY

- **Akitty → Claude Code Integration…** (or `akitty-agent claude-hooks install`)
  adds Claude Code hooks to `~/.claude/settings.json`, keeping other settings and
  hooks; removing deletes only AkiTTY's entries.
- Claude Code's Bash permission prompts in an AkiTTY pane appear as Allow Once /
  Deny sheets in that pane's approval queue. Claude Code runs the command; AkiTTY
  sends no input. When AkiTTY cannot answer, Claude Code shows its own prompt.
- The pane is identified from the hook's controlling terminal. The core's
  `shell_state` now reports the PTY device (`tty_device`).
- Agent Overview shows the conversation ID Claude Code reported for each pane.

## Reopen windows and resume Claude Code conversations

- **Shell → Window Layouts → Reopen Windows and Agent Conversations at Launch**
  (off by default) saves the open windows and each pane's last reported Claude
  Code conversation ID, never text or commands, and reopens them at launch.
- A restored pane offers its own conversation. **Shell → Resume Agent
  Conversation** or **Resume Conversation** in Agent Overview types
  `claude --resume <id>` at the pane's idle prompt. Agent Overview shows
  "(resumed)" only after Claude Code reports that same ID from the pane.
- **Clear Saved Workspace** removes the saved workspace and turns the option off.
- The core's control summary now reports `prompt_edited`, so Resume refuses a
  prompt that already holds typed text.
