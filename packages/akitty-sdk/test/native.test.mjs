import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { createSprite, createTerminalClient } from "../dist/index.js";

test(
  "SDK updates, sprite ticks and cleanup pass through the native OSC parser and snapshot",
  {
    skip: !process.env.AKITTY_SDK_ABI_SMOKE,
    timeout: 10000,
  },
  async () => {
    const child = spawn(process.env.AKITTY_SDK_ABI_SMOKE, [], {
      stdio: ["pipe", "pipe", "inherit"],
    });
    const lines = createInterface({ input: child.stdout })[
      Symbol.asyncIterator
    ]();
    async function call(request) {
      child.stdin.write(JSON.stringify(request) + "\n");
      const response = await lines.next();
      assert.equal(response.done, false);
      const result = JSON.parse(response.value);
      assert.equal(result.ok, true, result.error);
      return result.data;
    }
    try {
      const { id } = await call({
        op: "create",
        cols: 20,
        rows: 4,
        headless: true,
      });
      const writes = [];
      let tick;
      const client = createTerminalClient({
        capabilities: { title: true, chrome: true },
        write: (sequence) => {
          writes.push(sequence);
          return true;
        },
        schedule: (callback) => {
          tick = callback;
          return () => {};
        },
      });
      async function feed() {
        await call({ op: "feed", id, text: writes.splice(0).join("") });
        return call({ op: "snapshot", id });
      }
      client.setTitle("SDK test");
      client.setStatus({ text: "Working", tone: "info" });
      client.setProgress(0.6);
      const sprite = createSprite(1, 1, [
        new Uint8Array([255, 0, 0, 255]),
        new Uint8Array([0, 0, 255, 255]),
      ]);
      client.playSprite({ sprite, intervalMs: 150 });
      let snapshot = await feed();
      assert.equal(snapshot.title, "SDK test");
      assert.deepEqual(snapshot.chrome, {
        status: { text: "Working", tone: "info" },
        progress: 0.6,
        mark: 0,
        sprite,
      });
      tick();
      snapshot = await feed();
      assert.equal(snapshot.chrome.mark, 1);
      assert.equal(snapshot.chrome.status.text, "Working");
      assert.ok(
        snapshot.lines.every((line) => line.trim() === ""),
        "OSC payload leaked into the grid",
      );
      client.dispose();
      tick();
      snapshot = await feed();
      assert.equal(snapshot.chrome, undefined);
      assert.equal(snapshot.title, "");
      await call({ op: "close", id });
    } finally {
      child.stdin.end();
      child.kill();
    }
  },
);
