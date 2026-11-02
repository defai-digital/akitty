import { invoke } from "@tauri-apps/api/core"
import { listen } from "@tauri-apps/api/event"
import { Ghostty, Terminal, FitAddon } from "@akitty/web"
import wasmUrl from "../../packages/akitty-web/ghostty-vt.wasm?url"
import "./style.css"

const element = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T
const button = (id: string, action: () => void | Promise<void>) => element(id).addEventListener("click", () => { Promise.resolve().then(action).catch(showError) })
const call = <T = unknown>(action: Record<string, unknown>) => invoke<T>("desktop_action", { request: JSON.stringify(action) })
const message = (text: string) => { element("message").textContent = text }
function showError(error: unknown) { message(String(error)) }
type Snapshot = { sequence: number; output: string; control: { owner: string; agent: boolean }; shell: { ready: boolean; cwd: string | null }; program_status: { records: Array<{ state: string; app: string | null; msg: string | null; progress: number | null; message_truncated?: boolean }> }; chrome: { status?: { text: string }; mark?: string | number; progress?: number | "indeterminate"; sprite?: { w: number; h: number; frames: string[] } } | null; exited: boolean; error: string | null }
type Pending = { id: string; pane: string; command: string; cwd_untrusted: string | null; pid: number }
type Poll = { panes: Record<string, Snapshot>; pending: Pending | null; enabled: boolean; recording_error: string | null }
type Pane = { terminal: Terminal; fit: FitAddon; container: HTMLDivElement; tab: HTMLButtonElement; overview: HTMLButtonElement; ack: number; writing: boolean; snapshot?: Snapshot; reports: boolean }
const panes = new Map<string, Pane>()
let platform = "Desktop"
let active: string | null = null
let pending: Pending | null = null
let enabled = false
let exported = ""
let busy = false
let inputBytes = 0
let inputChain = Promise.resolve()
const approval = element<HTMLDialogElement>("approval")
const confirmDialog = element<HTMLDialogElement>("confirm")
const records = element<HTMLDialogElement>("records")
const ghostty = await Ghostty.load(wasmUrl)

