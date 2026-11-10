import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { createCommandHost } from "../dist/host.js";
import { test } from "node:test";
import { createSprite, createTerminalClient } from "../dist/index.js";
import type { Chrome } from "../dist/index.js";

type CreateResult = Readonly<{ id: number }>;
type NativeSnapshot = Readonly<{
  title: string;
  chrome?: Chrome;
  lines: readonly string[];
  shell: Readonly<{ ready: boolean }>;
  control: Readonly<{ agent: boolean; owner: string }>;
}>;
type CommandRecord = Readonly<{ id: number; exit_code: number }>;

const ABI_SMOKE = process.env.AKITTY_SDK_ABI_SMOKE;

test(
  "SDK updates, sprite ticks and cleanup pass through the native OSC parser and snapshot",
  {
    skip: !ABI_SMOKE,
    timeout: 10000,
  },
  async () => {
    assert(ABI_SMOKE);
    const child = spawn(ABI_SMOKE, [], {
      stdio: ["pipe", "pipe", "inherit"],
    });
    assert(child.stdout);
    assert(child.stdin);
    const lines = createInterface({ input: child.stdout })[
      Symbol.asyncIterator
    ]();

    async function nextLine(): Promise<string> {
      const response = await lines.next();
      if (response.done) throw new Error("native process closed unexpectedly");
      return response.value;
    }

    async function call<T = unknown>(request: unknown): Promise<T> {
      child.stdin!.write(JSON.stringify(request) + "\n");
      const result = JSON.parse(await nextLine()) as { ok?: unknown; error?: unknown; data?: unknown };
      assert.equal(result.ok, true, typeof result.error === "string" ? result.error : undefined);
      return result.data as T;
    }
    try {
      const { id } = await call<CreateResult>({
        op: "create",
        cols: 20,
        rows: 4,
        headless: true,
      });
      const writes: string[] = [];
      let tick: (() => void) | undefined;
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
      async function feed(): Promise<NativeSnapshot> {
        await call({ op: "feed", id, text: writes.splice(0).join("") });
        return call<NativeSnapshot>({ op: "snapshot", id });
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
      assert(tick !== undefined);
      tick();
      snapshot = await feed();
      assert.equal(snapshot.chrome?.mark, 1);
      assert.equal(snapshot.chrome?.status?.text, "Working");
      assert.ok(
        snapshot.lines.every((line) => line.trim() === ""),
        "OSC payload leaked into the grid",
      );
      client.dispose();
      tick();
      snapshot = await feed();
      assert.equal(snapshot.chrome, undefined);
      // Clearing the title (`ESC ] 2 ; BEL`) hands the tab back to the core's default name; see docs/ABI.md.
      assert.equal(snapshot.title, "Akitty");
      await call({ op: "close", id });
    } finally {
      child.stdin.end();
      child.kill();
    }
  },
);

test("trusted SDK host approves and executes once through real native PTY and reads its result", {
  skip: !ABI_SMOKE, timeout: 15000,
}, async () => {
  assert(ABI_SMOKE);
  const child = spawn(ABI_SMOKE, [], { stdio: ["pipe", "pipe", "inherit"] })
  assert(child.stdout)
  assert(child.stdin)
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]()
  async function nextLine(): Promise<string> {
    const line = await lines.next()
    if (line.done) throw new Error("native process closed unexpectedly")
    return line.value
  }
  async function call<T = unknown>(request: unknown): Promise<T> {
    child.stdin!.write(JSON.stringify(request) + "\n")
    const response = JSON.parse(await nextLine()) as { ok?: unknown; error?: unknown; data?: unknown }
    if (response.ok !== true) throw new Error(typeof response.error === "string" ? response.error : "native request failed")
    return response.data as T
  }
  let id: number | undefined
  try {
    const resources = fileURLToPath(new URL("../../../macos/Sources/AkittyKit/Resources/shell-integration/", import.meta.url))
    const created = await call<CreateResult>({ op: "create", cols: 80, rows: 10, shell: "/bin/zsh", cwd: "/tmp", shell_integration_dir: resources, folder_history: false })
    id = created.id
    const deadline = Date.now() + 10000
    while (!(await call<NativeSnapshot>({ op: "snapshot", id })).shell.ready) {
      assert.ok(Date.now() < deadline, "integrated prompt did not arrive"); await delay(10)
    }
    let approvals = 0
    const host = createCommandHost({ session: id, request: call, approve: async (request) => {
      approvals++; assert.equal(request.command, "printf 'HOST-SDK-RESULT\\n'; (exit 7)"); return true
    } })
    const receipt = await host.execute("sdk-agent", "printf 'HOST-SDK-RESULT\\n'; (exit 7)")
    let record: CommandRecord | undefined
    while (!record) {
      const history = await host.history(receipt.afterCommandId)
      const commands = history.commands as readonly CommandRecord[]
      record = commands.find(c => c.exit_code === 7)
      assert.ok(Date.now() < deadline, "command completion did not arrive")
      if (!record) await delay(10)
    }
    assert.equal(approvals, 1)
    const output = await host.output(record.id)
    const encoded = output.output_base64
    assert(typeof encoded === "string")
    assert.ok(Buffer.from(encoded, "base64").toString().includes("HOST-SDK-RESULT"))
    assert.equal(output.untrusted, true)
    assert.equal((await call<NativeSnapshot>({ op: "snapshot", id })).control.agent, true)
    await host.release(receipt.lease)
    assert.equal((await call<NativeSnapshot>({ op: "snapshot", id })).control.owner, "human")
    const audit = await host.audit()
    const events = (audit.events as readonly { event: string }[]).map(e => e.event)
    assert.ok(events.includes("authorized")); assert.ok(events.includes("dispatched"))
    await call({ op: "close", id }); id = undefined
  } finally {
    if (id !== undefined) await call({ op: "close", id })
    child.stdin.end(); child.kill()
  }
})
