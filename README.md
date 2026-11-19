<p align="center"><img src="assets/icon-source.png" width="128" alt="AkiTTY cat terminal logo"></p>

# AkiTTY

**A native macOS terminal for working with AI coding agents.**

Run Claude Code, Codex, OpenCode, or your usual shell. See what participating
agents report across your panes, review the commands they ask AkiTTY to run,
and take back terminal input when you need it.

**Apple Silicon · macOS 27.2+ · MIT licensed**

[Install](#quick-start) · [Try the agent workflow](#try-the-agent-workflow) ·
[Performance](#performance) · [Agent integration](#works-with-your-ai-agents) ·
[Release notes](docs/releases/1.4.1.md)

## Quick start

```sh
curl -fsSL https://download.automatosx.com/akitty/install -o install.sh
bash install.sh
open "$HOME/Applications/Akitty.app"
```

The installer verifies the archive checksum, code signature and notarization,
then installs AkiTTY into `~/Applications`. Use **⌘T** for a new tab, **⌘D** to
split a pane, and **⌘,** to set your font, shell and starting directory. The
title bar shows available updates. **Akitty → Check for Updates…** checks
manually.

### Manual download

Download the macOS arm64 ZIP, unzip it, and move **Akitty.app** to Applications.
For a shared installation, run `bash install.sh --system` with write access
to `/Applications`. [Latest release](https://github.com/defai-digital/akitty/releases/latest)

<a id="why-akitty"></a>
<a id="30-second-tour"></a>

## Try the agent workflow

- **Observe.** Open **Window → Agent Overview (⌥⌘A)** to see agent-reported
  activity and input ownership across windows, tabs, splits and the quick terminal.
- **Approve.** Enable local agent requests to review the exact command and target
  pane in a native approval sheet. **Deny** is the default.
- **Reclaim.** Use **Edit → Reclaim Terminal Control** or **Reclaim Control** in
  Agent Overview to take back input and revoke unused approvals. A command
  already running continues until it exits or you interrupt it.
- **Inspect.** Open **Akitty → Agent Event Timeline…** for local activity and
  request metadata, or choose **Export Agent Events…** to export JSONL.

Approval applies to explicit requests through AkiTTY's opt-in local interface.
Ordinary subprocesses and file operations use the agent's and OS's permissions.
Program status shows what the program reports. An accepted request receipt
confirms that input was queued. Inspect the terminal to check the command result.
[Native request and trust boundary](docs/AGENT_NATIVE.md#local-request-protocol-and-trust-boundary)

### Observe a program report

Run this in an AkiTTY pane and open **Agent Overview**. With **Allow programs
to set the status bar** enabled, the pane shows a working report followed by
a completion report.

```sh
{
  printf '\033]7501;state=working:app=demo\007'
  sleep 5
  printf '\033]7501;state=done:app=demo\007'
}
```

### Approve a command and reclaim input

1. Leave a local bash or zsh pane idle at an empty prompt with shell integration
   enabled.
2. Choose **Akitty → Enable Local Agent Requests** for this app run.
3. From a second pane, list the terminals and request `pwd` in the idle pane.
   Replace `<pane-id>` with the opaque ID from the list.

   ```sh
   AKITTY_AGENT="$HOME/Applications/Akitty.app/Contents/MacOS/akitty-agent"
   "$AKITTY_AGENT" list
   "$AKITTY_AGENT" request '<pane-id>' 'pwd'
   ```

4. Review the request in the native sheet. After approving it, inspect the
   target pane for the output and use **Reclaim Terminal Control** to type
   there again.

For a shared install, the client is at `/Applications/Akitty.app/Contents/MacOS/akitty-agent`.
The native guide covers pagination, recovery after a lost response, and local event
retention. [Native agent guide](docs/AGENT_NATIVE.md) · [Approval demo](docs/AGENT_DEMO.md)

<a id="what-is-implemented"></a>

## Everyday terminal features

- **Workspaces.** Native tabs, windows and vertical splits. Drag tabs between
  windows with their live shells and scrollback. Save named layouts and reopen
  them with fresh shells and optional saved scrollback.
- **Per-profile settings.** Save a font, theme, shell, starting directory and
  scrollback settings together. Open a folder from Finder or with
  `open -a Akitty /path/to/folder`.
- **Terminal input and output.** ANSI truecolor, alternate screens, scrollback
  search, hyperlinks, CJK fonts, IME input, Kitty graphics and keyboard
  protocols, and paste and clipboard controls.
- **Native rendering.** CoreText and Metal with a software fallback. The Metal
  path uses a glyph atlas for eligible ASCII frames.
- **Quick access.** Open the command palette with **⇧⌘P**, or enable the
  persistent quick terminal and assign a global shortcut.

[Compatibility and protocol coverage](docs/COMPATIBILITY.md) ·
[Accessibility controls and validation](docs/ACCESSIBILITY.md) ·
[Native app details](docs/ARCHITECTURE.md#macos-app-surface)

<a id="folder-command-history"></a>

### Command history

In an integrated zsh 5.9+ shell, type a prefix and press **Tab** to see recent
matches, with commands from the current folder first. Use **↑/↓** to preview,
**Return** to put the match on the command line, and **Return** again to run it.
Manage the feature in Settings. [History behavior and storage](docs/ARCHITECTURE.md#zsh-command-history)

<a id="macos-pty-throughput"></a>

## Performance

The released macOS apps processed the same four workloads through real PTYs.
Each rate is the median of 27 samples, from the first payload write to the
terminal's reply to a trailing cursor-position request.

| Workload (median MiB/s) | AkiTTY 1.4.0 | cmux 0.65.2.2 |
| --- | ---: | ---: |
| ASCII | 224.0 | 232.8 |
| ANSI color | 251.7 | 189.3 |
| CJK and combining text | 222.7 | 156.8 |
| Long lines | 222.5 | 242.9 |

The apps ran hidden on the same Apple M3 Max with macOS 27.2.1, a 98×25 PTY
grid and scrollback configured off. Results cover PTY transport and terminal
processing through the cursor reply. The ASCII and long-line launch median
ranges overlap. [App benchmark method and raw data](docs/PERFORMANCE.md#macos-pty-throughput)

The engine benchmark feeds bytes directly into the parser and grid. It includes
AkiTTY, libghostty-vt, Alacritty and Kitty. [Headless engine results](docs/PERFORMANCE.md#reference-engine-throughput)

## Siri and Shortcuts

Enable Siri in macOS, open AkiTTY and try **“Show agents in AkiTTY”** or
**“Show the quick terminal in AkiTTY.”** You can also use the built-in actions
in Shortcuts. **“Request a command in AkiTTY”** opens AkiTTY for review of the
exact command and pane. Actions require local device authentication.
[Available actions, setup and validation](docs/SIRI.md)

<a id="agent-protocols"></a>

## Works with your AI agents

Use your existing command-line agent in its usual shell. An agent or adapter
can opt in to AkiTTY workflows through these interfaces.

| Goal | Integration |
| --- | --- |
| Report activity or progress | Emit OSC 7501 program status. [Program reporting](docs/AGENT_NATIVE.md#observe-programs) |
| Show tab sprites or pane status | Emit OSC 771 through the [TypeScript/JavaScript SDK](packages/akitty-sdk/README.md). |
| Request a command in a native pane | Use the bundled `akitty-agent` client. [Local request interface](docs/AGENT_NATIVE.md#request-a-command-from-a-local-agent) |
| Connect an MCP client | Run `akitty-agent mcp` for pane listing and human-approved requests. [MCP setup](docs/MCP.md) |
| Embed terminal control | Supply caller authentication and approval policy in your [trusted host](docs/AGENT_WORKFLOWS.md#host-control-and-approval). |

## Windows and Linux

AkiTTY Web is the private source package used by AX Code Desktop. It runs in a
browser on Windows, Linux and macOS, using the same Rust VT engine compiled
to WebAssembly. The embedding host starts the shell, owns its PTY, sends
output to `term.write()` and routes input from `term.onData()`.
[AkiTTY Web integration guide](packages/akitty-web/README.md)

## Architecture and security boundaries

AkiTTY's Rust VT engine owns parsing, the grid and keyboard encoding. The
macOS app combines Rust PTYs with Swift/AppKit, CoreText and Metal. The web
package supplies its own Canvas renderer. The native approval service uses
an opt-in same-user local socket, and the local event timeline retains bounded
metadata. [Architecture](docs/ARCHITECTURE.md) · [C ABI and protocols](docs/ABI.md) ·
[Event storage](docs/AGENT_NATIVE.md#timeline-storage-and-export)

## Limitations and roadmap

See the compatibility matrix for protocol coverage and open qualification
work. The roadmap tracks terminal input latency and rendering, shell
integration, quick terminal behavior and VoiceOver validation.
[Compatibility](docs/COMPATIBILITY.md) · [Roadmap](docs/ROADMAP.md)

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Settings | ⌘, |
| New window / tab | ⌘N / ⌘T |
| Split / close pane | ⌘D / ⌘W |
| Command palette | ⇧⌘P |
| Agent Overview | ⌥⌘A |
| Find in scrollback | ⌘F |
| Find next / previous | ⌘G / ⇧⌘G |
| Increase / decrease / reset font size | ⌘+ / ⌘− / ⌘0 |

## Build and run

Source version **1.4.1** requires Apple Silicon, macOS 27.2+, Xcode 27.2,
Rust 1.99.1 and Node 22+. See the contributor guide for the repository layout
and focused development commands. [Contributing](CONTRIBUTING.md)

```sh
rustup toolchain install 1.99.1 --profile minimal --component clippy --component rustfmt --target wasm32-unknown-unknown
scripts/build-app.sh release
open build/Akitty.app
```

### Verification and distribution

```sh
scripts/verify.sh
```

The gate covers Rust, Swift, TypeScript, WebAssembly, ABI compatibility,
browser tests and release tooling. [Verification and build details](CONTRIBUTING.md#build-and-test) ·
[Signing and publication](docs/RELEASING.md) · [Unreleased changes](docs/releases/unreleased.md)

## Acknowledgments and MIT license

AkiTTY's code is MIT licensed. The native and web terminals use the
independently authored `akitty-vt` engine. Thanks to the Ghostty, Alacritty
and VTE contributors for earlier engines and design references, to iTerm2
and Kitty for architectural ideas and protocol work, and to AX TUI for the
adapted command palette ranking. [License](LICENSE) ·
[Engine provenance](third_party/TERMINAL_ENGINE.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
