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
import type { SelectionCoordinates } from './selection-manager';

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


describe('CanvasRenderer background runs', () => {
  test('preserves rectangles and colors across inverse and selection boundaries', () => {
    const cell = (inverse = false): TerminalCell => ({
      codepoint: 65, flags: inverse ? CellFlags.INVERSE : 0, width: 1,
      fg_r: 40, fg_g: 50, fg_b: 60, bg_r: 10, bg_g: 20, bg_b: 30,
      hyperlink_id: 0, grapheme_len: 0,
    });
    const cells = [cell(), cell(), cell(true), cell(true), cell()];
    const paint = (selection: SelectionCoordinates | null, row = cells, selectionBackground?: string): [number, number, string][] => {
      const renderer = new CanvasRenderer(document.createElement('canvas'), { fontSize: 10,
        ...(selectionBackground ? { theme: { selectionBackground } } : {}) });
      const context = (renderer as any).ctx;
      const calls: [number, number, string][] = [];
      context.fillRect = (x: number, _y: number, width: number, _height: number) => { calls.push([x, width, context.fillStyle]); };
      (renderer as any).paintRow(row, 0, row.length, selection, () => '');
      return calls.slice(1);
    };
    expect(paint(null)).toEqual([
      [0, 16, 'rgb(10,20,30)'], [16, 16, 'rgb(40,50,60)'], [32, 8, 'rgb(10,20,30)'],
    ]);
    expect(paint({ startCol: 1, startRow: 0, endCol: 2, endRow: 0 })).toEqual([
      [0, 8, 'rgb(10,20,30)'], [8, 16, DEFAULT_THEME.selectionBackground],
      [24, 8, 'rgb(40,50,60)'], [32, 8, 'rgb(10,20,30)'],
    ]);
    cells[1] = cell(true);
    cells[1].fg_r = 10; cells[1].fg_g = 20; cells[1].fg_b = 30;
    const merged = [[0, 16, 'rgb(10,20,30)'], [16, 16, 'rgb(40,50,60)'], [32, 8, 'rgb(10,20,30)']];
    expect(paint(null)).toEqual(merged);
    expect(paint({ startCol: 1, startRow: 0, endCol: 1, endRow: 0 }, cells, 'rgb(10,20,30)')).toEqual(merged);
    expect(paint({ startCol: 0, startRow: 0, endCol: 0, endRow: 0 }, cells, 'rgb(10,20,30)')).toEqual(merged);
    const styled = [cell(), cell()];
    styled[0]!.flags = CellFlags.BOLD;
    expect(paint(null, styled)).toEqual([[0, 16, 'rgb(10,20,30)']]);
    const different = [cell(), cell(), cell(true), cell(true)];
    different[1]!.bg_b = 31; different[3]!.fg_b = 61;
    expect(paint(null, different)).toEqual([
      [0, 8, 'rgb(10,20,30)'], [8, 8, 'rgb(10,20,31)'],
      [16, 8, 'rgb(40,50,60)'], [24, 8, 'rgb(40,50,61)'],
    ]);
  });
});
