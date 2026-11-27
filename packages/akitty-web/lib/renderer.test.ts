/**
 * Tests for Canvas Renderer
 *
 * Note: Most renderer tests are visual and require a browser environment.
 * These tests verify non-visual aspects like theme configuration.
 * Full visual tests are in examples/renderer-demo.html
 */

import { describe, expect, test } from 'bun:test';
import { CanvasRenderer, DEFAULT_THEME } from './renderer';
import type { IRenderable, IScrollbackProvider } from './renderer';
import { CellFlags, type TerminalCell } from './types';

describe('CanvasRenderer', () => {
  describe('Default Theme', () => {
    test('has all required ANSI colors', () => {
      expect(DEFAULT_THEME.black).toBe('#000000');
      expect(DEFAULT_THEME.red).toBe('#cd3131');
      expect(DEFAULT_THEME.green).toBe('#0dbc79');
      expect(DEFAULT_THEME.yellow).toBe('#e5e510');
      expect(DEFAULT_THEME.blue).toBe('#2472c8');
      expect(DEFAULT_THEME.magenta).toBe('#bc3fbc');
      expect(DEFAULT_THEME.cyan).toBe('#11a8cd');
      expect(DEFAULT_THEME.white).toBe('#e5e5e5');
    });

    test('has all bright ANSI colors', () => {
      expect(DEFAULT_THEME.brightBlack).toBe('#666666');
      expect(DEFAULT_THEME.brightRed).toBe('#f14c4c');
      expect(DEFAULT_THEME.brightGreen).toBe('#23d18b');
      expect(DEFAULT_THEME.brightYellow).toBe('#f5f543');
      expect(DEFAULT_THEME.brightBlue).toBe('#3b8eea');
      expect(DEFAULT_THEME.brightMagenta).toBe('#d670d6');
      expect(DEFAULT_THEME.brightCyan).toBe('#29b8db');
      expect(DEFAULT_THEME.brightWhite).toBe('#ffffff');
    });

    test('has foreground and background colors', () => {
      expect(DEFAULT_THEME.foreground).toBe('#d4d4d4');
      expect(DEFAULT_THEME.background).toBe('#1e1e1e');
    });

    test('has cursor colors', () => {
      expect(DEFAULT_THEME.cursor).toBe('#ffffff');
      expect(DEFAULT_THEME.cursorAccent).toBe('#1e1e1e');
    });

    test('has selection colors', () => {
      // Selection colors are now solid (not semi-transparent overlay)
      // AkittyEngine-style: selection bg = foreground color, selection fg = background color
      expect(DEFAULT_THEME.selectionBackground).toBe('#d4d4d4');
      expect(DEFAULT_THEME.selectionForeground).toBe('#1e1e1e');
    });
  });

  describe('Theme Color Format', () => {
    test('all colors are valid hex strings', () => {
      const hexPattern = /^#[0-9a-f]{6}$/i;

      expect(DEFAULT_THEME.black).toMatch(hexPattern);
      expect(DEFAULT_THEME.foreground).toMatch(hexPattern);
      expect(DEFAULT_THEME.background).toMatch(hexPattern);
      expect(DEFAULT_THEME.cursor).toMatch(hexPattern);
    });
  });
});

describe('CanvasRenderer scrollback row mapping', () => {
  test('keeps fractional viewport rows inside the scrollback bounds', () => {
    const canvas = document.createElement('canvas');
    const renderer = new CanvasRenderer(canvas, { fontSize: 10, lineHeight: 1 });

    const scrollbackLength = 10;
    const requestedOffsets: number[] = [];
    const scrollback: IScrollbackProvider = {
      getScrollbackLength: () => scrollbackLength,
      getScrollbackLine: (offset) => {
        requestedOffsets.push(offset);
        return null;
      },
    };

    // Every screen row is empty, so only the scrollback boundary rows are mapped.
    const buffer: IRenderable = {
      getLine: () => null,
      getCursor: () => ({ x: 0, y: 0, visible: false }),
      getDimensions: () => ({ cols: 80, rows: 24 }),
      isRowDirty: () => true,
      isDirty: () => true,
      clearDirty: () => {},
    };

    // A fractional viewport offset occurs during smooth scrolling. Rows above floor(3.5) come from scrollback.
    renderer.render(buffer, true, 3.5, scrollback, 0);

    expect(requestedOffsets.length).toBeGreaterThan(0);
    expect(requestedOffsets.every((offset) => offset >= 0 && offset < scrollbackLength)).toBe(true);
  });
});


describe('CanvasRenderer row hashing', () => {
  test('matches the field-by-field hash reference and complex-glyph exits', () => {
    const cells: TerminalCell[] = Array.from({ length: 200 }, (_, index) => ({
      codepoint: 65 + index % 26,
      flags: index * 3 & 0xff & ~CellFlags.ITALIC,
      width: index % 7 === 0 ? 2 : 1,
      fg_r: index * 17 & 255, fg_g: index * 29 & 255, fg_b: index * 31 & 255,
      bg_r: index * 37 & 255, bg_g: index * 41 & 255, bg_b: index * 43 & 255,
      hyperlink_id: 0, grapheme_len: 0,
      underline_style: index % 6,
      underline_color: index % 4 === 0 ? undefined : index * 0x010203,
    }));
    const reference = (): number | undefined => {
      let hash = 2166136261;
      for (const cell of cells) {
        if (cell.codepoint > 127 || cell.grapheme_len || cell.flags & CellFlags.ITALIC) return undefined;
        for (const value of [cell.codepoint, cell.flags, cell.width, cell.fg_r, cell.fg_g, cell.fg_b, cell.bg_r, cell.bg_g, cell.bg_b, cell.underline_style ?? 0, cell.underline_color ?? 0]) {
          hash = Math.imul(hash ^ value, 16777619);
        }
      }
      return hash >>> 0;
    };
    const renderer = new CanvasRenderer(document.createElement('canvas'));
    const rowHash = (): number | undefined => (renderer as any).rowHash({ getLine: () => cells }, 0);
    expect(rowHash()).toBe(reference());
    cells[0]!.codepoint = 128;
    expect(rowHash()).toBeUndefined();
    cells[0]!.codepoint = 65; cells[0]!.grapheme_len = 1;
    expect(rowHash()).toBeUndefined();
    cells[0]!.grapheme_len = 0; cells[0]!.flags = CellFlags.ITALIC;
    expect(rowHash()).toBeUndefined();
  });
});
