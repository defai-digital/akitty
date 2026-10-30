import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = fileURLToPath(new URL("../", import.meta.url));

test("packed SDK imports and typechecks in an isolated consumer without native libraries", () => {
  const directory = mkdtempSync(join(tmpdir(), "akitty-sdk-consumer-"));
  try {
    execFileSync(
      "npm",
      ["pack", "--ignore-scripts", "--pack-destination", directory],
      { cwd: root, stdio: "pipe" },
    );
    const archive = join(
      directory,
      readdirSync(directory).find((name) => name.endsWith(".tgz")),
    );
    writeFileSync(
      join(directory, "package.json"),
      '{"private":true,"type":"module"}',
    );
    execFileSync(
      "npm",
      [
        "install",
        "--offline",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        archive,
      ],
      { cwd: directory, stdio: "pipe" },
    );
    writeFileSync(
      join(directory, "consumer.mts"),
      `
import { createTerminalClient, createSprite, type Status } from "@ax-code/akitty-sdk"
import { createCommandHost } from "@ax-code/akitty-sdk/host"
const host = createCommandHost({ session: 1, request: async () => ({}), approve: async () => false })
if (typeof host.execute !== "function") throw new Error("Host entry unavailable")
const writes: string[] = []
const client = createTerminalClient({ capabilities: { title: true, chrome: true }, write: (s) => { writes.push(s); return true } })
const status: Status = { text: "consumer", tone: "info" }
client.setStatus(status)
client.setSprite(createSprite(1, 1, [new Uint8Array(4)]))
client.dispose()
if (writes.length !== 3) throw new Error("SDK did not emit the expected updates and cleanup")
`,
    );
    execFileSync(
      process.execPath,
      [
        join(root, "node_modules/typescript/bin/tsc"),
        "--strict",
        "--target",
        "ES2022",
        "--module",
        "NodeNext",
        "--moduleResolution",
        "NodeNext",
        "consumer.mts",
      ],
      { cwd: directory, stdio: "pipe" },
    );
    assert.equal(
      execFileSync(process.execPath, ["consumer.mjs"], {
        cwd: directory,
        encoding: "utf8",
      }),
      "",
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
