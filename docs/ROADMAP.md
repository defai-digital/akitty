# AkiTTY implementation roadmap

This roadmap distinguishes the 1.3.0 implementation baseline and remaining qualification.
The native Mac app uses locally maintained source derived from `alacritty_terminal` 0.26.0 with AkiTTY's own
Rust/Swift integration and rendering. AkiTTY Web separately uses Ghostty's VT
parser compiled to WebAssembly and Canvas rendering. Native performance must be
measured on AkiTTY; Ghostty's native core and renderer are not used by the Mac app.
See [architecture](ARCHITECTURE.md) for the current implementation and
[the README](../README.md#what-is-implemented) for shipped behavior.

## 1. Performance and stability

Implemented foundation: local engine ownership, synchronized-output timeout recovery,
PTY read diagnostics, required repeated concurrent PTY/pane cleanup checks, and
real-browser canvas/input/lifecycle tests. Run a longer PTY soak with
`AKITTY_STRESS_ROUNDS=100 cargo test --locked -p akitty-core --test lifecycle_stress -- --nocapture`.
This exercises 800 sessions. It does not establish multi-day reliability, memory
plateaus, sleep/wake behavior or complete terminal conformance.


Establish repeatable baselines before changing hot paths. Priorities are:

- Measure input throughput, full/partial snapshot cost, typing latency, idle
  wakeups, and memory with several panes and graphics workloads.
- Evaluate reducing full-grid snapshot hashing, filter-buffer copies, and event
  processing overhead while preserving protocol ordering and queue bounds.
- Evaluate waking the PTY worker for input/resize/close instead of its fixed
  10 ms idle polling, with prompt shutdown and no lost wakeups.
- Reduce hidden/minimized-pane rasterization and polling while keeping PTY output
  consumption, exit detection, and bounded state updates active. Refresh the
  visible state when the pane is shown again.
- Extend malformed-input and stream-chunking coverage, including graphics/chrome
  sequences, Unicode, resets, resize, and partial/full snapshot equivalence.
- Stress repeated open/close, shell exit during output, resize/input bursts,
  backpressure, and renderer fallback. Check that child processes, file
  descriptors, threads, and memory settle after cleanup.
- Preserve unexpected I/O and cleanup errors in visible session status; distinguish
  expected PTY closure from failures rather than silently discarding errors.

The existing release-mode timing probe is a starting point:

```sh
cargo test --release --locked --test hotpath_probe -- --ignored --nocapture
```

It measures headless feed, full snapshot serialization, and unchanged polls; its
feed result includes JSON request overhead. It does not measure end-to-end UI
latency, GPU behavior, idle power, or long-running stability.

Acceptance: compare the same workloads before/after, preserve full/partial snapshot
equivalence and protocol behavior, and pass `scripts/verify.sh` plus app smoke
checks. Performance claims need measurements; stability claims need stress-test
evidence. The local engine fork provides independent maintenance; integration improvements still require their own tests.

## 2. Shell integration (implemented in 1.1.0; qualification continues)

Version 1.1.0 provides local bash/zsh hooks and bounded command history/output; the app enables
them by default for bash and zsh from 1.2.0.
See [host workflows](AGENT_WORKFLOWS.md) for startup, limits and trust boundaries.
Continue qualifying native-app awareness of prompt and command boundaries, working-directory
changes, and command completion/exit status through shell notifications. Define
the initial supported shells and notification protocol during implementation;
support for every shell is not implied.

Acceptance criteria:

- Document explicit enable/disable behavior and installation for supported shells.
- Validate bounded notifications and handle partial, malformed, repeated, or
  unexpected sequences without corrupting terminal output or session state.
- Test prompt/command transitions, failed commands, directory changes, multiline
  input, and startup files. Ordinary interactive shells work without integration.
- Treat shell-reported data as untrusted metadata. Integration does not grant
  terminal output permission to execute host commands or bundled JavaScript.
- Document any ABI additions and preserve schema-1 compatibility. AkiTTY Web's
  host must explicitly adopt any integration; native support does not add it to
  the separate web package automatically.

### Bash version qualification (2026-10-31)

macOS ships bash 3.2, which runs only the first `PROMPT_COMMAND` element, so macOS CI
alone could not catch prompt-array defects. A report from Linux bash 5.2 showed a
second `PROMPT_COMMAND` array hook recorded as the user's command (`printf HOOK_B`
instead of `echo REAL_COMMAND`). `scripts/test_shell_integration.py` was then run
against bash built from GPG-verified GNU sources (`AKITTY_TEST_BASH=/path/to/bash`;
`AKITTY_TEST_ZSH` selects zsh):

| Bash | Before the fixes | After | Subshell-only lines |
| --- | --- | --- | --- |
| 3.2.57 (macOS) | pass | pass | recorded (functrace) |
| 4.3.30 | not run | pass | recorded (functrace; checked on 4.3.0) |
| 4.4.18 | not run | pass | recorded |
| 5.1.16 | 2 failures | pass | recorded |
| 5.2.37 | 2 failures (the reported defect) | pass | recorded |
| 5.3 | 2 failures | pass | recorded |

Fixed: whole-array `PROMPT_COMMAND` assignment; hooks added after startup are adopted
instead of recorded; each hook sees the command's exit status as bash 5.1+ gives it;
subshell-only lines are recorded through `PS0` on bash 4.4+. A subshell line was also
checked through a real PTY on bash 5.2: command, start, its output, then exit status 3.
CI now runs the tests with bash 5.1 and 5.2 (Ubuntu 22.04/24.04) and Homebrew bash 5.3
on macOS, in addition to the system bash 3.2.

