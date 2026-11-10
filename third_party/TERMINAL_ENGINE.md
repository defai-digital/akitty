# Terminal engine ownership and provenance

Native AkiTTY and AkiTTY Web use the independently authored MIT-licensed
`crates/akitty-vt`. Its parser, screens/history, Unicode clustering, protocol
state, key encoder and WASM interface are AkiTTY implementations. Native graphics,
PTY and host-policy code remains in `akitty-core`. Native Swift rendering and the
browser DOM/Canvas frontend are separate platform adapters.

The Alacritty terminal 0.26.0 and VTE 0.15.0 derived packages previously stored
here have been removed, including their recordings and parser/graphics mirror.
The Ghostty WASM and its build patch have also been removed. Git history retains
these previous implementations and their original notices. No upstream engine
implementation is compiled or bundled. Historical inspiration is not a runtime
dependency or a performance claim.

## Protocol inputs and ordinary libraries

Behavior is implemented from ECMA-48, xterm control-sequence documentation and the
public Kitty keyboard/graphics specifications. `placeholder_table.rs` is generated
from Unicode 6.0.0 `UnicodeData.txt`, SHA-256
`90b45b777346bef027556f9c6cb3ea5d7d745bd60d6762855c08d8a22d34f771`,
using `scripts/generate-placeholder-table.py`. The generated alphabet contains
297 numeric protocol facts. Its Unicode license is in `third_party/unicode/LICENSE`;
no Ghostty or Kitty implementation is an input to that generator.

Ordinary locked libraries remain dependencies: `unicode-width` 0.2.3 provides
Unicode 18.0 scalar/string width tables; `unicode-segmentation` 1.13.3 provides
Unicode 17.0 grapheme boundaries; `base64` handles OSC clipboard encoding.
Native preserves its scalar-width profile. Web enables streaming grapheme mode
2027 by default. These profiles share parser/screen code and explicit fixtures.
Other dependencies provide PTYs, image decoding, serialization and platform UI.
Their licenses are collected from the exact locked graph during app packaging.

## Qualification and maintenance

`cargo test --workspace --locked` covers authored protocol fixtures at every byte
boundary, deterministic edit/resize stress, native conformance, graphics and PTY
lifecycle. `scripts/test-vt-wasm.ts` runs the same fixtures in the actual WASM.
`scripts/verify.sh` also runs Clippy, Web/SDK/feature tests, real-browser tests,
Swift and ABI checks. It validates both the committed WASM and a fresh Rust build.
`scripts/check-engine-source.py` rejects obsolete dependencies, source trees,
artifacts and exports. `wasm-provenance.json` binds the artifact hash to the exact
owned engine inputs. Rebuild and stamp it when those inputs change.

The Web production modules were reauthored during this migration. Historical
Coder-derived tests and test helpers retain their MIT notice; see
`packages/akitty-web/PROVENANCE.md`. Historical copyright notices retained in root
licenses do not describe current engine authorship. Release notes describe past
releases and are not rewritten to hide provenance.

See `docs/ENGINE_MIGRATION.md` for scope and qualification and the Web README for
its 0.6 API migration. Complete terminal conformance and physical IME/platform
qualification remain ongoing product work, as with the previous engine.
