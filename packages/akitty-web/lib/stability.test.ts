/**
 * Stability regressions: bounded replies, scrollback budget, wasm handle lifetime, size validation.
 */

import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { AkittyEngine } from './engine';
import { Terminal } from './terminal';
import { createIsolatedTerminal } from './test-helpers';

describe('terminal replies', () => {
  test('every queued reply is drained in one write', async () => {
    const engine = await AkittyEngine.load();
    const wasm = engine.createTerminal(80, 24);
    // 200 cursor-position reports exceed the old single 256-byte read.
    wasm.write('\x1b[6n'.repeat(200));
    const reply = wasm.readResponse();
    expect(reply).toBe('\x1b[1;1R'.repeat(200));
    expect(wasm.hasResponse()).toBeFalsy();
    wasm.free();
  });

  test('a reply flood is capped instead of queued for later', async () => {
    const engine = await AkittyEngine.load();
    const wasm = engine.createTerminal(80, 24);
    wasm.write('\x1b[6n'.repeat(50_000));
    const reply = wasm.readResponse(1024);
    expect(reply!.length).toBe(1024);
    // The excess is discarded, not delivered on a later write as fake input.
    expect(wasm.hasResponse()).toBeFalsy();
    expect(wasm.readResponse()).toBeNull();
    wasm.free();
  });
});

