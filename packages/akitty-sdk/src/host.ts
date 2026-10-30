/** Trusted embedding-host API. Never expose this transport to terminal programs or read-only WebMCP tools. */
export type HostRequest = Readonly<Record<string, unknown>>
export type HostTransport = (request: HostRequest) => Promise<unknown>
export type ApprovalRequest = Readonly<{
  session: number
  actor: string
  command: string
  /** Untrusted shell metadata, for display and exact binding only. */
  cwd: string | null
}>
export type DispatchReceipt = Readonly<{
  lease: number
  afterCommandId: number
  completionUntrusted: true
}>

function object(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new RangeError("invalid host response")
  return value as Record<string, unknown>
}
function identifier(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new RangeError("invalid host identifier")
  return value
}
function bounded(value: string, limit: number, name: string): void {
  if (typeof value !== "string" || !value.trim() || new TextEncoder().encode(value).length > limit || /[\x00-\x1f\x7f-\x9f]/u.test(value)) {
    throw new RangeError(`${name} must be nonempty, bounded and without controls`)
  }
}

/** Policy decisions belong to the host: e.g. native approval UI or an authenticated ax-trust adapter.
 * No ax-trust connection is implied. Core lease/authorization checks must be enforced by the transport's host.
 */
export function createCommandHost(options: Readonly<{
  session: number
  request: HostTransport
  approve: (request: ApprovalRequest) => Promise<boolean>
}>) {
  const session = identifier(options.session)
  if (session === 0) throw new RangeError("session must be positive")
  const call = async (op: string, fields: HostRequest = {}) =>
    object(await options.request(Object.freeze({ op, id: session, ...fields })))
  return Object.freeze({
    async execute(actor: string, command: string): Promise<DispatchReceipt> {
      bounded(actor, 64, "actor"); bounded(command, 4096, "command")
      const lease = identifier((await call("control_acquire", { actor })).lease)
      try {
        const snapshot = await call("snapshot")
        const shell = object(snapshot.shell)
        if (shell.ready !== true || !(shell.cwd === null || typeof shell.cwd === "string")) throw new RangeError("integrated shell prompt required")
        const cwd = shell.cwd
        const approval = Object.freeze({ session, actor, command, cwd })
        if (await options.approve(approval) !== true) {
          await call("command_deny", { lease })
          throw new Error("command execution denied")
        }
        const authorization = identifier((await call("command_authorize", { lease, command, expected_cwd: cwd })).authorization)
        const receipt = await call("command_execute", { lease, authorization, command })
        if (receipt.accepted !== true || receipt.completion_untrusted !== true) throw new RangeError("invalid dispatch receipt")
        return Object.freeze({ lease, afterCommandId: identifier(receipt.after_command_id), completionUntrusted: true as const })
      } catch (error) {
        try { await call("control_release", { lease }) }
        catch (cleanupError) { throw new AggregateError([error, cleanupError], "command failed; lease cleanup also failed") }
        throw error
      }
    },
    /** Explicitly return ownership; untrusted completion text never does this automatically. */
    async release(lease: number) { await call("control_release", { lease: identifier(lease) }) },
    /** Human takeover does not terminate the process; the human may then send an interrupt. */
    async reclaim() { await call("control_reclaim") },
    async history(after = 0) { return call("command_history", { after: identifier(after) }) },
    async output(commandId: number) { return call("command_output", { command_id: identifier(commandId) }) },
    /** Persist pages externally when durable auditing is required; check oldest_seq for eviction. */
    async audit(after = 0) { return call("control_audit", { after: identifier(after) }) },
  })
}
