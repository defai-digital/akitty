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

- **Settings → Agents** (or `akitty-agent claude-hooks install`)
  adds Claude Code hooks to `~/.claude/settings.json`, keeping other settings and
  hooks; removing deletes only AkiTTY's entries.
- Claude Code's Bash permission prompts in an AkiTTY pane appear as Allow Once /
  Deny sheets in that pane's approval queue. Claude Code runs the command; AkiTTY
  sends no input. When AkiTTY cannot answer, Claude Code shows its own prompt.
- The pane is identified from the hook's controlling terminal, or that of its
  nearest ancestor when the agent starts hooks in a new session. The core's
  `shell_state` now reports the PTY device (`tty_device`).
- Agent Overview shows the conversation ID Claude Code reported for each pane.

## Codex permission prompts in AkiTTY

- **Settings → Agents** (or `akitty-agent codex-hooks install`) adds
  the same hooks to `~/.codex/hooks.json` (`$CODEX_HOME`), keeping other hooks.
  Trust them with `/hooks` in Codex.
- Codex's Bash permission prompts in an AkiTTY pane appear in the same approval
  queue; Codex runs the command under its own sandbox and policy. `apply_patch`,
  MCP and network approvals stay with Codex.
- Agent Overview shows Codex's conversation ID, and a restored workspace can
  resume it with `codex resume <id>`.

## Settings → Agents

- A new Agents tab in Settings (**Akitty → Agent Integrations…**) shows each
  agent CLI's path, version and capabilities, installs or removes its hooks in
  one click, and shows the newest conversation it reported.
- **Turn on when AkiTTY starts** (off by default) enables Local Agent Requests
  at launch.

## AX Code and requests from another pane

- **Settings → Agents → AX Code → Install** (or `akitty-agent ax-code-mcp
  install`) adds AkiTTY's MCP server to `~/.config/ax-code/ax-code.json`, leaving
  the commented `ax-code.jsonc` alone, plus a small plugin,
  `plugin/akitty.js`, that reports the conversation running in each pane. AX
  Code's command requests then wait in the approval queue, Agent Overview shows
  its conversation, and a restored pane can resume it with `ax-code --session
  <id>`.
- A request for another pane queues on that pane, and its sheet names the pane
  the request came from (found from the caller's terminal) or says it came from
  outside every pane. The timeline records `source_pane_session_id`, or
  `source: outside_panes`.

## Reopen windows and resume Claude Code and Codex conversations

- **Shell → Window Layouts → Reopen Windows and Agent Conversations at Launch**
  (off by default) saves the open windows and each pane's last reported Claude
  Code or Codex conversation ID, never text or commands, and reopens them at
  launch.
- A restored pane offers its own conversation. **Shell → Resume Agent
  Conversation** or **Resume Conversation** in Agent Overview types
  `claude --resume <id>`, `codex resume <id>` or `ax-code --session <id>` at the
  pane's idle prompt. Agent
  Overview shows "(resumed)" only after the agent reports that same ID from the
  pane.
- **Clear Saved Workspace** removes the saved workspace and turns the option off.
- The core's control summary now reports `prompt_edited`, so Resume refuses a
  prompt that already holds typed text.
