# AX TUI attribution

Source: https://github.com/defai-digital/ax-code
Package: `packages/ax-tui` (`@defai-digital/ax-tui`)
Revision: 8eb6a536f69d3e200a23c2613ee217d6cd430091
Checked against ax-code `1f8797f5fbd5669b5baad780705b7019a7d16a82`; this file is unchanged there.
Source file: `packages/ax-tui/src/lib/commands.ts`, `CommandRegistry.search` fuzzy ranking loop.

The standalone repository `https://github.com/defai-digital/ax-tui` no longer resolves.
AX TUI is maintained in the AX Code monorepo.

Akitty adapts the Unicode-normalized subsequence ranking algorithm into
`typescript/src/palette.ts`. It does not depend on, import, or bundle
`@defai-digital/ax-tui`. The adaptation removes the Node EventEmitter,
renderer ownership, execution handlers and native renderer dependencies. Akitty
adds closed command IDs, its own input and output bounds, a contiguous-match
bonus, and a versioned JSON envelope. The full AX TUI package is not imported.
See LICENSE in this directory.