Bash 3.2–4.3 later gained subshell-only lines through functrace (`set -T`): the subshell
inherits the DEBUG trap and reports the line before its first command, so the record
keeps its output and duration (a record made after the fact would have neither), and
the core collapses a repeated start of the same command before a prompt. Qualified with
macOS bash 3.2.57 and unpatched GNU 4.3.0 and 5.2.0 builds, plus a real PTY through the
core on bash 3.2 (`actual_shells_record_subshell_only_lines_once_with_output_and_status`).

A line that reached history without running a command in the shell (a comment, a
function definition, or a subshell on these versions) used to leave an end mark with no
start; the prompt now restates such a line and the core folds the restart, so it is
recorded like any other.

The zsh ZDOTDIR wrapper was re-qualified on Linux (Ubuntu 26.04.1, zsh 5.9, bash
5.3.9) on 2026-10-31. The v1.2.2 wrapper reproduced the reported failure there: the
`compinit` in `/etc/zsh/zshrc` wrote `.zcompdump` into the shell-integration directory,
which in the app is the signed bundle. The single `.zshenv` that restores the user's
ZDOTDIR before the system files run passes all 12 shell tests on that box and leaves
the directory untouched; macOS zsh 5.9 and bash 3.2 pass as well.

Remaining: on bash 3.2–4.3 functrace makes functions inherit RETURN traps; the
bash-preexec path keeps its own limits; bash 4.3/4.4 are qualified locally, not in CI.

## 3. Quick terminal (implemented in 1.1.0; qualification continues)

Version 1.1.0 provides a persistent window and three selectable global shortcuts.
Continue qualifying a configurable global shortcut that shows/hides a persistent native terminal.
Hiding the terminal keeps the shell session alive. Closing it or quitting the app
continues to follow live-process confirmation and bounded shutdown rules.

Acceptance criteria:

- Define shortcut registration, conflict reporting, and enable/disable behavior.
- Define placement on multiple displays and behavior across Spaces/full-screen
  apps; document supported behavior and limitations.
- Show and focus the terminal predictably, and restore prior application focus
  when hidden where macOS permits it.
- Preserve the session across repeated toggles, sleep/wake, and display changes.
- Keep IME, paste policy, rendering fallback, and ordinary terminal windows working.
- Test failure paths and lifecycle cleanup; no orphaned shortcut registrations,
  timers, display links, or child processes.

## 4. Existing Agent Overview and accessibility (P1)

Agent Overview already lists panes across windows, tabs, splits and the hidden quick
terminal. Terminal text, selection, UTF-16 character counts, range reads and cursor
line are already exposed through AppKit accessibility APIs. Improve and validate
these foundations rather than scheduling them as new features.

Current development preserves Overview cell objects during status updates, clears
selection when a pane disappears, establishes keyboard focus and labels each cell's
source. The approval sheet exposes the exact command and shell-reported directory,
with Deny as the default. Terminal accessibility gains line/index queries,
coalesced text-change notifications and concise state-transition announcements.

Acceptance: regression tests for multiple windows/splits/hidden quick terminals,
stable selection and accessible cells, stale-pane action disabling, Unicode line
navigation, approval context/default and bounded notification behavior. Exercise
keyboard and VoiceOver operation in the native app, including denial, reclaim,
settings, selection and sustained output. Record each result and remaining limitation.
**VoiceOver user validation is not complete.** See [accessibility](ACCESSIBILITY.md).

Complete terminal navigation, range geometry, cursor tracking through scrollback,
remote/multiplexer behavior and user validation continue in P1–P2. Sixel stays
unsupported and is P3, subject to demonstrated compatibility demand. Performance,
stability and trusted-host execution control remain P0.

## 5. Agent-native integration (introduced in 1.3.0)

The first native integration implements bounded OSC 7501 revision 0.4 reports
alongside OSC 771, a request-only local companion with mandatory human approval,
source-labeled Overview state, and bounded local timeline/export. See
[the implementation contract](AGENT_NATIVE.md) for scope and usage.

Acceptance requires parser/lifecycle/ABI tests; no authority from program reports;
denial/disconnect/timeout/reclaim regressions; a real PTY command with an observed
filesystem effect; bounded private recording with loss markers; and the canonical
verification gate plus a built-app smoke. Published binaries are separate evidence.

Next work should validate another real Agent integration against the same request
contract, then define optional command policy/evidence adapters. Existing ax-trust
LLM policies do not automatically authorize shell commands. Complete orchestration,
cloud execution, remote multiplexing and verifiable result attestation are deferred.

## Outside the current roadmap

- Native Linux or Windows desktop apps (the 1.3.5 experiments are discontinued;
  AkiTTY Web covers those platforms).
- Ghostty configuration compatibility or importing Ghostty's native Zig core/renderer.
- Third-party plugins, arbitrary script loading, or a public extension ecosystem.
- Full external esctest qualification. The curated conformance suite remains a
  required gate; passing it does not establish complete xterm/esctest conformance.

Sixel, image clipboard protocols, and custom shaders remain unsupported and are
not added to this plan. Signing, notarization, and publication continue to follow
[the release procedure](RELEASING.md); this plan does not change those gates or
promise a release date/version for planned features.
