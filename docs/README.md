# AkiTTY documentation

Start with the [project README](../README.md) for installation and an overview.
The current release is described in [AkiTTY 2.4.2](releases/2.4.2.md); changes
on `main` since then are in [unreleased](releases/unreleased.md).

## Use the app

| Guide | Covers |
| --- | --- |
| [User guide](USER_GUIDE.md) | Opening folders and programs, tabs and splits, search, profiles, saved layouts, the Quick Terminal, settings, and keyboard shortcuts. |
| [Agent workflows](AGENT_NATIVE.md) | Setting up Claude Code, Codex, AX Code, Grok, Muse Code, Kimi Code, and AGY; approvals; Agent Overview; resuming conversations; the event timeline. |
| [Local MCP bridge](MCP.md) | Connecting any stdio MCP client to AkiTTY's approval queue. |
| [Approval demo](AGENT_DEMO.md) | A reproducible request, denial, and approval with the bundled companion. |
| [Siri and Shortcuts](SIRI.md) | The ten App Shortcuts actions, setup, and troubleshooting. |
| [Accessibility](ACCESSIBILITY.md) | Keyboard and VoiceOver use, and current validation status. |

## Integrate with AkiTTY

| Guide | Covers |
| --- | --- |
| [Program SDK](../packages/akitty-sdk/README.md) | Titles, status, progress, and tab sprites from a program running in the terminal, plus the trusted host entry. |
| [Shell integration and host control](AGENT_WORKFLOWS.md) | bash/zsh hooks, command observations, folder-aware history, and the lease/approval contract for embedding hosts. |
| [C ABI](ABI.md) | The versioned native interface used by the Swift app and other native hosts. |
| [AkiTTY Web](../packages/akitty-web/README.md) | Embedding the browser terminal, its API, and read-only agent tools. |

## Develop AkiTTY

| Guide | Covers |
| --- | --- |
| [Contributing](../CONTRIBUTING.md) | Repository map, build and test commands, generated files, and local file policy. |
| [Architecture](ARCHITECTURE.md) | Component ownership, engine, PTY pipeline, rendering, and known limitations. |
| [Compatibility](COMPATIBILITY.md) | What each capability is tested against and where qualification stops. |
| [Roadmap](ROADMAP.md) | Current priorities and feature candidates. |
| [Performance](PERFORMANCE.md) · [Benchmarks](../benchmarks/README.md) | Measurement history, methods, raw data, and how to reproduce them. |
| [Releasing](RELEASING.md) | Versioning, signing, notarization, publication, and the SDK package. |
| [Engine provenance](../third_party/TERMINAL_ENGINE.md) · [Web provenance](../packages/akitty-web/PROVENANCE.md) | Engine ownership, historical origins, and WASM build verification. |

## Release notes and history

- [Release notes](releases/) for every version, and [unreleased changes](releases/unreleased.md).
- [Independent engine migration](archive/ENGINE_MIGRATION.md) and the
  [original quality milestone](archive/QUALITY_IMPROVEMENTS.md) are kept for
  reference. They describe past work and are not updated.

## Writing documentation

- Put user-visible changes in `releases/unreleased.md`.
- Name the release version only in the README, this index, and release notes.
  Other guides describe current behavior, so they need no edits at release time.
- Keep user steps in the user guide or agent workflows, contracts and limits in
  the reference guides, and planned work in the roadmap.
