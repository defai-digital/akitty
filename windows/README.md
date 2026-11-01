# AkiTTY Experimental for Windows amd64

A separate experimental Tauri desktop using the same TypeScript/AkiTTY Web UI and
trusted agent host as the Linux experiment. Windows uses native ConPTY,
Windows PowerShell 5.1 or an installed PowerShell 7, and local named pipes.
No WSL, Linux runtime, Windows Terminal embedding or PowerShell profile edits are
required. This is not complete macOS feature parity or a stable release.

## Build

Use Windows 11 amd64, Node 22+, npm, Python 3, Rust 1.99.1, Microsoft C++ Build
Tools and the WebView2 runtime. Run from the repository root:

```powershell
rustup toolchain install 1.99.1 --profile minimal --component clippy
npm.cmd ci --ignore-scripts --prefix linux
npm.cmd ci --ignore-scripts --prefix windows
npm.cmd --prefix windows run package
```

The unsigned, per-user NSIS installer is under
`windows/src-tauri/target/release/bundle/nsis/`. It installs
`akitty-windows-experimental.exe`, `akitty-agent.exe`, the trusted PowerShell hook
and third-party notices. WebView2's bootstrapper is used if the runtime is absent.
The installer does not add the companion to PATH, configure automatic updates,
publish a release or modify execution policy outside the launched shell process.

For development, `npm.cmd --prefix windows run desktop` starts the shared UI with
the Windows host. `scripts/verify-windows.ps1` runs native host tests, strict
frontend checks and desktop builds/clippy. See [qualification](../docs/WINDOWS_EXPERIMENTAL.md).

## Use

Open a PowerShell terminal and click **Enable agent requests**. Requests are off
at every launch. From the installed application directory, use:

```powershell
.\akitty-agent.exe list
.\akitty-agent.exe request PANE 'Get-ChildItem'
```

Review the exact command and terminal in AkiTTY. **Deny** is the default. Approval
queues input at most once, retains the agent's input lease, and does not prove
execution succeeded. **Reclaim terminal control** restores human input without
interrupting a running command. Closing a terminal terminates its job-contained
process tree.

The endpoint is `\\.\pipe\AkiTTY-Experimental-USER_SID-SESSION_ID`. The pipe rejects
remote clients and checks the peer process's user SID and Windows session.
One retained pipe instance prevents a second server from taking the same name.
`--socket` accepts an explicit local AkiTTY Experimental pipe name for testing.
There are no IPC approval, raw-input, event-read or reclaim operations.

Shell/program reports are unverified observations and never grant authority.
Managed requests require a clean integrated filesystem prompt. PowerShell registry
and other provider prompts do not qualify. Directory observations use file-URI
paths (for example `/C:/work`); they are not verified filesystem identities.
PowerShell completion is recorded without inventing an external process exit code.

The host retains the Linux experiment's bounded queues, exact approvals, expiry,
disconnect cancellation, control leases and fingerprinted event timeline. Windows
storage uses protected user-only DACLs, exclusive writer ownership, hardlink/reparse
rejection, bounded rotation and create-new exports. These controls govern AkiTTY's
managed input; they do not sandbox an agent's unrelated processes or file access.

## Desktop test

Install tauri-driver 2.1.0, Microsoft Edge WebDriver matching WebView2, and Selenium
4.52.0. With both drivers on PATH:

```powershell
powershell -NoProfile -File windows/tests/desktop_smoke.ps1 `
  -Application 'C:\path\to\installed\akitty-windows-experimental.exe' `
  -Companion 'C:\path\to\installed\akitty-agent.exe'
```

The test drives an actual Tauri/WebView2 window and real PowerShell command effects.
On elevated SSH/CI accounts, its launcher uses a temporary medium-integrity token
with a user-owned default DACL; no account or machine policy is changed. A Windows
job contains the test process and driver descendants for cleanup.
Physical IME, accessibility, GPU/desktop behavior and long-running reliability are
separate qualification tasks. Windows ARM64 and cmd.exe are outside this experiment.
