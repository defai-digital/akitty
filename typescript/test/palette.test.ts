import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

type Command = Readonly<{ id: string; shortcut: string }>;
type Catalog = Readonly<{ version: number; commands: readonly Command[] }>;
type FeatureBundle = Readonly<{ listCommands(query: unknown): string }>;

const source = fs.readFileSync('macos/Sources/AkittyKit/Resources/features.js', 'utf8');
const sandbox = vm.createContext({});
vm.runInContext(source, sandbox, { timeout: 1000 });
const features = (sandbox as { AkittyFeatures?: FeatureBundle }).AkittyFeatures;
assert.ok(features, 'features bundle must export AkittyFeatures');

const list = (query: unknown): Catalog => JSON.parse(features.listCommands(query)) as Catalog;
const only = (query: string): Command => {
  const command = list(query).commands[0];
  assert.ok(command, `no command for ${query}`);
  return command;
};
const command = (id: string): Command => {
  const found = list('').commands.find((item) => item.id === id);
  assert.ok(found, `no command named ${id}`);
  return found;
};

test('bounded deterministic command catalog', () => {
  assert.equal(list('').version, 1);
  assert.equal(list('').commands.length, 13);
  assert.equal(new Set(list('').commands.map((x) => x.id)).size, 13);
  assert.equal(command('find-next').shortcut, '⌘G');
  assert.equal(command('find-previous').shortcut, '⌘⇧G');
  assert.deepEqual(list('split'), list('split'));
  assert.equal(only('split').id, 'split');
  assert.equal(only('next').id, 'find-next');
  assert.equal(only('previous').id, 'find-previous');
  assert.equal(only('agent').id, 'agent-overview');
  assert.equal(only('reclaim').shortcut, '⌥⌘A');
});
test('Unicode normalization and subsequence search', () => {
  assert.equal(only('ｓｐｌｉｔ').id, 'split');
  assert.equal(only('nwtab').id, 'new-tab');
  assert.deepEqual(list('🚀unknown').commands, []);
});
test('contiguous keyword matches outrank scattered subsequences', () => {
  assert.equal(only('side').id, 'split');
});
test('reject invalid and excessive input', () => {
  assert.throws(() => list('x'.repeat(513)));
  assert.throws(() => list(null));
});
test('bundle has no native/Node imports or shell capability', () => {
  assert.doesNotMatch(source, /require\(|node:|child_process|\.zig|eval\(|fetch\(/);
  assert.equal(vm.runInContext('typeof process', sandbox), 'undefined');
});
