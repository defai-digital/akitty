import assert from 'node:assert/strict';
import { test } from 'node:test';
import { compare, options, statistics } from './benchmark-vt.mjs';

test('nearest-rank percentiles retain raw samples and do not mutate them', () => {
  const raw = [9e6, 1e6, 4e6, 3e6, 2e6];
  assert.deepEqual(statistics(raw), { samples_ns: raw, p50_ms: 3, p95_ms: 9, p99_ms: 9 });
  assert.deepEqual(raw, [9e6, 1e6, 4e6, 3e6, 2e6]);
  for (const sample of [[1], [1, 0, 3], [1, NaN, 3], [1, Infinity, 3]]) assert.throws(() => statistics(sample));
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
  assert.equal(output[0].native.feed.median_mib_per_second, .48828125);
  assert.throws(() => compare({ results: [base] }, [{ ...base, state: { cursor: [1, 0] } }], [{ id: 'ascii' }]));
  assert.throws(() => compare({ results: [base] }, [{ ...base, bytes_per_sample: 1 }], [{ id: 'ascii' }]));
  assert.throws(() => compare({ results: [base] }, [base], [{ id: 'ascii' }], 30));
});
