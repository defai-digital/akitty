# Contributing to AkiTTY

Start with the [architecture](docs/ARCHITECTURE.md), [native ABI](docs/ABI.md), and
[Web provenance](packages/akitty-web/PROVENANCE.md). They define component
ownership and compatibility requirements. The native app requires Apple Silicon
and macOS 27.2 or later; the Web terminal has its own browser and host boundaries.

## Repository map

| Path | Responsibility |
| --- | --- |
| `crates/akitty-vt/` | Shared Rust parser, terminal state, screens, keyboard encoding, and WASM exports. No PTY, filesystem, UI, or wall clock. |
| `crates/akitty-agent-core/` | Shared agent protocols, command authority, shell observations, program chrome/status, and Unix child cleanup. Hosts create PTYs and perform I/O. |
| `crates/akitty-core/` | Native session registry, PTY workers, snapshots, graphics, and versioned C ABI. Composes the two crates above. |
| `include/` | Public native C header. `macos/Bridge/` contains its verified mirror and Swift module map. |
| `macos/` | Swift package, app metadata, entitlements, native UI, agent client, and MCP bridge. |
| `typescript/` | Bundled command-palette ranking, evaluated by JavaScriptCore. Swift owns command execution. |
| `packages/akitty-web/` | Private source package: browser canvas terminal over the shared VT engine compiled to WASM. The embedding host owns the PTY. |
| `packages/akitty-sdk/` | Separately versioned program-integration SDK and host output queue. |
| `distribution/` | Read-only download gateway and its tests. Deployment is separate from app packaging. |
| `scripts/` | Build, verification, ABI smoke tests, installer, provenance, and release tooling with their tests. |
| `benchmarks/` | Workload definitions, recorded baseline, and measurement instructions. |
| `docs/` | Architecture, contracts, workflow guides, compatibility, roadmap, and versioned release notes. |
| `assets/` | Brand artwork and icon sources. |
| `third_party/` | License notices and engine/protocol provenance; not vendored terminal implementations. |

Within `macos/Sources/`, `Akitty` is the app entry point, `AkittyKit` owns the
native implementation, `AgentIPC` owns the local transport, `AkittyAgent` is the
command-line client, and `AkittyMCP` adapts it to MCP. Their tests live under
`macos/Tests/`.

`AkittyKit/Application/` groups application lifecycle and menus, terminal windows
and panes, tab controls, the find bar, and the command palette into focused files.
Rendering, terminal input/accessibility, agent workflows, preferences, and profiles
remain in their existing files in `AkittyKit`. Keep a whole type together when
splitting files so its private state stays private. Subfolders do not create new
Swift targets or change the app's resource lookup.

## Dependencies and package management

The native dependency direction is Swift → C ABI → `akitty-core` → `akitty-vt`
and `akitty-agent-core`. The Web frontend uses only the VT engine's WASM boundary;
it does not inherit native approval, IPC, or PTY services. Keep the program SDK
independent of the app UI and terminal renderer.

Use **npm** for all JavaScript packages. The root, Web, and SDK packages have
separate `package-lock.json` files and installations; they are not an npm
workspace. `pnpm-workspace.yaml` only denies esbuild install scripts for incidental
pnpm use; it is not an alternative dependency lock or build workflow.

Rust uses the root Cargo workspace and `Cargo.lock`, with Rust 1.99.1 pinned in
`rust-toolchain.toml`. Swift dependencies are resolved in `macos/Package.resolved`.
Preserve these locks and use the repository scripts to select the toolchain.

## Build and test

Use Node 22.18 or later and the Xcode 27.2 toolchain for the native app. From the
repository root, the complete required gate is:

```sh
scripts/verify.sh
scripts/build-app.sh release
git diff --exit-code -- macos/Sources/AkittyKit/Resources/features.js
```

The gate builds and tests Rust, checks Clippy, validates the native ABI and WASM,
runs a benchmark smoke check, builds/tests the palette and SDK, runs Web unit and
real-browser tests, runs Swift and shell/IPC tests, and audits release tooling and
public files. It installs npm dependencies with `npm ci --ignore-scripts`.

For a shorter development loop, run the commands for the component being changed;
the complete gate still applies before merging.

| Component | Focused commands from the repository root |
| --- | --- |
| Native Rust | `cargo build --workspace --locked`; `cargo test --workspace --locked` |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` |
| Swift | Build Rust first, then `swift test --package-path macos`. Set `AKITTY_RUST_LIB_DIR` when using a different Rust library directory. |
| Palette and gateway | `npm ci --ignore-scripts`; `npm run build`; `npm test` |
| Web | `npm ci --ignore-scripts --prefix packages/akitty-web`; `npm --prefix packages/akitty-web run type-check`; `npm --prefix packages/akitty-web test` |
| Web browsers | `npm --prefix packages/akitty-web exec -- playwright install chromium firefox webkit`; `npm --prefix packages/akitty-web run test:browser` |
| Program SDK | `npm ci --ignore-scripts --prefix packages/akitty-sdk`; `npm --prefix packages/akitty-sdk test` |

Rust unit tests stay next to the implementation; cross-boundary native cases live
in `crates/akitty-core/tests/`, and shared VT contracts in `crates/akitty-vt/tests/`.
Web unit tests are colocated in `lib/`; `browser/` contains Playwright fixtures and
specs. Web test setup and its legacy Bun API shim live in `test/`. Root palette,
SDK, and gateway tests use Node's test runner. Preserve historical test notices.

## Generated files and local output

| Tracked artifact | How to update it |
| --- | --- |
| `macos/Sources/AkittyKit/Resources/features.js` | Run `npm run build` and commit the resulting bundle with its source changes. |
| `macos/Bridge/akitty.h` | Keep byte-identical to `include/akitty.h`; the gate runs `cmp`. |
| `packages/akitty-web/akitty-vt.wasm`, `wasm-provenance.json`, and `ENGINE_LICENSES.txt` | Follow the [Web build verification procedure](packages/akitty-web/PROVENANCE.md#build-verification); rebuild and stamp the artifact together. |
| `crates/akitty-core/src/placeholder_table.rs` | Generated by `scripts/generate-placeholder-table.py`; retain the documented Unicode data provenance. |

`target/`, `build/`, `macos/.build/`, package `node_modules/`, SDK `dist/`, and
browser test reports are ignored local output. Packaged resources are explicitly
copied by `scripts/build-app.sh`: `features.js` loads from the app bundle, not a
SwiftPM resource bundle. Keep `AkittyKit/Resources/` at its existing path.

App packaging produces `build/Akitty.app`. Signing, notarization, app publication,
and SDK publication are separate operations described in
[RELEASING.md](docs/RELEASING.md). A successful build does not publish a release.

## Documentation and change scope

Use [ARCHITECTURE.md](docs/ARCHITECTURE.md) for ownership and design decisions,
[ABI.md](docs/ABI.md) for native contracts, and component READMEs for usage.
[COMPATIBILITY.md](docs/COMPATIBILITY.md) records qualification limits;
[ROADMAP.md](docs/ROADMAP.md) records planned work. Put user-visible changes in
`docs/releases/unreleased.md` and versioned release notes when releasing.

Keep refactors focused and preserve unrelated work. Avoid repository-wide
formatting changes. New boundary behavior needs bounded validation and relevant
regression coverage. Do not commit credentials, machine paths, private development
notes, or build output; `scripts/check_public.py` audits the exact Git index or
committed tree before publication.
