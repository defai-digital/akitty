import assert from "node:assert/strict";
import { test } from "node:test";
import {
  CHROME_CLEAR_SEQUENCE,
  chromeSequence,
  createSprite,
  createTerminalClient,
  detectCapabilities,
  titleSequence,
} from "../dist/index.js";

const capabilities = { title: true, chrome: true };
const sprite = createSprite(1, 1, [
  new Uint8Array([255, 0, 0, 255]),
  new Uint8Array([0, 0, 255, 255]),
]);
const body = (sequence) => JSON.parse(sequence.slice("\x1b]771;".length, -1));

function harness(options = {}) {
  const writes = [];
  const ticks = [];
  let cancelled = 0;
  const client = createTerminalClient({
    capabilities,
    write: (sequence) => {
      writes.push(sequence);
      return true;
    },
    schedule: (tick, interval) => {
      ticks.push({ tick, interval });
      return () => {
        cancelled++;
      };
    },
    ...options,
  });
  return {
    client,
    writes,
    ticks,
    get cancelled() {
      return cancelled;
    },
  };
}

test("only direct AkiTTY TTYs opt into chrome; advanced identity grants no graphics capability", () => {
  assert.deepEqual(
    detectCapabilities(
      { TERM_PROGRAM: "Akitty", TERM: "xterm-256color" },
      true,
    ),
    capabilities,
  );
  assert.deepEqual(detectCapabilities({ TERM_PROGRAM: "ghostty" }, true), {
    title: true,
    chrome: false,
  });
  assert.deepEqual(detectCapabilities({ TERM_PROGRAM: "Akitty" }, false), {
    title: false,
    chrome: false,
  });
  for (const key of [
    "SSH_CONNECTION",
    "SSH_CLIENT",
    "SSH_TTY",
    "MOSH_CONNECTION",
    "TMUX",
    "TMUX_PANE",
    "STY",
    "ZELLIJ",
  ]) {
    assert.deepEqual(
      detectCapabilities({ TERM_PROGRAM: "Akitty", [key]: "outer" }, true),
      { title: false, chrome: false },
    );
  }
  for (const TERM of [
    "dumb",
    "linux",
    "vt100",
    "screen-256color",
    "tmux-256color",
  ]) {
    assert.equal(
      detectCapabilities({ TERM_PROGRAM: "Akitty", TERM }, true).chrome,
      false,
    );
  }
  assert.equal(
    detectCapabilities({ TERM_PROGRAM: "vscode", WT_SESSION: "outer" }, true)
      .chrome,
    false,
  );
});

test("title and status cannot inject escapes and limits count Unicode scalars", () => {
  assert.equal(
    titleSequence("A\x1b]52;B\x07"),
    "\x1b]2;A ]52;B \x07\x1b]1;A ]52;B \x07",
  );
  assert.equal(
    titleSequence("😀".repeat(129)),
    `\x1b]2;${"😀".repeat(128)}\x07\x1b]1;${"😀".repeat(128)}\x07`,
  );
  const { client, writes } = harness();
  client.setStatus({
    text: "\x1b\x07測試\x9f" + "😀".repeat(129),
    tone: "info",
  });
  assert.equal(body(writes[0]).status.text, "測試" + "😀".repeat(126));
});

test("field updates preserve the complete replacement document; null removes only its field", () => {
  const { client, writes } = harness();
  client.setStatus({ text: "Working", tone: "info", expires: 1234567890000 });
  client.setSprite(sprite);
  client.setProgress(0.6);
  client.setMark(1);
  assert.deepEqual(body(writes.at(-1)), {
    status: { text: "Working", tone: "info", expires: 1234567890000 },
    sprite,
    progress: 0.6,
    mark: 1,
  });
  client.setProgress(null);
  assert.equal("progress" in body(writes.at(-1)), false);
  assert.deepEqual(body(writes.at(-1)).sprite, sprite);
  assert.ok(Object.isFrozen(client.chrome));
  assert.ok(Object.isFrozen(client.chrome.status));
  assert.ok(Object.isFrozen(client.chrome.sprite.frames));
  assert.equal(client.clearChrome(), true);
  assert.equal(writes.at(-1), CHROME_CLEAR_SEQUENCE);
  assert.equal(client.clearChrome(), false);
});

test("invalid inputs never change state or emit bytes", () => {
  const { client, writes } = harness();
  client.setStatus({ text: "Preserve", tone: "warn" });
  const previous = client.chrome;
  for (const patch of [
    { progress: NaN },
    { progress: Infinity },
    { progress: -0.1 },
    { progress: 1.1 },
    { progress: "other" },
    { mark: 4 },
    { mark: -1 },
    { mark: 0.5 },
    { mark: "other" },
    { path: "file" },
    { status: { text: "x", tone: "other" } },
    { status: { text: "x", tone: "info", expires: -1 } },
    { status: { text: "x", tone: "info", expires: 1.5 } },
    { status: { text: "x", tone: "info", unknown: true } },
    { sprite: { ...sprite, source: "file" } },
    { sprite: { ...sprite, frames: ["AAAA"] } },
    { sprite: { w: 1, h: 1, frames: ["AAAAA==="] } },
    { sprite: { ...sprite, w: 33 } },
  ]) {
    assert.throws(() => client.updateChrome(patch), RangeError);
    assert.equal(client.chrome, previous);
  }
  assert.equal(writes.length, 1);
});