describe('wasm handle lifetime', () => {
  test('free is idempotent and later calls are inert', async () => {
    const engine = await AkittyEngine.load();
    const wasm = engine.createTerminal(80, 24);
    wasm.write('é hello');
    wasm.update();
    expect(wasm.getGrapheme(0, 0)).not.toBeNull();
    wasm.free();
    expect(wasm.isFreed).toBe(true);
    expect(() => wasm.free()).not.toThrow();
    expect(() => wasm.write('after free')).not.toThrow();
    expect(wasm.getGrapheme(0, 0)).toBeNull();
    expect(wasm.readResponse()).toBeNull();
  });

  test('large writes are fed in chunks and still parse across chunk boundaries', async () => {
    const engine = await AkittyEngine.load();
    const wasm = engine.createTerminal(80, 24);
    const big = new Uint8Array((1 << 20) + 3).fill(0x61);
    // An escape sequence straddling the 1 MiB chunk boundary must still be recognised.
    big.set(new TextEncoder().encode('\x1b[6n'), (1 << 20) - 2);
    wasm.write(big);
    expect(wasm.readResponse()).toMatch(/^\x1b\[\d+;\d+R$/);
    wasm.free();
  });
});

describe('scrollback budget', () => {
  test('line counts are converted to a byte budget that keeps at least that many lines', async () => {
    const term = await createIsolatedTerminal({ cols: 80, rows: 24, scrollback: 5000 });
    const container = document.createElement('div');
    document.body.appendChild(container);
    term.open(container);
    let text = '';
    for (let i = 0; i < 8000; i++) text += `line ${i}\r\n`;
    term.write(text);
    expect(term.wasmTerm!.getScrollbackLength()).toBeGreaterThanOrEqual(5000);
    term.dispose();
    container.remove();
  });

  test('zero or invalid scrollback never maps to the unlimited budget', () => {
    expect(Terminal.scrollbackBytes(0, 80)).toBe(1);
    expect(Terminal.scrollbackBytes(Number.NaN, 80)).toBe(1);
    expect(Terminal.scrollbackBytes(-5, 80)).toBe(1);
    expect(Terminal.scrollbackBytes(1e12, 500)).toBe(512 * 1024 * 1024);
  });
});

describe('terminal lifecycle hygiene', () => {
  let container: HTMLElement;
  beforeEach(() => {
    container = document.createElement('div');
    document.body.appendChild(container);
  });
  afterEach(() => container.remove());

  test('resize rejects sizes that are not a sane grid', async () => {
    const term = await createIsolatedTerminal({ cols: 80, rows: 24 });
    term.open(container);
    for (const [cols, rows] of [[0, 24], [80, 0], [Number.NaN, 24], [80.5, 24], [100_000, 24]]) {
      expect(() => term.resize(cols, rows)).toThrow(RangeError);
    }
    expect(term.cols).toBe(80);
    term.resize(100, 30);
    expect(term.cols).toBe(100);
    term.dispose();
  });

  test('dispose removes the tabindex open() added but keeps a host-provided one', async () => {
    const term = await createIsolatedTerminal();
    term.open(container);
    expect(container.getAttribute('tabindex')).toBe('0');
    term.dispose();
    expect(container.hasAttribute('tabindex')).toBe(false);

    const hosted = document.createElement('div');
    hosted.setAttribute('tabindex', '-1');
    document.body.appendChild(hosted);
    const other = await createIsolatedTerminal();
    other.open(hosted);
    other.dispose();
    expect(hosted.getAttribute('tabindex')).toBe('-1');
    hosted.remove();
  });

  test('a throwing onData listener does not break DSR replies on later writes', async () => {
    const term = await createIsolatedTerminal();
    term.open(container);
    const original = globalThis.reportError;
    globalThis.reportError = () => {};
    let replies = '';
    try {
      term.onData(() => {
        throw new Error('ipc closed');
      });
      term.onData((data) => {
        replies += data;
      });
      term.write('\x1b[6n');
      term.write('\x1b[6n');
    } finally {
      globalThis.reportError = original;
    }
    expect(replies).toBe('\x1b[1;1R\x1b[1;1R');
    term.dispose();
  });
});


describe('runtime terminal configuration', () => {
  test('theme changes recolor cached viewport and history without resetting state', async () => {
    const term = await createIsolatedTerminal({ cols: 8, rows: 2 });
    const container = document.createElement('div');
    term.open(container);
    try {
      term.write('abc\x1b[31mR\x1b[0m\r\nsecond\r\nlive\x1b]2;retained\x07');
      term.wasmTerm!.getLineView(0);
      const history = term.getScrollbackLength();
      term.options.theme = { foreground: '#123456', background: '#234567', red: '#abcdef', cursor: '#fedcba' };
      expect(term.wasmTerm!.getColors()).toEqual({ foreground: { r: 18, g: 52, b: 86 },
        background: { r: 35, g: 69, b: 103 }, cursor: { r: 254, g: 220, b: 186 } });
      expect(term.wasmTerm!.getLineView(0)![0]).toMatchObject({ fg_r: 18, fg_g: 52, fg_b: 86, bg_r: 35, bg_g: 69, bg_b: 103 });
      expect(term.getScrollbackLine(0)![3]).toMatchObject({ fg_r: 171, fg_g: 205, fg_b: 239 });
      expect(term.getScrollbackLength()).toBe(history);
      expect(term.title).toBe('retained');
      expect(term.buffer.active.getLine(history)?.translateToString(true)).toBe('second');
      term.write('\x1b]10;#ff0000\x07');
      term.options.theme = { foreground: '#654321' };
      expect(term.wasmTerm!.getColors().foreground).toEqual({ r: 255, g: 0, b: 0 });
      term.write('\x1b]110\x07');
      expect(term.wasmTerm!.getColors().foreground).toEqual({ r: 101, g: 67, b: 33 });
    } finally { term.dispose(); }
  });

  test('alternate wheel input honors mode 1007, application cursor mode and delta units', async () => {
    const term = await createIsolatedTerminal();
    const container = document.createElement('div');
    term.open(container);
    const sent: string[] = [];
    term.onData(data => sent.push(data));
    try {
      term.write('\x1b[?1049h\x1b[?1007l');
      container.dispatchEvent(new WheelEvent('wheel', { deltaY: 120 }));
      expect(sent).toEqual([]);
      term.write('\x1b[?1007h\x1b[?1h');
      container.dispatchEvent(new WheelEvent('wheel', { deltaY: 1, deltaMode: 1 }));
      expect(sent).toEqual(['\x1bOB']);
      sent.length = 0;
      for (let i = 0; i < 4; i++) container.dispatchEvent(new WheelEvent('wheel', { deltaY: -8.25 }));
      expect(sent).toEqual(['\x1bOA']);
    } finally { term.dispose(); }
  });

  test('reset and disabled mouse tracking discard a held mouse button', async () => {
    const term = await createIsolatedTerminal();
    const container = document.createElement('div');
    document.body.appendChild(container);
    term.open(container);
    const sent: string[] = [];
    term.onData(data => sent.push(data));
    try {
      for (const reset of [() => term.reset(), () => term.write('\x1b[?1000l')]) {
        term.write('\x1b[?1000h\x1b[?1006h');
        container.querySelector('canvas')!.dispatchEvent(new MouseEvent('mousedown', { button: 0, bubbles: true }));
        expect(sent.length).toBeGreaterThan(0);
        reset(); sent.length = 0;
        document.dispatchEvent(new MouseEvent('mouseup', { button: 0, bubbles: true }));
        expect(sent).toEqual([]);
      }
    } finally { term.dispose(); container.remove(); }
  });
});
