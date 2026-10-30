# AX TUI attribution

Source: https://github.com/defai-digital/ax-tui
Revision: 83ba423abb26e149382f622d06b0afcdb7416ff9
Source file: src/lib/commands.ts, CommandRegistry.search fuzzy ranking loop.

Akitty adapts the Unicode-normalized subsequence ranking algorithm into
`typescript/src/palette.ts`. The adaptation removes the Node EventEmitter,
renderer ownership, execution handlers and native renderer dependencies. Akitty
adds closed command IDs, input/output bounds and a versioned JSON envelope.
The full AX TUI package is not imported. See LICENSE in this directory.
