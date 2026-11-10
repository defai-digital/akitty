import assert from "node:assert/strict"
import { test } from "node:test"
import { createCommandHost } from "../dist/host.js"
import type { ApprovalRequest, HostRequest } from "../dist/host.js"

function fixture(approve: (request: ApprovalRequest) => Promise<boolean> = async () => true) {
  const calls: HostRequest[] = []
  const request = async (r: HostRequest) => {
    calls.push(r)
    switch (r.op) {
      case "control_acquire": return { lease: 3 }
      case "shell_state": return { shell: { ready: true, cwd: "/tmp" } }
      case "command_authorize": return { authorization: 4 }
      case "command_execute": return { accepted: true, after_command_id: 8, completion_untrusted: true }
      default: return {}
    }
  }
  return { calls, host: createCommandHost({ session: 1, request, approve }) }
}
test("host binds exact approved command and directory without releasing on shell completion", async () => {
  const { calls, host } = fixture(async (r) => {
    assert.ok(Object.isFrozen(r)); assert.equal(r.command, "echo hi"); assert.equal(r.cwd, "/tmp"); return true
  })
  const receipt = await host.execute("coding-agent", "echo hi")
  assert.deepEqual(receipt, { lease: 3, afterCommandId: 8, completionUntrusted: true })
  assert.deepEqual(calls.map(r => r.op), ["control_acquire", "shell_state", "command_authorize", "command_execute"])
  const authorize = calls[2]
  assert(authorize !== undefined)
  assert.equal(authorize.expected_cwd, "/tmp")
  await host.release(receipt.lease)
  const released = calls.at(-1)
  assert(released !== undefined)
  assert.equal(released.op, "control_release")
})
test("denial and policy failure never authorize or dispatch and release ownership", async () => {
  for (const approve of [async () => false, async () => { throw new Error("policy offline") }]) {
    const { calls, host } = fixture(approve)
    await assert.rejects(host.execute("agent", "echo hi"))
    assert.ok(!calls.some(r => r.op === "command_authorize" || r.op === "command_execute"))
    const released = calls.at(-1)
    assert(released !== undefined)
    assert.equal(released.op, "control_release")
  }
})
test("host rejects multiline input before acquiring a lease", async () => {
  const { calls, host } = fixture()
  await assert.rejects(host.execute("agent", "echo hi\nrm file"), RangeError)
  assert.equal(calls.length, 0)
})

test("unknown dispatch outcome preserves ownership and never retries", async () => {
  for (const malformed of [false, true]) {
    const calls: unknown[] = []
    const host = createCommandHost({ session: 1, approve: async () => true, request: async r => {
      calls.push(r.op)
      if (r.op === "control_acquire") return { lease: 3 }
      if (r.op === "shell_state") return { shell: { ready: true, cwd: "/tmp" } }
      if (r.op === "command_authorize") return { authorization: 4 }
      if (r.op === "command_execute") {
        if (malformed) return { accepted: true }
        throw new Error("connection lost after possible dispatch")
      }
      return {}
    } })
    await assert.rejects(host.execute("agent", "echo hi"), /outcome is unknown.*do not retry/)
    assert.equal(calls.filter(op => op === "command_execute").length, 1)
    assert.ok(!calls.includes("control_release"))
  }
})

test("invisible command formatting is rejected before authority acquisition", async () => {
  const { calls, host } = fixture()
  await assert.rejects(host.execute("agent", "echo \u202ehidden"), /formatting/)
  assert.equal(calls.length, 0)
})

test("host approval reads shell state without consuming pending terminal events", async () => {
  const calls: unknown[] = []
  let pendingBell = true
  const host = createCommandHost({ session: 1, approve: async () => true, request: async r => {
    calls.push(r.op)
    if (r.op === "control_acquire") return { lease: 3 }
    if (r.op === "snapshot") pendingBell = false
    if (r.op === "shell_state" || r.op === "snapshot") return { shell: { ready: true, cwd: null } }
    if (r.op === "command_authorize") return { authorization: 4 }
    if (r.op === "command_execute") return { accepted: true, after_command_id: 8, completion_untrusted: true }
    return {}
  } })
  await host.execute("agent", "echo hi")
  assert.equal(pendingBell, true, "approval must leave bell and clipboard events for the renderer")
  assert.ok(calls.includes("shell_state"))
  assert.ok(!calls.includes("snapshot"))
})
