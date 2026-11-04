import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const wasmPath = process.argv[2] ?? new URL('../build/akitty-vt.wasm', import.meta.url);
const module = await WebAssembly.compile(await readFile(wasmPath));
assert.deepEqual(WebAssembly.Module.imports(module), [], 'portable VT must require no OS imports');
const { exports: api } = await WebAssembly.instantiate(module);
assert.equal(api.akitty_vt_abi_version(), 1);
const id = api.akitty_vt_create(12, 3, 10);
assert.ok(id);
const length = 4096;
const pointer = api.akitty_vt_alloc(length);
assert.ok(pointer);
const write = (text, now = 0) => {
  const bytes = new TextEncoder().encode(text);
  new Uint8Array(api.memory.buffer, pointer, bytes.length).set(bytes);
  assert.equal(api.akitty_vt_write(id, pointer, bytes.length, now), 1);
};
const line = (row) => {
  const size = api.akitty_vt_line(id, row, pointer, length);
  const data = new DataView(api.memory.buffer, pointer, size);
  return Array.from({ length: size / 32 }, (_, col) => data.getUint32(col * 32 + 20, true) === 0 ? '' : String.fromCodePoint(data.getUint32(col * 32, true) || 32)).join('');
};
write('ab中e\u0301\x1b[2;3H\x1b[38;2;1;2;3mZ\x1b[6n');
assert.equal(line(0), 'ab中e       ');
assert.equal(line(1), '  Z         ');
assert.equal(api.akitty_vt_get(id, 2), 3);
assert.equal(api.akitty_vt_get(id, 3), 1);
let size = api.akitty_vt_replies(id, pointer, length);
assert.equal(new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, size)), '\x1b[2;4R');
write('\x1b[>5u\x1b[?1049halt\x1b[?1049l');
assert.equal(api.akitty_vt_get(id, 8), 5);
write('\x1b[?2026h\x1b[6n', 100);
assert.equal(api.akitty_vt_get(id, 11), 0);
assert.equal(api.akitty_vt_tick(id, 251), 1);
assert.ok(api.akitty_vt_get(id, 11) > 0);
assert.equal(api.akitty_vt_tick(id, 300), 0);
assert.equal(api.akitty_vt_resize(id, 16, 4), 1);
assert.equal(api.akitty_vt_get(id, 0), 16);
assert.equal(api.akitty_vt_resize(id, 0, 4), 0);
api.akitty_vt_color(id, 256, 0x123456);
write('\x1b]10;#abcdef\x07');
assert.equal(api.akitty_vt_get(id, 9), 0xabcdef);
write('\x1b]110\x07');
assert.equal(api.akitty_vt_get(id, 9), 0x123456, 'OSC reset restores the configured theme');
write('\x1b]12;#654321\x07');
assert.equal(api.akitty_vt_get(id, 18), 0x654321);
assert.equal(api.akitty_vt_get(id, 9), 0x123456, 'cursor color must not change foreground');
write('\x1b]112\x07');
assert.equal(api.akitty_vt_get(id, 18) >>> 0, 0xffffffff);
api.akitty_vt_clean(id);
write('\x1b[?5h');
assert.equal(api.akitty_vt_dirty(id, 0), 1, 'reverse video invalidates unchanged cells');
api.akitty_vt_line(id, 0, pointer, length);
assert.equal(new DataView(api.memory.buffer, pointer, 32).getUint32(12, true) & 8, 8);
write('\x1bc');
assert.equal(api.akitty_vt_get(id, 9), 0x123456, 'RIS preserves the configured theme');
assert.equal(api.akitty_vt_destroy(id), 1);
assert.equal(api.akitty_vt_write(id, pointer, 1, 400), 0, 'stale handles stay invalid');
assert.equal(api.akitty_vt_free(pointer, length - 1), 0);
assert.equal(api.akitty_vt_free(pointer, length), 1);
assert.equal(api.akitty_vt_free(pointer, length), 0);
const keyPointer = api.akitty_vt_alloc(length);
for (const [code, expected] of [[9, '\t'], [13, '\r'], [27, '\x1b'], [127, '\x7f'], [57414, '\r']]) {
  const count = api.akitty_vt_key(code, 0, 0, 4, 1, 1024, keyPointer, 0, keyPointer, length);
  assert.equal(new TextDecoder().decode(new Uint8Array(api.memory.buffer, keyPointer, count)), expected, `Ctrl key ${code}`);
}
assert.equal(api.akitty_vt_free(keyPointer, length), 1);


