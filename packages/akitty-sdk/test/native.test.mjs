import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { createCommandHost } from "../dist/host.js";
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

test("trusted SDK host approves and executes once through real native PTY and reads its result", {
  skip: !process.env.AKITTY_SDK_ABI_SMOKE, timeout: 15000,
}, async () => {
  const child = spawn(process.env.AKITTY_SDK_ABI_SMOKE, [], { stdio: ["pipe", "pipe", "inherit"] })
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]()
  async function call(request) {
    child.stdin.write(JSON.stringify(request) + "\n")
    const line = await lines.next()
    assert.equal(line.done, false)
    const response = JSON.parse(line.value)
    if (!response.ok) throw new Error(response.error)
    return response.data
  }
  let id
  try {
    const resources = fileURLToPath(new URL("../../../macos/Sources/AkittyKit/Resources/shell-integration/", import.meta.url))
    ;({ id } = await call({ op: "create", cols: 80, rows: 10, shell: "/bin/zsh", cwd: "/tmp", shell_integration_dir: resources }))
    const deadline = Date.now() + 10000
    while (!(await call({ op: "snapshot", id })).shell.ready) {
      assert.ok(Date.now() < deadline, "integrated prompt did not arrive"); await delay(10)
    }
    let approvals = 0
    const host = createCommandHost({ session: id, request: call, approve: async (request) => {
      approvals++; assert.equal(request.command, "printf 'HOST-SDK-RESULT\\n'; (exit 7)"); return true
    } })
    const receipt = await host.execute("sdk-agent", "printf 'HOST-SDK-RESULT\\n'; (exit 7)")
    let record
    while (!record) {
      record = (await host.history(receipt.afterCommandId)).commands.find(c => c.exit_code === 7)
      assert.ok(Date.now() < deadline, "command completion did not arrive")
      if (!record) await delay(10)
    }
    assert.equal(approvals, 1)
    const output = await host.output(record.id)
    assert.ok(Buffer.from(output.output_base64, "base64").toString().includes("HOST-SDK-RESULT"))
    assert.equal(output.untrusted, true)
    assert.equal((await call({ op: "snapshot", id })).control.agent, true)
    await host.release(receipt.lease)
    assert.equal((await call({ op: "snapshot", id })).control.owner, "human")
    const events = (await host.audit()).events.map(e => e.event)
    assert.ok(events.includes("authorized")); assert.ok(events.includes("dispatched"))
    await call({ op: "close", id }); id = undefined
  } finally {
    if (id !== undefined) await call({ op: "close", id })
    child.stdin.end(); child.kill()
  }
})