function sendInput(id: string, text: string, reply: boolean) {
  const length = new TextEncoder().encode(text).length
  if (inputBytes + length > 65548) { showError("Input queue is full; inspect the terminal before typing again."); return }
  inputBytes += length
  inputChain = inputChain.then(async () => {
    await call({ op: reply ? "reply" : "input", pane: id, text })
  }).catch(showError).finally(() => { inputBytes -= length })
}
function select(id: string) {
  active = id
  for (const [key, pane] of panes) { pane.container.hidden = key !== id; pane.tab.setAttribute("aria-selected", String(key === id)); pane.overview.setAttribute("aria-current", key === id ? "true" : "false") }
  const pane = panes.get(id)
  if (pane) { pane.fit.fit(); pane.terminal.focus(); renderOverview(pane) }
}
function mount(id: string) {
  if (panes.has(id)) { select(id); return }
  const container = document.createElement("div"); container.className = "terminal"
  element("terminals").append(container)
  const tab = document.createElement("button"); tab.textContent = `Terminal ${panes.size + 1}`; tab.setAttribute("role", "tab")
  tab.addEventListener("click", () => select(id)); element("tabs").append(tab)
  const overview = document.createElement("button"); overview.className = "agent-entry"
  overview.addEventListener("click", () => select(id)); element("agent-list").append(overview)
  const terminal = new Terminal({ ghostty, cols: 80, rows: 24, fontSize: 14, scrollback: 5000, theme: { background: "#080a0d", foreground: "#dce2ec", cursor: "#c8d5ee" } })
  const fit = new FitAddon(); terminal.loadAddon(fit); terminal.open(container)
  const pane: Pane = { terminal, fit, container, tab, overview, ack: 0, writing: false, reports: true }
  panes.set(id, pane)
  terminal.onData(text => sendInput(id, text, pane.writing))
  terminal.onResize(({ cols, rows }) => { void call({ op: "resize", pane: id, cols: Math.min(cols, 500), rows: Math.min(rows, 300) }).catch(showError) })
  // Paste is an explicit human action, with review for control/multiline text. Do not allow the
  // web terminal's default handler to race the host approval/ownership boundary.
  container.addEventListener("paste", event => {
    event.preventDefault(); event.stopImmediatePropagation()
    const text = event.clipboardData?.getData("text/plain") ?? ""
    if (new TextEncoder().encode(text).length > 65536) { showError("Paste exceeds 64 KiB."); return }
    if (pane.snapshot?.control.agent) { showError("Reclaim control before pasting."); return }
    const paste = async () => {
      if (/[\x00-\x1f\x7f-\x9f]/u.test(text) && !await confirm("Paste control or multiline text?", text)) return
      pane.terminal.paste(text.replace(/\x1b/g, ""))
    }
    void paste().catch(showError)
  }, true)
  container.addEventListener("drop", event => { event.preventDefault(); event.stopImmediatePropagation(); message(`File drops are not yet supported in Experimental ${platform}.`) }, true)
  select(id)
}
function renderOverview(pane: Pane) {
  const s = pane.snapshot
  if (!s) return
  const reports = s.program_status.records.map(r => `${r.app ?? "Program"}: ${r.state}${r.progress === null ? "" : ` ${r.progress}%`}${r.msg ? `\n${r.msg}${r.message_truncated ? "…" : ""}` : ""}`).join("\n")
  element("overview").textContent = `Input owner: ${s.control.owner}\nShell: ${s.exited ? "exited" : s.shell.ready ? "prompt observed" : "working / unknown"}\nDirectory (unverified): ${s.shell.cwd ?? "unknown"}\n\nProgram reports (unverified):\n${reports || s.chrome?.status?.text || "No reports"}`
  element("reports").textContent = pane.reports ? "Disable program reports" : "Enable program reports"
  const sprite = s.chrome?.sprite
  const canvas = element<HTMLCanvasElement>("agent-sprite"); canvas.hidden = !sprite
  if (sprite) {
    canvas.width = sprite.w; canvas.height = sprite.h
    const index = typeof s.chrome?.mark === "number" ? s.chrome.mark : s.chrome?.mark === "busy" ? Math.floor(Date.now() / 200) % sprite.frames.length : 0
    const frame = sprite.frames[index] ?? sprite.frames[0]
    if (frame) canvas.getContext("2d")?.putImageData(new ImageData(Uint8ClampedArray.from(atob(frame), c => c.charCodeAt(0)), sprite.w, sprite.h), 0, 0)
  }
  const progress = element<HTMLProgressElement>("agent-progress"); progress.hidden = s.chrome?.progress === undefined
  if (typeof s.chrome?.progress === "number") progress.value = s.chrome.progress
  else progress.removeAttribute("value")
  if (s.error) message(s.error)
}
async function poll() {
  try {
    const state = await call<Poll>({ op: "poll", acknowledgements: Object.fromEntries([...panes].map(([id, p]) => [id, p.ack])) })
    enabled = state.enabled; element("enable").textContent = enabled ? "Disable agent requests" : "Enable agent requests"
    if (state.recording_error) message(`Agent requests blocked: ${state.recording_error}`)
    for (const [id, snapshot] of Object.entries(state.panes)) {
      if (!panes.has(id)) mount(id)
      const pane = panes.get(id)!
      if (snapshot.sequence > pane.ack && snapshot.output) {
        const data = Uint8Array.from(atob(snapshot.output), c => c.charCodeAt(0))
        pane.writing = true
        try { pane.terminal.write(data); pane.ack = snapshot.sequence } finally { pane.writing = false }
      }
      pane.snapshot = snapshot
      pane.terminal.options.disableStdin = snapshot.control.agent || snapshot.exited
      const label = snapshot.program_status.records[0]?.state ?? (snapshot.exited ? "exited" : snapshot.control.agent ? "agent" : "shell")
      pane.tab.textContent = `${[...panes.keys()].indexOf(id) + 1} · ${label}`
      const overviewLabel = `Terminal ${[...panes.keys()].indexOf(id) + 1} · ${label}\n${snapshot.control.owner}`
      if (pane.overview.textContent !== overviewLabel) pane.overview.textContent = overviewLabel
      if (id === active) renderOverview(pane)
    }
    pending = state.pending
    if (pending && !confirmDialog.open && !records.open) {
      element("approval-context").textContent = `Local process ${pending.pid}\nTerminal ${[...panes.keys()].indexOf(pending.pane) + 1} (${pending.pane})\nDirectory reported by shell: ${pending.cwd_untrusted ?? "unknown"}`
      element("approval-command").textContent = pending.command
      if (!approval.open) { select(pending.pane); approval.showModal(); element("deny").focus() }
    } else if (!pending && approval.open) approval.close()
  } catch (error) { showError(error) }
  setTimeout(() => { void poll() }, 50)
}
async function decide(allow: boolean) {
  if (!pending || busy) return
  const id = pending.id; busy = true
  try { await call({ op: "decide", request: id, allow }); approval.close(); pending = null; message(allow ? "Command queued once. Review the terminal, then reclaim control." : "Command denied.") }
  finally { busy = false }
}
function confirm(title: string, text: string): Promise<boolean> {
  if (confirmDialog.open || approval.open || records.open) return Promise.resolve(false)
  element("confirm-title").textContent = title; element("confirm-text").textContent = text
  confirmDialog.showModal(); element("cancel").focus()
  return new Promise(resolve => {
    const done = (yes: boolean) => { confirmDialog.close(); element("cancel").removeEventListener("click", cancel); element("continue").removeEventListener("click", accept); confirmDialog.removeEventListener("cancel", escape); resolve(yes) }
    const cancel = () => done(false); const accept = () => done(true); const escape = (event: Event) => { event.preventDefault(); done(false) }
    element("cancel").addEventListener("click", cancel); element("continue").addEventListener("click", accept); confirmDialog.addEventListener("cancel", escape)
  })
}
button("allow", () => decide(true)); button("deny", () => decide(false))
approval.addEventListener("cancel", event => { event.preventDefault(); void decide(false).catch(showError) })
button("enable", async () => { await call({ op: "enable", enabled: !enabled }) })
button("new", async () => {
  const value = await call<{ pane: string }>({ op: "create", shell: element<HTMLSelectElement>("shell").value, cwd: element<HTMLInputElement>("directory").value })
  mount(value.pane); message(`Experimental ${platform} · local agent requests require explicit approval.`)
})
button("reclaim", async () => { if (active) { await call({ op: "reclaim", pane: active }); message("Control returned to you. Running processes continue.") } })
button("reports", async () => { const pane = active && panes.get(active); if (pane) { await call({ op: "reports", pane: active, enabled: !pane.reports }); pane.reports = !pane.reports } })
button("close", async () => {
  const id = active
  if (!id || !await confirm("Close this terminal?", "The shell and its foreground work will be terminated.")) return
  await call({ op: "close", pane: id }); const pane = panes.get(id)
  pane?.terminal.dispose(); pane?.container.remove(); pane?.tab.remove(); pane?.overview.remove(); panes.delete(id)
  active = panes.keys().next().value ?? null
  if (active) select(active); else element("overview").textContent = "No terminal selected."
})
button("timeline", async () => {
  exported = (await call<{ jsonl: string }>({ op: "export" })).jsonl
  element("records-title").textContent = "Agent event timeline"
  element("records-text").textContent = exported.split("\n").slice(-201).join("\n") || "No retained events."
  records.showModal()
})
button("history", async () => {
  if (!active) return
  const history = await call({ op: "history", pane: active, after: 0 })
  element("records-title").textContent = "Command history — unverified shell observations"
  element("records-text").textContent = JSON.stringify(history, null, 2); records.showModal()
})
button("export", async () => {
  const path = element<HTMLInputElement>("export-path").value
  await call({ op: "export_to", path })
  message(`Exported retained metadata to ${path}`)
})
button("dismiss", () => records.close())
await listen("close-requested", () => {
  void (async () => { if (await confirm("Quit AkiTTY Experimental?", "All terminal sessions and their foreground work will be terminated.")) await call({ op: "quit" }) })().catch(showError)
})
new ResizeObserver(() => { if (active) panes.get(active)?.fit.fit() }).observe(element("terminals"))
const environment = await call<{ home: string; shells: string[]; socket: string; platform: string }>({ op: "environment" })
platform = environment.platform
element("platform-badge").textContent = `EXPERIMENTAL · ${platform.toUpperCase()}`
element<HTMLInputElement>("directory").value = environment.home; element("socket").textContent = environment.socket
element<HTMLInputElement>("export-path").value = `${environment.home}/akitty-events-${Date.now()}.jsonl`
for (const shell of environment.shells) { const option = document.createElement("option"); option.value = shell; option.textContent = shell; element("shell").append(option) }
message(`Experimental ${platform} · local agent requests are disabled.`)
element("new").click()
void poll()
