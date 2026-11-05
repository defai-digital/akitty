import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { arch, cpus, platform, release } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

export function options(args) {
  const result = { samples: 30, rounds: 64 };
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i]?.slice(2), value = args[i + 1];
    assert(args[i]?.startsWith('--') && value !== undefined, 'expected --samples N, --rounds N or --output PATH');
    if (key === 'output') { assert(value.length && !result.output, 'invalid or duplicate output'); result.output = value; }
    else {
      assert(['samples', 'rounds'].includes(key), `unknown option ${args[i]}`);
      assert(/^\d+$/.test(value), `${key} must be an integer`);
      const n = Number(value), [min, max] = key === 'samples' ? [3, 200] : [1, 1024];
      assert(n >= min && n <= max, `${key} must be in ${min}..=${max}`); result[key] = n;
    }
  }
  return result;
}

export function statistics(samples) {
  assert(samples.length >= 3 && samples.every(n => Number.isSafeInteger(n) && n > 0), 'invalid timing samples');
  const sorted = [...samples].sort((a, b) => a - b);
  const percentile = p => sorted[Math.ceil(sorted.length * p) - 1] / 1e6;
  return { samples_ns: samples, p50_ms: percentile(.5), p95_ms: percentile(.95), p99_ms: percentile(.99) };
}

export function compare(native, wasm, expected, samples = 3) {
  assert.equal(native.results.length, expected.length, 'missing native workload');
  assert.equal(wasm.length, expected.length, 'missing WASM workload');
  return expected.map((workload, index) => {
    const n = native.results[index], w = wasm[index];
    assert.equal(n.id, workload.id); assert.equal(w.id, workload.id);
    assert.equal(n.bytes_per_sample, w.bytes_per_sample, 'different workload byte counts');
    assert.deepEqual(n.state, w.state, `${workload.id}: native/WASM state disagreement`);
    return { id: workload.id, bytes_per_sample: n.bytes_per_sample, state_sha256: hash(JSON.stringify(n.state)),
      ...Object.fromEntries([['native', n], ['wasm', w]].map(([name, result]) => {
        assert.equal(result.feed_ns.length, samples, `${name}: missing feed samples`);
        assert.equal(result.resize_ns.length, samples, `${name}: missing resize samples`);
        const feed = statistics(result.feed_ns);
        feed.median_mib_per_second = result.bytes_per_sample / 1048576 / (feed.p50_ms / 1000);
        return [name, { feed, resize_pair: statistics(result.resize_ns) }];
      })) };
  });
}

async function measureWasm(bytes, config) {
  const module = await WebAssembly.compile(bytes);
  assert.deepEqual(WebAssembly.Module.imports(module), []);
  const { exports: api } = await WebAssembly.instantiate(module);
  assert.equal(api.akitty_vt_abi_version(), 1);
  const capacity = 65536, pointer = api.akitty_vt_alloc(capacity);
  assert(pointer);
  const state = id => {
    const lines = [];
    for (let row = 0; row < config.rows; row++) {
      const size = api.akitty_vt_line(id, row, pointer, capacity);
      assert.equal(size, config.cols * 32);
      const view = new DataView(api.memory.buffer, pointer, size);
      const widths = Array.from({ length: config.cols }, (_, col) => view.getUint32(col * 32 + 20, true));
      let text = '';
      for (let col = 0; col < config.cols; col++) {
        if (!widths[col]) continue;
        const size = api.akitty_vt_text(id, row, col, 0, pointer, capacity);
        text += new TextDecoder().decode(new Uint8Array(api.memory.buffer, pointer, size));
      }
      lines.push(text);
    }
    return { lines, cursor: [api.akitty_vt_get(id, 2), api.akitty_vt_get(id, 3)],
      history: api.akitty_vt_get(id, 6), alternate: !!api.akitty_vt_get(id, 5) };
  };
  const results = [];
  try {
    for (const workload of config.workloads) {
      const input = new TextEncoder().encode(workload.text);
      const result = { id: workload.id, bytes_per_sample: input.length * config.rounds, feed_ns: [], resize_ns: [] };
      for (let sample = 0; sample < config.samples + 3; sample++) {
        const id = api.akitty_vt_create(config.cols, config.rows, config.history); assert(id);
        try {
          // Copy fixture bytes before timing; native likewise receives an already-decoded byte slice.
          new Uint8Array(api.memory.buffer, pointer, input.length).set(input);
          let start = process.hrtime.bigint();
          for (let round = 0; round < config.rounds; round++) assert.equal(api.akitty_vt_write(id, pointer, input.length, 0), 1);
          const feed = Number(process.hrtime.bigint() - start);
          start = process.hrtime.bigint();
          assert.equal(api.akitty_vt_resize(id, Math.floor(config.cols * 2 / 3), config.rows), 1);
          assert.equal(api.akitty_vt_resize(id, config.cols, config.rows), 1);
          const resize = Number(process.hrtime.bigint() - start);
          if (sample >= 3) { result.feed_ns.push(feed); result.resize_ns.push(resize); }
          result.state = state(id);
        } finally { assert.equal(api.akitty_vt_destroy(id), 1); }
      }
      results.push(result);
    }
  } finally { assert.equal(api.akitty_vt_free(pointer, capacity), 1); }
  return results;
}

