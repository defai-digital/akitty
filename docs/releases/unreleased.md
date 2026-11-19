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
