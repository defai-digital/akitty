# AkiTTY implementation roadmap

This plan distinguishes the implementation in version 1.1.0 from remaining qualification.
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

## Outside the current roadmap

- Ghostty configuration compatibility or importing Ghostty's native Zig core/renderer.
- Third-party plugins, arbitrary script loading, or a public extension ecosystem.
- Full external esctest qualification. The curated conformance suite remains a
  required gate; passing it does not establish complete xterm/esctest conformance.
- Dedicated VoiceOver development and VoiceOver user testing. Existing macOS
  accessible text/selection APIs remain implemented; VoiceOver qualification is
  not claimed.

Sixel, image clipboard protocols, and custom shaders remain unsupported and are
not added to this plan. Signing, notarization, and publication continue to follow
[the release procedure](RELEASING.md); this plan does not change those gates or
promise a release date/version for planned features.