export async function benchmark(args) {
  const opts = options(args);
  const manifestBytes = readFileSync(resolve(root, 'benchmarks/workloads.json'));
  const manifest = JSON.parse(manifestBytes);
  assert.equal(manifest.schema, 1);
  assert.equal(manifest.grapheme_support, true, 'benchmark profile must match the WASM grapheme configuration');
  const workloads = manifest.workloads.map(({ id, pattern }) => ({ id,
    text: pattern.repeat(Math.ceil(manifest.chunk_bytes / Buffer.byteLength(pattern))) }));
  const config = { ...manifest, ...opts, workloads };
  const wasmBytes = readFileSync(resolve(root, 'packages/akitty-web/akitty-vt.wasm'));
  const provenance = JSON.parse(readFileSync(resolve(root, 'packages/akitty-web/wasm-provenance.json')));
  assert.equal(hash(wasmBytes), provenance.sha256, 'WASM artifact is stale');
  for (const [path, digest] of Object.entries(provenance.inputs)) assert.equal(hash(readFileSync(resolve(root, path))), digest, `stale source stamp: ${path}`);
  const binary = resolve(root, 'target/release/examples/benchmark');
  const child = spawnSync(binary, [], { input: JSON.stringify(config), encoding: 'utf8', timeout: 180000, maxBuffer: 8 * 1024 * 1024 });
  assert(!child.error && child.status === 0, child.error?.message || child.stderr || 'native benchmark failed');
  const native = JSON.parse(child.stdout);
  const wasm = await measureWasm(wasmBytes, config);
  const results = compare(native, wasm, workloads, opts.samples);
  const git = args => {
    const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0); return result.stdout.trim();
  };
  const report = { schema: 1, measured_at: new Date().toISOString(), scope: 'parser-grid-and-reflow',
    git_commit: git(['rev-parse', 'HEAD']), dirty: !!git(['status', '--porcelain']),
    host: { os: platform(), release: release(), architecture: arch(), cpu: cpus()[0]?.model, node: process.version },
    source_sha256: hash(JSON.stringify(provenance.inputs)), workload_sha256: hash(manifestBytes),
    harness_sha256: hash(readFileSync(fileURLToPath(import.meta.url))), rust: provenance.rust, profile: 'release',
    native_sha256: hash(readFileSync(binary)), wasm_sha256: hash(wasmBytes),
    configuration: { cols: config.cols, rows: config.rows, history: config.history, grapheme_support: true, rounds: opts.rounds, samples: opts.samples, warmup: 3 },
    percentile_method: 'nearest-rank', state_agreement: true, results };
  const json = JSON.stringify(report, null, 2) + '\n';
  if (opts.output) {
    mkdirSync(dirname(resolve(opts.output)), { recursive: true });
    writeFileSync(opts.output, json, { flag: 'wx', mode: 0o600 });
    process.stderr.write(`Benchmark result: ${opts.output}\n`);
  } else process.stdout.write(json);
  return report;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  benchmark(process.argv.slice(2)).catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
}
