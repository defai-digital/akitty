import assert from "node:assert/strict"
import { test } from "node:test"
import { createCommandHost } from "../dist/host.js"

function fixture(approve = async () => true) {
  const calls = []
  const request = async (r) => {
    calls.push(r)
    switch (r.op) {
      case "control_acquire": return { lease: 3 }
      case "snapshot": return { shell: { ready: true, cwd: "/tmp" } }
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
  assert.deepEqual(calls.map(r => r.op), ["control_acquire", "snapshot", "command_authorize", "command_execute"])
  assert.equal(calls[2].expected_cwd, "/tmp")
  await host.release(receipt.lease)
  assert.equal(calls.at(-1).op, "control_release")
})
test("denial and policy failure never authorize or dispatch and release ownership", async () => {
  for (const approve of [async () => false, async () => { throw new Error("policy offline") }]) {
    const { calls, host } = fixture(approve)
    await assert.rejects(host.execute("agent", "echo hi"))
    assert.ok(!calls.some(r => ["command_authorize", "command_execute"].includes(r.op)))
    assert.equal(calls.at(-1).op, "control_release")
  }
})
test("host rejects multiline input before acquiring a lease", async () => {
  const { calls, host } = fixture()
  await assert.rejects(host.execute("agent", "echo hi\nrm file"), RangeError)
  assert.equal(calls.length, 0)
})
