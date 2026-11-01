# Experimental Windows amd64 desktop

Status: implemented Experimental evaluation build; not a stable release.
The macOS app and its C ABI are unchanged by the Windows wrapper.

## Architecture and scope

`Shared Tauri/TypeScript UI -> shared trusted host -> Windows ConPTY -> PowerShell`

The Windows wrapper lives in `windows/`. The UI, command approval state machine,
input ownership, bounded output delivery and terminal observation code remain in
`linux/` and are compiled into both desktop variants. Platform adapters own native
PTY lifecycle, local IPC and event storage. Shared agent primitives remain in
`crates/akitty-agent-core`; AkiTTY Web is the only terminal grid.

Windows starts the native shell suspended, assigns it to a kill-on-close job and
then resumes it. Closing a pane terminates that contained process tree. Reads are
bounded and writes have a bounded worker queue. Natural exit closes ConPTY while
continuing to drain output to EOF. Cleanup runs outside the host lock; at most 32
live/cleaning-up sessions retain resources. Slow cleanup is reported rather than
blocking the UI indefinitely. The initial scope is Windows 11 amd64, Windows
PowerShell 5.1 and installed PowerShell 7; cmd.exe, WSL and Windows ARM64 are not
included.

PowerShell hooks are process-local, launched without user profiles. They preserve
the host's exact human approval and single-use grants and report untrusted command
history, filesystem directory and completion. Non-filesystem provider prompts do
not admit managed commands. Reports never grant control. Shell completion does
not invent a native command exit code.

The request-only named pipe has a protected user-only DACL, rejects remote clients,
checks peer user/session identity and retains one first-instance server handle.
Only list and exact-command request operations are accepted. UI approval remains
the authority. The protocol uses the same bounded JSON frames as Linux, with a
Windows-only receipt byte before disconnect so unread responses are not discarded.
Connection setup can briefly wait for the prior connection to close; request data
is never automatically resent. CLI errors after submission explicitly report an
uncertain outcome.

Event files use protected user-only DACLs, an exclusive writer handle, a pinned
directory, hardlink/reparse-point rejection, two bounded segments and create-new
exports. These controls do not sandbox other processes running as the same user.
UI reports, input review, reclaim, expiration, disconnect handling, recording
failure and fingerprints retain the shared host semantics.

Build/run instructions: [Windows README](../windows/README.md).

## Qualification recorded 2026-11-01

| Gate | Observed result |
| --- | --- |
| Native Windows 11 amd64 | 9 host tests passed with Windows PowerShell 5.1: real ConPTY effects, request-only named pipe, approval/denial, disconnect/expiry, stale context, storage failures, replay, final-output drain, job cleanup and private storage |
| Shared Rust primitives | 9 tests passed on Windows |
| Windows build | Strict TypeScript/Vite build, native release build, host and desktop clippy passed |
| Installed NSIS package | Real Tauri/WebView2 UI test passed under a non-elevated test token: exact approval, default denial, once-only filesystem effect, reclaim, keyboard input, fingerprinted timeline, private export and close confirmation |
| Installed identity | Companion byte-identical to build; app differs only at Tauri's three-byte `NSS` versus `UNK` bundle-format marker |
| Linux regression after platform extraction | 8 native x86_64 host tests and clippy passed; 7 Unix host tests also passed on macOS |

The Windows host used OS build 26200, Rust 1.99.1, Node 26.5.1, Windows PowerShell
5.1 and WebView2/EdgeDriver 156.0.4314.58. The desktop test used tauri-driver 2.1.0
and Selenium 4.52.0. Testing ran over SSH in Windows session 0, not a logged-in
physical desktop. PowerShell 7 discovery is implemented but was not locally
qualified; the tested shell was the installed Windows PowerShell 5.1.

The shared desktop smoke drives an actual Tauri/WebView2 window and installed
companion, without a mocked bridge or terminal. The test launcher filters an
elevated SSH/CI token to medium integrity with a user-owned default DACL; WebView2
ignores WebDriver environment overrides in elevated apps. This changes no account,
registry or machine policy. A test-owned Windows job cleans up driver descendants.
No remote-debugging option is added to the installer or app configuration.

CI has a Windows amd64 build/test/installer/UI job. That hosted job has not been
run as part of this implementation. Local packages and tests do not publish a
release or establish full macOS parity.

Local evidence is retained under the ignored `build/windows-experimental/`
directory: the unsigned installer, tested source snapshot, logs and UI screenshots.
SHA-256 identities:

- `AkiTTY-Experimental-0.1.0-windows-amd64-setup.exe`:
  `b022e9478a23d51bbda56d8a62a66f849cea84024111bfd1b3caae4dfb28d7ad`
- `source-snapshot.tar.gz`:
  `634f3211e2e7b5640ea874f7db44a419831e2d0efff357a8aecccaaaf69c928f`

Physical CJK IME, screen readers, interactive desktop/GPU combinations, extended
reliability and broader PowerShell/user-profile compatibility remain separate
qualification gates. The experimental installer is unsigned and has no automatic
updates. No public Windows release is implied.

## API references

- [Microsoft ConPTY lifecycle](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session)
- [Microsoft named pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- [Tauri Windows installers](https://v2.tauri.app/distribute/windows-installer/)
