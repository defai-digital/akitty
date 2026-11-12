# Unreleased changes

- Add an optional macOS stdio MCP approval bridge through `akitty-agent mcp`, with
  `list_panes` and `request_command` tools for external agents. Existing per-launch
  opt-in, exact-command native approval, and human reclaim remain required.
  Dispatch receipts do not establish command success. See [setup and limits](../MCP.md).