test("sprite dimensions, frame counts and raw buffers are bounded before encoding", () => {
  for (const [w, h, frames] of [
    [0, 1, []],
    [33, 1, []],
    [1, 0, []],
    [1, 33, []],
    [1.5, 1, []],
    [1, 1, []],
    [1, 1, Array(5).fill(new Uint8Array(4))],
    [1, 1, [new Uint8Array(3)]],
  ]) {
    assert.throws(() => createSprite(w, h, frames), RangeError);
  }
  const raw = new Uint8Array(32 * 32 * 4);
  const maximum = createSprite(32, 32, [raw, raw, raw, raw]);
  assert.ok(Buffer.byteLength(chromeSequence({ sprite: maximum })) < 65536);
  const copied = createSprite(1, 1, [raw.subarray(0, 4)]);
  raw[0] = 255;
  assert.equal(copied.frames[0], "AAAAAA==");
});

test("rejected and throwing writers do not commit state; later writes can retry", () => {
  let mode = "reject";
  const { client } = harness({
    write: () => {
      if (mode === "throw") throw new Error("output unavailable");
      return mode === "accept";
    },
  });
  assert.equal(client.setProgress(0.5), false);
  assert.deepEqual(client.chrome, {});
  mode = "throw";
  assert.throws(() => client.setProgress(0.5), /output unavailable/);
  assert.deepEqual(client.chrome, {});
  mode = "accept";
  assert.equal(client.setProgress(0.5), true);
  assert.equal(client.chrome.progress, 0.5);
});

test("disabled capabilities emit nothing and schedule nothing", () => {
  const { client, writes, ticks } = harness({
    capabilities: { title: false, chrome: false },
  });
  assert.equal(client.setTitle("AX Code"), false);
  assert.equal(client.setProgress(0.2), false);
  assert.equal(client.playSprite({ sprite, intervalMs: 150 }), false);
  client.dispose();
  assert.deepEqual(writes, []);
  assert.deepEqual(ticks, []);
});

test("animation preserves concurrent status updates and fences old callbacks after replacement, stop and dispose", () => {
  const h = harness();
  h.client.playSprite({ sprite, intervalMs: 150 });
  assert.equal(h.ticks[0].interval, 150);
  h.ticks[0].tick();
  assert.equal(h.client.chrome.mark, 1);
  h.client.setStatus({ text: "Still working", tone: "info" });
  h.ticks[0].tick();
  assert.equal(h.client.chrome.mark, 0);
  assert.equal(h.client.chrome.status.text, "Still working");
  h.client.playSprite({ sprite, intervalMs: 200 });
  const count = h.writes.length;
  h.ticks[0].tick();
  assert.equal(h.writes.length, count);
  h.client.stopSprite();
  h.ticks[1].tick();
  assert.equal(h.writes.length, count);
  h.client.playSprite({ sprite, intervalMs: 100 });
  h.client.dispose();
  const closed = h.writes.length;
  h.ticks[2].tick();
  h.client.dispose();
  assert.equal(h.client.setProgress(0.5), false);
  assert.equal(h.writes.length, closed);
  assert.equal(h.writes.at(-1), CHROME_CLEAR_SEQUENCE);
  assert.equal(h.cancelled, 3);
});

test("manual frame or sprite updates stop animation; status updates do not", () => {
  for (const patch of [{ mark: "idle" }, { sprite: null }]) {
    const h = harness();
    h.client.playSprite({ sprite, intervalMs: 150 });
    h.client.updateChrome(patch);
    const count = h.writes.length;
    h.ticks[0].tick();
    assert.equal(h.writes.length, count);
  }
});

test("reduce motion and single-frame sprites remain static", () => {
  for (const options of [{ reduceMotion: true }, {}]) {
    const h = harness(options);
    h.client.playSprite({
      sprite: options.reduceMotion
        ? sprite
        : createSprite(1, 1, [new Uint8Array(4)]),
      intervalMs: 150,
    });
    assert.equal(h.client.chrome.mark, 0);
    assert.equal(h.ticks.length, 0);
  }
  for (const intervalMs of [0, 49, 60001, NaN, 150.5]) {
    assert.throws(
      () => harness().client.playSprite({ sprite, intervalMs }),
      RangeError,
    );
  }
});

test("animation stops after a rejected or throwing write without resurrecting", () => {
  for (const failure of [false, new Error("output failed")]) {
    let count = 0;
    const errors = [];
    const h = harness({
      write: () => {
        if (++count === 1) return true;
        if (failure instanceof Error) throw failure;
        return failure;
      },
      onError: (error) => errors.push(error),
    });
    h.client.playSprite({ sprite, intervalMs: 150 });
    h.ticks[0].tick();
    h.ticks[0].tick();
    assert.equal(count, 2);
    assert.equal(h.cancelled, 1);
    assert.deepEqual(errors, failure instanceof Error ? [failure] : []);
  }
});

test("dispose clears only owned title/chrome and remains closed after a teardown exception", () => {
  const h = harness();
  h.client.setTitle("AX Code");
  h.client.setProgress("indeterminate");
  h.client.dispose();
  assert.deepEqual(h.writes.slice(-2), [
    CHROME_CLEAR_SEQUENCE,
    titleSequence(""),
  ]);
  const broken = createTerminalClient({
    capabilities,
    write: () => {
      throw new Error("broken");
    },
  });
  broken.dispose();
  assert.equal(broken.setTitle("late"), false);
  let fail = false;
  const writes = [];
  const closing = createTerminalClient({
    capabilities,
    write: (sequence) => {
      writes.push(sequence);
      if (fail && sequence === CHROME_CLEAR_SEQUENCE)
        throw new Error("clear failed");
      return true;
    },
  });
  closing.setTitle("owned");
  closing.setProgress(0.2);
  fail = true;
  assert.throws(() => closing.dispose(), /clear failed/);
  assert.equal(
    writes.at(-1),
    titleSequence(""),
    "title cleanup must run even when chrome cleanup throws",
  );
  const count = writes.length;
  closing.dispose();
  assert.equal(closing.setProgress(0.3), false);
  assert.equal(writes.length, count);
});
