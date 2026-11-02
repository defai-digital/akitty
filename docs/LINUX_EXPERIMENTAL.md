# Experimental Linux desktop

Status: implemented Experimental evaluation build; not a stable release.
Windows has a [separate Experimental amd64 wrapper](WINDOWS_EXPERIMENTAL.md).

## Scope and acceptance plan

1. Share the existing Rust agent protocol/authority primitives with the native Mac
   app, preserving its C ABI and regressions.
2. Build a separate Tauri/TypeScript desktop using AkiTTY Web and Linux-native PTYs
   with installed bash/zsh. Do not embed or automate another terminal application.
3. Preserve request-only local agent IPC, exact human approval, single-use grants,
   exclusive input ownership, reclaim, source-labeled reports and private bounded
   event recording. Program/shell output never grants authority.
4. Test actual Linux PTY effects, denial, replay, stale context, disconnect, expiry,
   reclaim, storage failures and cleanup. Build the desktop against WebKitGTK.
5. Record what was tested separately from physical desktop/IME/accessibility
   qualification. No Windows decision or production release follows automatically.

The experiment provides a terminal workspace and agent workflow, not complete
macOS UI, graphics, quick-terminal, or accessibility parity. All UI and package
metadata identify it as Experimental. AkiTTY Web remains a separate browser
terminal; only this trusted desktop host adds execution authority.

## Architecture

`Tauri UI -> Linux host -> native PTY -> bash/zsh`

PTY output passes through shared bounded agent/shell filters before reaching
AkiTTY Web's Wasm terminal. There is one terminal grid, in AkiTTY Web. The host
owns control leases, request context, exact command dispatch and event storage.
The macOS app uses the same agent primitives through its existing private modules.

The host retains at most 16 sessions, bounds queued input/output, and delivers
output batches with acknowledgements and replay until consumption. A stalled UI
applies PTY backpressure instead of growing an unbounded output queue. Dashboard
messages are shortened to 128 characters with an explicit truncation flag;
protocol storage retains its existing bounds. Terminal replies use a separate
bounded response validator and cannot be used as an arbitrary input endpoint.

## Implemented workflow

- Native bash/zsh sessions, tabs and an all-terminal controller overview.
- OSC 771 chrome/sprites/progress and OSC 7501 reports, with program-report gating.
- Read-only shell history/output, with unverified source labels.
- Request-only Unix socket and companion CLI, kernel peer UID/PID checks,
  per-launch enablement, bounded framing, approval expiry and disconnect cancellation.
- Exact human approval with Deny as default, single-use grants, input leases,
  context/readiness checks, explicit reclaim and uncertain-outcome handling.
- Bounded private event timeline, command fingerprints, rotation/gap markers,
  incomplete-tail recovery, fail-closed recording and non-overwriting JSONL export.
- Reviewed multiline/control-character paste and confirmed terminal/app shutdown.
- Separate Experimental identity, desktop title, Debian package and source docs.

Build and usage instructions: [Linux README](../linux/README.md).

## Qualification recorded 2026-11-01

| Gate | Observed result |
| --- | --- |
| Linux host on Debian 12 ARM64 | 8 tests passed, including real PTY effects, local IPC, cancellation, replay, stale context, output acknowledgements, storage protection and failure before/after dispatch |
| Shared Rust primitives | 10 tests passed on macOS and Linux |
| Native shell hooks on Linux | 12 tests passed |
| Linux desktop | Tauri/WebKitGTK release build and clippy passed; TypeScript strict checking and Vite build passed |
| Installed ARM64 Debian package | Real WebKitGTK/Xvfb UI test passed: bash/zsh startup, keyboard input, exact command review, default denial, approval, once-only filesystem effect, reclaim, fingerprinted timeline, private export and close confirmation |
| Ubuntu 24.04.5 x86_64 and ARM64, separate native Linux hosts | Full `scripts/verify-linux.sh` passed on each architecture: 10 shared-core tests, 8 Linux-host tests, 12 shell-hook tests, frontend build, desktop build and clippy |
| Installed Ubuntu x86_64 and ARM64 packages | Release `.deb` built and installed on each architecture; installed executables matched the package contents; the real WebKitGTK/Xvfb UI test passed on both |
| macOS Swift regression suite | 245 tests completed, 1 skipped, 0 failures |
| Public source hygiene | New source audit, public-audit unit tests and whitespace check passed |

`linux/tests/desktop_smoke.py` drives an actual Tauri window through tauri-driver
2.1.0 and Selenium 4.52.0. It does not mock the bridge or the PTY. Linux CI adds
Ubuntu 24.04 x86_64 host/build/UI verification; that hosted job has not been run
as part of this implementation. Independent remote qualification used Ubuntu
24.04.5 containers on native x86_64 and ARM64 hosts, with four CPUs and 6 GiB of
memory per container, Rust 1.99.1, Node 26.5.0 and WebKitGTK 2.52.6. Both builds
used the same working-tree source archive, SHA-256
`7079fb232db3ba882820bcaf0cd03c4834b3ce0b6ec014c5f10be3e38c5758b4`.
This qualifies the recorded snapshot, not subsequent working-tree changes.
The tests used Xvfb software rendering without GPU passthrough; they do not
qualify GPU acceleration or the hosts' physical desktop sessions. Test containers
were removed after retrieving packages, logs, identity checks and screenshots.

The full macOS `scripts/verify.sh` was attempted but stopped at
`post_exit_drain_answers_a_descendant_cursor_position_query`. That test and its
session implementation were already being changed separately in the working
tree; this task did not edit those files. A focused rerun also failed. This is
an unresolved workspace gate, not a claimed green full macOS verification.

Remaining qualification: physical CJK IME, accessibility/screen readers, Wayland,
real GPU/desktop combinations, longer reliability
runs and broader distro compatibility. Split panes, macOS quick-terminal behavior,
file drops, automatic updates and native graphics parity are outside this initial
experiment. No public release or signing service is included.

## Windows decision

The separate [Windows amd64 experiment](WINDOWS_EXPERIMENTAL.md) shares the TS UI and authority model, with separate ConPTY, PowerShell, named
pipe and filesystem adapters. Linux qualification does not establish Windows
qualification; maintenance and actual usage remain evaluation criteria.
