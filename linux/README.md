# AkiTTY Experimental for Linux

An experimental Tauri/TypeScript desktop using **Linux-native PTYs and installed
bash/zsh**, with AkiTTY Web for the terminal display. It does not embed GNOME
Terminal, Konsole, or another terminal application. The native macOS app remains
separate; agent protocol and control primitives are shared Rust source.

This is an evaluation build, not a stable release. Windows amd64 uses the [separate Experimental wrapper](../windows/README.md).
See [scope and qualification](../docs/LINUX_EXPERIMENTAL.md).

## Build and run

Use Node 22+, npm, Rust 1.99.1, and Linux desktop development dependencies. On
Debian/Ubuntu:

```sh
sudo apt-get install build-essential pkg-config libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev librsvg2-dev patchelf bash zsh
npm ci --ignore-scripts --prefix linux
npm --prefix linux run desktop
```

Run these commands from the repository root. A regular desktop login must provide
`XDG_RUNTIME_DIR`; the application refuses to place its request endpoint in a
shared fallback directory. The app uses the installed shell selected in its UI.
Bundled hooks are loaded without editing user startup files.

For a local Debian package (including the `akitty-agent` companion):

```sh
npm --prefix linux run package
```

The output is under `linux/src-tauri/target/release/bundle/deb/` unless
`CARGO_TARGET_DIR` is set. Package generation and local testing do not publish a
release or configure automatic updates.
The Debian package name is `aki-tty-experimental`; the installed binaries are
`akitty-linux-experimental` and `akitty-agent`. Package qualification covers
Debian 12 ARM64 and Ubuntu 24.04 x86_64/ARM64 containers on native Linux hosts,
including actual installed-app tests under WebKitGTK/Xvfb. Physical desktop and
GPU qualification remain pending. Ubuntu 24.04 x86_64 verification is also
configured in CI.

## Agent workflow

1. Open an integrated bash/zsh terminal and wait for its prompt.
2. Click **Enable agent requests**. This permission is off at every launch.
3. Run `akitty-agent list` to obtain an opaque pane ID.
4. Run `akitty-agent request PANE 'git status'` and keep the caller connected.
5. Review the exact command, target pane, connecting PID and shell-reported
   directory. **Deny** is the default. Approval queues the command at most once.
6. Inspect its output and use **Reclaim terminal control**. Reclaim does not kill
   the running command; interrupt or close the pane separately if needed.

For development, the companion can be built without GUI dependencies:

```sh
cargo build --manifest-path linux/src-tauri/Cargo.toml --locked \
  --no-default-features --bin akitty-agent
linux/src-tauri/target/debug/akitty-agent list
```

The endpoint is `$XDG_RUNTIME_DIR/akitty-experimental/requests.sock`. Its private
directory is 0700, its socket and ownership lock are 0600, and kernel peer UID/PID
are checked. The listener rejects requests while disabled. An agent may only list
panes or request a command; there are no approval, raw input, grant, reclaim, or
audit-read endpoints. `--socket PATH` selects an explicit test/instance endpoint.
The framed protocol matches the request-only schema in
[native agent workflows](../docs/AGENT_NATIVE.md).

Requests expire after 120 seconds and are canceled on disconnect, half-close,
target removal, service disable or human reclaim. A 3-second cooldown follows a
prompt. Concurrent connections are closed. No request is automatically retried.
An uncertain dispatch requires human inspection. A receipt proves input was
queued, not that execution completed or succeeded.

## Local observations

Agent Overview separates host input ownership from unverified OSC 771/7501 program
reports and shell observations. Reports never approve a command. Command history
is bounded and stays in memory. The timeline records bounded private metadata in
the application data directory, with two 4 MiB segments, gap/retention markers,
and SHA-256 command fingerprints instead of command text. Fingerprints are not
strong anonymization. Exports create a new 0600 file and never overwrite a file.
The timeline previews the latest 200 retained events; file exports include both retained segments.
Recording failures latch for the app run and block new managed commands.

These controls govern the app's managed input path. They are not a process sandbox
and do not intercept an agent's unrelated subprocesses or filesystem access.

## Verification

`bash scripts/verify-linux.sh` runs the shared primitives, Linux host/IPC tests,
frontend build, desktop build/clippy and shell-hook tests. CI uses Ubuntu 24.04.
Physical input methods, desktop accessibility, Wayland, distro packaging and
long-running reliability require further qualification before stable release.

The real desktop test uses tauri-driver 2.1.0, WebKitWebDriver and Selenium 4.52.0:
start tauri-driver under the same user and `XDG_RUNTIME_DIR` as the test, set
`AKITTY_DESKTOP_BINARY` to the absolute application path, and run
`python linux/tests/desktop_smoke.py`. `AKITTY_AGENT_BINARY` selects the installed
companion when it is not next to the application. The test exercises both the
visible approval flow and real command effects, and produces screenshots.
