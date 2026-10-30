import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync('macos/Sources/AkittyKit/Resources/features.js', 'utf8');
const context = vm.createContext({});
vm.runInContext(source, context, {timeout: 1000});
const list = query => JSON.parse(context.AkittyFeatures.listCommands(query));
test('bounded deterministic command catalog', () => {
  assert.equal(list('').version, 1);
  assert.equal(list('').commands.length, 12);
  assert.equal(new Set(list('').commands.map(x => x.id)).size, 12);
  assert.equal(list('').commands.find(command => command.id === 'find-next').shortcut, '⌘G');
  assert.equal(list('').commands.find(command => command.id === 'find-previous').shortcut, '⌘⇧G');
  assert.deepEqual(list('split'), list('split'));
  assert.equal(list('split').commands[0].id, 'split');
  assert.equal(list('next').commands[0].id, 'find-next');
  assert.equal(list('previous').commands[0].id, 'find-previous');
});
test('Unicode normalization and subsequence search', () => {
  assert.equal(list('ｓｐｌｉｔ').commands[0].id, 'split');
  assert.equal(list('nwtab').commands[0].id, 'new-tab');
  assert.deepEqual(list('🚀unknown').commands, []);
});
test('contiguous keyword matches outrank scattered subsequences', () => {
  assert.equal(list('side').commands[0].id, 'split');
});
test('reject invalid and excessive input', () => {
  assert.throws(() => list('x'.repeat(513)));
  assert.throws(() => list(null));
});
test('bundle has no native/Node imports or shell capability', () => {
  assert.doesNotMatch(source, /require\(|node:|child_process|\.zig|eval\(|fetch\(/);
  assert.equal(vm.runInContext('typeof process', context), 'undefined');
});
