# AkiTTY roadmap

This page lists what is shipped, what is being qualified, and what may come
next. It makes no promise of a release date or version for planned work.
For how shipped features work, see the [architecture](ARCHITECTURE.md); for
what each feature is tested against, see [compatibility](COMPATIBILITY.md).

## Shipped

| Area | Since | Where it is described |
| --- | --- | --- |
| Command palette ranked in Rust | 0.6.0 | [Command palette contract](ABI.md#command-palette) |
| bash/zsh shell integration, on by default | 1.1.0 (default in 1.2.0) | [Shell integration](AGENT_WORKFLOWS.md#local-shell-integration) |
| Quick Terminal with a global shortcut | 1.1.0 | [User guide](USER_GUIDE.md#keep-a-shell-within-reach) |
| OSC 7501 program reports, local command requests, event timeline | 1.3.0 | [Agent workflows](AGENT_NATIVE.md) |
| Independently authored `akitty-vt` engine, shared by native and Web | 1.3.10 | [Architecture](ARCHITECTURE.md) · [Engine provenance](../third_party/TERMINAL_ENGINE.md) |
| Siri and Shortcuts actions | 1.3.11 | [Siri and Shortcuts](SIRI.md) |
| Named window layouts | 1.3.16 | [User guide](USER_GUIDE.md#save-and-reopen-a-workspace) |
| Local MCP bridge | 1.3.21 | [MCP bridge](MCP.md) |
| Moving tabs between windows | 1.3.24 | [User guide](USER_GUIDE.md#organize-a-project) |
| Per-pane approval queues, Claude Code and Codex permission prompts, AX Code integration | 2.0.0 | [Agent integrations](AGENT_NATIVE.md#agent-integrations) |
| Workspace reopening with per-pane conversation resume | 2.0.0 | [Resume conversations](AGENT_NATIVE.md#reopen-windows-and-resume-agent-conversations) |
| Find in All Terminals | 2.1.0 | [User guide](USER_GUIDE.md#find-and-copy-output) |
| Grok, Muse Code, Kimi Code, and AGY integrations | 2.2.0 | [Agent integrations](AGENT_NATIVE.md#agent-integrations) |
| Finder default terminal and Dock menu commands | 2.3.0 | [Folder opening](ARCHITECTURE.md#macos-folder-opening) |

See the [release notes](releases/) for the exact version of each change.

## Priorities

### P0: performance and stability

Performance claims need before/after measurements on the same workloads, and
stability claims need stress-test evidence. Work in progress:

- Measure typing latency, snapshot cost, idle wakeups, and memory with several
  panes and graphics workloads, not only throughput.
- Extend malformed-input and stream-chunking coverage, including graphics and
  chrome sequences, Unicode, resets, resize, and partial/full snapshot equivalence.
- Stress repeated open/close, shell exit during output, resize and input bursts,
  backpressure, and renderer fallback, and check that child processes, file
  descriptors, threads, and memory settle afterwards.
- Report unexpected I/O and cleanup errors in the pane's status instead of
  discarding them, and distinguish them from an expected PTY close.
- Multi-day reliability is not established yet. The
  [optional qualification runs](../CONTRIBUTING.md#optional-qualification-runs)
  cover longer PTY soaks and sleep/wake.

Acceptance: the same workloads compared before and after, snapshot equivalence
and protocol behavior preserved, `scripts/verify.sh` passing, and an app smoke check.

### P0: trusted-host execution control

Approvals, input leases, and the event timeline must keep failing closed.
New request sources need denial, disconnect, timeout, and reclaim regressions,
and a real PTY test with an observed effect.

### P1: accessibility

Agent Overview, approval sheets, and terminal text are exposed through AppKit
accessibility and covered by automated tests. **A VoiceOver user validation
session is still outstanding.** Remaining work: reading order and focus
restoration across tabs and splits, range geometry, cursor tracking through
scrollback, and behavior during sustained output. See
[accessibility](ACCESSIBILITY.md#validation-status).

### P1: qualification of shipped features

- **Shell integration:** prompt frameworks, custom traps, nested shells, and
  bash 4.3/4.4 in CI. See [bash and zsh qualification](AGENT_WORKFLOWS.md#bash-and-zsh-qualification).
- **Quick Terminal:** behavior across Spaces, full-screen apps, display changes,
  and sleep/wake on each supported macOS version.
- **Applications:** a recorded qualification matrix for Vim, Neovim, tmux, and
  SSH workflows. See [recording an external qualification](COMPATIBILITY.md#recording-an-external-qualification).
- **Conformance:** full external esctest qualification. The curated suite is a
  required gate but does not establish complete xterm conformance.

## Feature candidates

1. Attention navigation in Agent Overview: unread state, filters, and jump to
   the next waiting pane.
2. Command navigation and output inspection using the existing bounded shell
   observations. Letting agents read output would need its own explicit
   permission and retention contract.
3. Recovery from corrupt saved layouts. Continuing live processes across app
   restarts would need a separate persistent PTY design.
4. Project and worktree launch presets that open a task's tabs, folder, and
   profile together.
5. Diff preview and handing selected review feedback to an agent.
6. Follow-up agent areas: UTCP, optional policy and evidence adapters, remote
   multiplexing, and result attestation.

## Not planned

- Native Linux or Windows desktop apps. The 1.3.5 experiments were
  discontinued; AkiTTY Web covers those platforms.
- Ghostty configuration compatibility or importing Ghostty's Zig core or renderer.
- Third-party plugins, arbitrary script loading, or a public extension ecosystem.
- Sixel, image clipboard protocols, and custom shaders.

Signing, notarization, and publication follow [the release procedure](RELEASING.md).
