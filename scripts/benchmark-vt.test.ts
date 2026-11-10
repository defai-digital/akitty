import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { compare, options, statistics } from './benchmark-vt.ts';

const root = fileURLToPath(new URL('../', import.meta.url));
const nativeBinary = join(root, 'target/release/examples/benchmark');
test('changing measured inputs prevents publication of a successful report', { skip: !existsSync(nativeBinary) }, () => {
  const fixture = mkdtempSync(join(tmpdir(), 'akitty-benchmark-change-'));
  try {
    for (const dir of ['scripts', 'benchmarks', 'packages/akitty-web', 'target/release/examples']) mkdirSync(join(fixture, dir), { recursive: true });
    copyFileSync(join(root, 'scripts/benchmark-vt.ts'), join(fixture, 'scripts/benchmark-vt.ts'));
    copyFileSync(nativeBinary, join(fixture, 'target/release/examples/benchmark-real'));
    // Mutate after the real native measurement, avoiding a race with WASM compilation or timers.
    writeFileSync(join(fixture, 'target/release/examples/benchmark'), `#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const { readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const result = spawnSync(join(__dirname, 'benchmark-real'), [], { input: readFileSync(0), encoding: 'utf8' });
if (result.status === 0) writeFileSync('source.txt', 'after');
process.stdout.write(result.stdout || ''); process.stderr.write(result.stderr || '');
process.exit(result.status ?? 1);
`, { mode: 0o700 });
    const wasm = readFileSync(join(root, 'packages/akitty-web/akitty-vt.wasm'));
    writeFileSync(join(fixture, 'packages/akitty-web/akitty-vt.wasm'), wasm);
    writeFileSync(join(fixture, 'source.txt'), 'before');
    const hash = (bytes: string | NodeJS.ArrayBufferView): string => createHash('sha256').update(bytes).digest('hex');
    writeFileSync(join(fixture, 'packages/akitty-web/wasm-provenance.json'), JSON.stringify({
      sha256: hash(wasm), rust: '1.99.1', inputs: { 'source.txt': hash('before') },
    }));
    writeFileSync(join(fixture, 'benchmarks/workloads.json'), JSON.stringify({ schema: 1, grapheme_support: true,
      cols: 16, rows: 4, history: 4, chunk_bytes: 32, workloads: [{ id: 'ascii', pattern: 'x\r\n' }] }));
    for (const args of [['init', '--quiet'], ['-c', 'user.name=Benchmark Fixture', '-c', 'user.email=benchmark@example.invalid',
      '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', 'commit', '--quiet', '--allow-empty', '-m', 'Fixture']]) {
      const result = spawnSync('git', args, { cwd: fixture, encoding: 'utf8' }); assert.equal(result.status, 0, result.stderr);
    }
    writeFileSync(join(fixture, 'run.mts'), `
import { benchmark } from './scripts/benchmark-vt.ts';
await benchmark(['--samples', '3', '--rounds', '1', '--output', 'result.json']);
`);
    const result = spawnSync(process.execPath, ['run.mts'], { cwd: fixture, encoding: 'utf8', timeout: 30000 });
    assert.equal(readFileSync(join(fixture, 'source.txt'), 'utf8'), 'after');
    assert.notEqual(result.status, 0, 'changed inputs must fail the run');
    assert.match(result.stderr, /changed during benchmark/);
    assert.equal(existsSync(join(fixture, 'result.json')), false, 'no success artifact may be written');
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});

test('nearest-rank percentiles retain raw samples and do not mutate them', () => {
  const raw = [9e6, 1e6, 4e6, 3e6, 2e6];
  assert.deepEqual(statistics(raw), { samples_ns: raw, p50_ms: 3, p95_ms: 9, p99_ms: 9 });
  assert.deepEqual(raw, [9e6, 1e6, 4e6, 3e6, 2e6]);
  const invalid = [[1], [1, 0, 3], [1, NaN, 3], [1, Infinity, 3], new Array(3), [1, , 3]] as readonly unknown[];
  for (const sample of invalid) assert.throws(() => statistics(sample as number[]));
});
test('CLI bounds prevent invalid or unexpectedly large runs', () => {
  assert.deepEqual(options(['--samples', '5', '--rounds', '8']), { samples: 5, rounds: 8 });
  for (const args of [['--samples', '0'], ['--samples', '201'], ['--rounds', '1.5'], ['--rounds', '1025'], ['--output'], ['--unknown', '1']]) {
    assert.throws(() => options(args));
  }
});
test('state or byte disagreement cannot produce a successful benchmark result', () => {
  const base = { id: 'ascii', bytes_per_sample: 1024, feed_ns: [1e6, 2e6, 3e6], resize_ns: [1e6, 2e6, 3e6], state: { cursor: [0, 0] } };
  const output = compare({ results: [base] }, [base], [{ id: 'ascii' }]);
  const first = output[0];
  assert(first !== undefined);
  assert.equal(first.native.feed.median_mib_per_second, .48828125);
  assert.throws(() => compare({ results: [base] }, [{ ...base, state: { cursor: [1, 0] } }], [{ id: 'ascii' }]));
  assert.throws(() => compare({ results: [base] }, [{ ...base, bytes_per_sample: 1 }], [{ id: 'ascii' }]));
  assert.throws(() => compare({ results: [base] }, [base], [{ id: 'ascii' }], 30));
});
