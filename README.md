<p align="center"><img src="assets/icon-source.png" width="128" alt="AkiTTY cat terminal logo"></p>

# AkiTTY

**A native macOS terminal for everyday shell work and AI coding agents.**

Organize projects in windows, tabs, and split panes. Find output across open
terminals, keep a quick terminal one shortcut away, and use Agent Overview to
see what your coding agents report. When an agent asks AkiTTY to run a command,
you review the exact command before anything is sent to the shell.

**Apple Silicon · macOS 27.2+ · Designed for ProMotion displays · MIT licensed**

[Install](#install) · [Features](#everyday-terminal-features) ·
[Agents](#work-with-ai-agents) · [User guide](docs/USER_GUIDE.md) ·
[Release notes](docs/releases/2.4.2.md) · [All documentation](docs/README.md)

## Install

Download **AkiTTY 2.4.2** for Apple Silicon, unzip it, and move **Akitty.app**
to Applications. [Download ZIP](https://github.com/defai-digital/akitty/releases/download/v2.4.2/AkiTTY-2.4.2-macOS-arm64.zip) ·
[Latest release](https://github.com/defai-digital/akitty/releases/latest)

Or use the installer. It verifies the checksum, code signature, and
notarization before installing the app in **~/Applications**. Add `--system`
to install in **/Applications** instead.

```sh
curl -fsSL https://download.automatosx.com/akitty/install -o install.sh
bash install.sh
open "$HOME/Applications/Akitty.app"
```

Use **⌘T** to open a tab, **⌘D** to split a pane, and **⌘,** to open Settings.
AkiTTY checks for updates in the background and shows a reminder in the title
bar; choose **AkiTTY → Check for Updates…** to check now. On a ProMotion
display, [turn on adaptive refresh](docs/USER_GUIDE.md#display-setup).

<a id="quick-start"></a>
<a id="what-is-implemented"></a>

## Everyday terminal features

| When you want to… | Use… |
| --- | --- |
| Keep several tasks in view | Split a tab into side-by-side panes. Switching tabs returns you to the last focused pane. Drag a tab onto another window's title bar to move its running shells. [Organize a project](docs/USER_GUIDE.md#organize-a-project) |
| Find output you saw earlier | **⌘F** searches the current pane. **⌥⌘F** searches retained output across open terminals and jumps to a match. |
| Open a shell with project settings | Save a profile with its own font, colours, shell, starting folder, and scrollback under **Settings → Profiles**. |
| Return to a workspace | Save named window layouts with **Shell → Window Layouts**. Reopening starts fresh shells and can include a short scrollback excerpt. |
| Reach a shell from another app | Enable the global Quick Terminal shortcut in **Settings → Keyboard**. Hiding the Quick Terminal keeps its shells running. |
| Recall a command from this folder | In zsh, type a prefix and press **Tab**. Commands run in the current folder come first. [Folder-aware history](docs/USER_GUIDE.md#folder-aware-command-history) |
| Open Unix executables from Finder | Choose **AkiTTY → Make AkiTTY the Default Terminal**. AkiTTY asks before it runs a program. [Open folders and programs](docs/USER_GUIDE.md#open-folders-and-programs) |
| Find an app command | Press **⇧⌘P** and search by name or keyword. For example, `zoom` finds the font size commands. |

<a id="folder-command-history"></a>

AkiTTY supports truecolor, alternate screens, CJK fonts, IME input, hyperlinks,
and the Kitty graphics and keyboard protocols. It renders with CoreText and
Metal and falls back to a software renderer. Paste and clipboard-write
confirmation are on by default. [Compatibility and test coverage](docs/COMPATIBILITY.md) ·
[Keyboard shortcuts](docs/USER_GUIDE.md#keyboard-shortcuts) ·
[Accessibility](docs/ACCESSIBILITY.md)

<a id="agent-protocols"></a>
<a id="why-akitty"></a>
<a id="30-second-tour"></a>

## Work with AI agents

Run your usual agent CLI inside an AkiTTY pane. **AkiTTY → Agent Integrations…**
shows which CLIs it found and installs the integration for each one.

| Agent | What AkiTTY can show or approve |
| --- | --- |
| Claude Code and Codex | Reported conversations and supported Bash permission prompts. **Allow Once** returns the decision to the agent, which runs the command under its own policy. |
| AX Code, Grok, Muse Code, Kimi Code, and AGY | Reported conversations and MCP requests to run a command in an AkiTTY pane. **Run Command** queues the approved command in that pane's shell. |
| Any other MCP client or script | Commands requested through the [local MCP bridge](docs/MCP.md) or the bundled `akitty-agent` companion. |

1. **Connect.** Install the integration for your CLI, restart the agent, and
   choose **AkiTTY → Enable Local Agent Requests**.
2. **Observe.** Open **Window → Agent Overview** (**⌥⌘A**) to see reported
   activity, who controls each pane's input, and queued approvals.
3. **Approve or deny.** Review the exact command and its target pane in the
   native sheet. **Deny** is selected by default.
4. **Reclaim.** After **Run Command**, check the terminal for the result and
   choose **Edit → Reclaim Terminal Control** to type in the pane again.
   Running commands continue.

Approval covers requests sent to AkiTTY. The agent's own subprocesses and file
operations keep using the agent's permissions. AkiTTY can also reopen your
windows and offer to resume the conversation last reported in each pane.
[Agent setup and approvals](docs/AGENT_NATIVE.md) ·
[Resume conversations](docs/AGENT_NATIVE.md#reopen-windows-and-resume-agent-conversations) ·
[Try an approval](docs/AGENT_DEMO.md)

## Siri and Shortcuts

Try **“Show agents in AkiTTY”** or **“Show the quick terminal in AkiTTY.”**
The Shortcuts app has ten AkiTTY actions for opening folders, managing panes,
and requesting a command for review. Every action requires local device
authentication. [Siri and Shortcuts guide](docs/SIRI.md)

<a id="macos-pty-throughput"></a>

## Performance

Each app below wrote the same payloads through a PTY 45 times per workload,
timed from the first write to the terminal's reply to a trailing
cursor-position request. The table reports median MiB/s; higher is better.
AkiTTY 2.3.1 was measured on 2026-11-23 and the other apps on 2026-11-19, on
the same Apple M3 Max with macOS 27.2.1, hidden windows, a 98×25 grid, and
scrollback set to zero.

<img src="docs/images/macos-pty-throughput.png" width="840" alt="Box plots of PTY throughput in MiB/s for five apps across four workloads. Dots show individual samples. Red lines label the highest median in each workload. The table lists all medians.">

| Workload (median MiB/s) | AkiTTY 2.3.1 | Ghostty 1.4.0 | Alacritty 0.17.0 | Kitty 0.51.0 | cmux 0.65.2.2 |
| --- | ---: | ---: | ---: | ---: | ---: |
| ASCII | 252.8 | 176.5 | 102.9 | 115.0 | 169.1 |
| ANSI color | 252.1 | 167.0 | 114.3 | 106.2 | 176.7 |
| CJK and combining text | 232.9 | 163.7 | 112.8 | 97.2 | 161.2 |
| Long lines | 240.4 | 166.5 | 99.3 | 112.7 | 182.6 |

Throughput is one measure. Key-to-paint latency, idle power, and memory are
measured separately. [Method and raw data](docs/PERFORMANCE.md#macos-pty-throughput) ·
[Headless engine comparison](docs/PERFORMANCE.md#reference-engine-throughput)

## Windows and Linux

The installable app is macOS only. AkiTTY Web runs the same Rust terminal
engine, compiled to WebAssembly, in a browser on Windows, Linux, and macOS.
It is a private source package embedded by AX Code Desktop, whose host starts
the shell and connects the PTY. [AkiTTY Web](packages/akitty-web/README.md)

<a id="build-and-run"></a>

## Build from source

Requires Apple Silicon, macOS 27.2+, Xcode 27.2, Rust 1.99.1 (pinned in
`rust-toolchain.toml`) and Node 22.18+.

```sh
rustup toolchain install 1.99.1 --profile minimal --component clippy --component rustfmt --target wasm32-unknown-unknown
scripts/build-app.sh debug     # try local changes
open build/Akitty.app
```

`scripts/build-app.sh release` requires a clean, committed checkout.
`scripts/verify.sh` runs the full gate: Rust, Swift, TypeScript, WebAssembly,
ABI compatibility, browser tests, and release tooling.
[Contributing](CONTRIBUTING.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Release process](docs/RELEASING.md) · [Unreleased changes](docs/releases/unreleased.md)

<a id="shortcuts"></a>

## Documentation

| What you need | Guide |
| --- | --- |
| Set up a workspace, search, or change preferences | [User guide](docs/USER_GUIDE.md) |
| Set up an agent CLI, review requests, or resume a conversation | [Agent workflows](docs/AGENT_NATIVE.md) · [MCP bridge](docs/MCP.md) |
| Use the keyboard, VoiceOver, or Siri | [Shortcuts](docs/USER_GUIDE.md#keyboard-shortcuts) · [Accessibility](docs/ACCESSIBILITY.md) · [Siri](docs/SIRI.md) |
| Integrate a program or host | [Program SDK](packages/akitty-sdk/README.md) · [Shell integration and host control](docs/AGENT_WORKFLOWS.md) · [C ABI](docs/ABI.md) |
| Check what is tested and planned | [Compatibility](docs/COMPATIBILITY.md) · [Roadmap](docs/ROADMAP.md) |
| Everything else | [Documentation index](docs/README.md) |

## License and acknowledgments

AkiTTY is MIT licensed. The native and web terminals use the independently
authored `akitty-vt` engine. Thanks to the Ghostty, Alacritty, and VTE
contributors for earlier engines and design references, and to iTerm2 and
Kitty for architectural ideas and protocol work. [License](LICENSE) ·
[Engine provenance](third_party/TERMINAL_ENGINE.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