const fixtures = JSON.parse(await readFile(new URL('../crates/akitty-vt/tests/fixtures/streams.json', import.meta.url), 'utf8'));
const encoder = new TextEncoder();
const decoder = new TextDecoder();
const scratch = api.akitty_vt_alloc(length);
for (const fixture of fixtures) {
  const bytes = encoder.encode(fixture.input);
  for (let split = 0; split <= bytes.length; split++) {
    const terminal = api.akitty_vt_create(fixture.cols, fixture.rows, fixture.history_limit);
    assert.ok(terminal);
    for (const chunk of [bytes.subarray(0, split), bytes.subarray(split)]) {
      new Uint8Array(api.memory.buffer, scratch, chunk.length).set(chunk);
      assert.equal(api.akitty_vt_write(terminal, scratch, chunk.length, 0), 1);
    }
    const lines = [];
    for (let row = 0; row < fixture.rows; row++) {
      const count = api.akitty_vt_line(terminal, row, scratch, length);
      const view = new DataView(api.memory.buffer, scratch, count);
      const widths = Array.from({ length: fixture.cols }, (_, col) => view.getUint32(col * 32 + 20, true));
      let text = '';
      for (let col = 0; col < fixture.cols; col++) {
        if (widths[col] === 0) continue;
        const count = api.akitty_vt_text(terminal, row, col, 0, scratch, length);
        text += decoder.decode(new Uint8Array(api.memory.buffer, scratch, count));
      }
      lines.push(text);
    }
    const context = `${fixture.name}, split ${split}`;
    assert.deepEqual(lines, fixture.lines, context);
    assert.deepEqual([api.akitty_vt_get(terminal, 2), api.akitty_vt_get(terminal, 3)], fixture.cursor, context);
    assert.equal(api.akitty_vt_get(terminal, 6), fixture.history, context);
    const count = api.akitty_vt_replies(terminal, scratch, length);
    assert.equal(decoder.decode(new Uint8Array(api.memory.buffer, scratch, count)), fixture.replies, context);
    assert.equal(api.akitty_vt_destroy(terminal), 1);
  }
}
// Explicit buffer inspection must preserve the active screen and pending events.
const feedTerminal = (handle, input) => {
  const bytes = encoder.encode(input);
  new Uint8Array(api.memory.buffer, scratch, bytes.length).set(bytes);
  assert.equal(api.akitty_vt_write(handle, scratch, bytes.length, 0), 1);
};
const retained = api.akitty_vt_create(8, 2, 10);
feedTerminal(retained, 'a中é\r\nb\r\nc\x1b[?1049halt中éabcdefg');
const revision = api.akitty_vt_get(retained, 7);
assert.equal(api.akitty_vt_buffer_get(retained, 0, 6), 1);
assert.equal(api.akitty_vt_buffer_get(retained, 1, 6), 0);
assert.equal(api.akitty_vt_buffer_get(retained, 0, 2), 1);
assert.equal(api.akitty_vt_buffer_get(retained, 1, 2), 5);
assert.equal(api.akitty_vt_buffer_line(retained, 0, -1, scratch, length), 8 * 32);
assert.equal(new DataView(api.memory.buffer, scratch, 32).getUint32(0, true), 97);
let count = api.akitty_vt_buffer_text(retained, 0, -1, 3, scratch, length);
assert.equal(decoder.decode(new Uint8Array(api.memory.buffer, scratch, count)), 'é');
assert.equal(api.akitty_vt_buffer_wrapped(retained, 1, 1), 1);
assert.equal(api.akitty_vt_get(retained, 5), 1);
assert.equal(api.akitty_vt_get(retained, 7), revision);
feedTerminal(retained, '\x1b[?1049l');
assert.equal(api.akitty_vt_buffer_line(retained, 1, 0, scratch, length), 8 * 32);
assert.equal(api.akitty_vt_get(retained, 5), 0);
assert.equal(api.akitty_vt_buffer_line(retained, 2, 0, scratch, length), 0);
assert.equal(api.akitty_vt_buffer_line(retained, 0, -100, scratch, length), 0);
assert.equal(api.akitty_vt_buffer_text(retained, 0, 0, 999, scratch, length), 0);
assert.equal(api.akitty_vt_destroy(retained), 1);
assert.equal(api.akitty_vt_buffer_get(retained, 0, 6), 0);
const reflow = api.akitty_vt_create(8, 3, 10);
feedTerminal(reflow, 'ab中xyz\x1b[1;4H');
assert.equal(api.akitty_vt_resize(reflow, 3, 4), 1);
assert.deepEqual([api.akitty_vt_get(reflow, 2), api.akitty_vt_get(reflow, 3)], [1, 1]);
assert.equal(api.akitty_vt_destroy(reflow), 1);
const syncModes = api.akitty_vt_create(8, 2, 10);
feedTerminal(syncModes, '\x1b[?25l\x1b[?2026;25habc\x1b[6n');
assert.ok(api.akitty_vt_deadline(syncModes) >= 0);
assert.equal(api.akitty_vt_get(syncModes, 4), 0);
assert.equal(api.akitty_vt_get(syncModes, 11), 0);
assert.equal(api.akitty_vt_get(syncModes, 2), 0);
feedTerminal(syncModes, '\x1b[?2026;25l');
assert.equal(api.akitty_vt_get(syncModes, 4), 0);
assert.equal(api.akitty_vt_get(syncModes, 2), 3);
count = api.akitty_vt_replies(syncModes, scratch, length);
assert.equal(decoder.decode(new Uint8Array(api.memory.buffer, scratch, count)), '\x1b[1;4R');
assert.equal(api.akitty_vt_tick(syncModes, 999), 0);
assert.equal(api.akitty_vt_destroy(syncModes), 1);
assert.equal(api.akitty_vt_free(scratch, length), 1);
console.log('Independent VT WASM: text, Unicode, replies, modes, synchronization, resize and lifecycle passed');
console.log(`Shared native/WASM contracts: ${fixtures.length} fixtures passed at every byte boundary`);
