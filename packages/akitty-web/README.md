# AkiTTY Web

`@ax-code/akitty-web` is the in-app canvas terminal for AX Code Desktop. It is part of the AkiTTY project but is a
separate implementation from the macOS Rust/Swift terminal: it renders to an HTML canvas and parses terminal output
with Ghostty's VT parser compiled to WebAssembly.

It is derived from [coder/ghostty-web](https://github.com/coder/ghostty-web) v0.4.0 and exposes an xterm.js-style API.
Provenance, hashes and every local change are recorded in [UPSTREAM.md](UPSTREAM.md).

## Status

- The package is **private** (`"private": true`) and is **not published** to npm or GitHub Packages. Consume it from
  source, for example through a workspace or Git dependency.
- It exports TypeScript source (`lib/index.ts`) and `ghostty-vt.wasm`; there is no prebuilt bundle. The consuming
  application's build compiles it.
- It was first developed in `defai-digital/ax-code-desktop` (`desktop/packages/akitty-web`) and migrated here.
  Desktop's copy is not updated automatically, so the two can diverge until Desktop switches to this one.
- The wasm file is the upstream release artifact, not a local rebuild. A rebuild has not been compared byte for byte.
- Comments and examples inside `lib/` still use upstream names (`ghostty-web`, `@cmux/ghostty-terminal`). They are left
  as-is to keep `lib/` close to upstream; the package name to import is `@ax-code/akitty-web`.

## Usage

```ts
import { init, Terminal } from "@ax-code/akitty-web"

await init() // loads ghostty-vt.wasm once
const term = new Terminal({ fontSize: 14, lineHeight: 1.15 })
term.open(document.getElementById("terminal")!)
term.write("Hello\r\n")
term.onData((data) => {
  /* send keystrokes to the shell or PTY */
})
```

`@ax-code/akitty-web/ghostty-vt.wasm` is also exported for hosts that need to serve the wasm file themselves.
Addons (such as `lib/addons/fit.ts`) follow the xterm.js addon interface.

Differences from upstream v0.4.0:

- `lineHeight` sets the row height as a multiple of the glyph height. Upstream ignored it.
- Empty, out-of-range and surrogate cell codepoints render as a space instead of throwing.

## Development

Requires Node 22+. The package has its own `package-lock.json` and is installed separately from the repository root.

```sh
cd packages/akitty-web
npm ci --ignore-scripts
npm run type-check
npm test          # Vitest with Happy DOM; upstream bun:test files run through test/bun-test-shim.ts
```

From the repository root, `scripts/verify.sh` runs the same install, type-check and tests.

`npm run build:wasm` rebuilds `ghostty-vt.wasm` from the pinned Ghostty commit and `patches/ghostty-wasm-api.patch`. It
needs Zig 0.15.2 and network access. Zig is needed **only** for this step; building and running AkiTTY and this
package does not require it. If the patch, pin or wasm changes, update the hashes in `UPSTREAM.md`.

## Licenses

MIT. See [LICENSE](LICENSE) (ghostty-web, Copyright (c) 2025 Coder) and [LICENSE-GHOSTTY](LICENSE-GHOSTTY). Record any
modification of `lib/` or the patch in [UPSTREAM.md](UPSTREAM.md).
