import AppKit
import AgentIPC

/// Same-user processes may request. Only the native human sheet may approve; no core authority crosses IPC.
@MainActor final class AgentRequests {
    private let source: () -> [TerminalView]
    let store: AgentEventStore
    private let server: LocalRequestServer
    private let instance = UUID().uuidString
    private var timer: Timer?
    private var sessions: [UInt64: String] = [:]
    private var cursors: [UInt64: UInt64] = [:]
    /// Program-status state counts last recorded per pane. Only a change in counts is recorded: progress and message
    /// updates arrive at 2 Hz from a busy program and would otherwise rotate host records out of retention.
    private var reports: [UInt64: [String: Int]] = [:]
    private weak var pendingWindow: NSWindow?
    private weak var pendingSheet: NSWindow?
    private var activeRequest: UUID?
    /// Whether a request is still unwinding; its cooldown is armed only once this turns false.
    var hasActiveRequest: Bool { activeRequest != nil }
    private var pendingLocalRequest = false
    private var stopped = false
    private var timeline: NSWindowController?
    private var nextPromptTime: TimeInterval = 0
    var cooldownInterval: TimeInterval = 3
    private(set) var enabled = false
    var onFailure: ((String) -> Void)?
    private(set) var failure: String? { didSet { if let failure { onFailure?(failure) } } }
    init(source: @escaping () -> [TerminalView], store: AgentEventStore? = nil, path: String = LocalSocket.defaultPath) {
        self.source = source; self.store = store ?? AgentEventStore(); server = LocalRequestServer(path: path)
    }
    func startRecording() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.collectAll() }
        }
        for terminal in source() { register(terminal) }
    }
    func register(_ terminal: TerminalView) {
        guard timer != nil, !terminal.isShutdown, sessions[terminal.session.id] == nil else { return }
        let id = terminal.session.id; sessions[id] = UUID().uuidString
        let previous = terminal.onWillShutdown
        terminal.onWillShutdown = { [weak self, weak terminal] in
            defer { previous?() }
            guard let self, let terminal else { return }
            self.record(terminal, drain: true)
            self.persist(event: "session_closed", id: id)
            self.cursors.removeValue(forKey: id); self.reports.removeValue(forKey: id); self.sessions.removeValue(forKey: id)
        }
        persist(event: "session_opened", id: id)
    }
    func setEnabled(_ value: Bool) throws {
        if value {
            guard !stopped else { throw AkittyError.core("Request service has stopped.") }
            startRecording()
            try server.start { [weak self] data, peer in
                guard let self else { return Data("{\"version\":1,\"ok\":false,\"error\":\"Host stopped\"}".utf8) }
                return await self.handle(data, peer: peer)
            }
            enabled = true
        } else {
            enabled = false; server.stop()
            if pendingLocalRequest { cancelPendingApproval() }
        }
    }
    func stop() { stopped = true; cancelPendingApproval(); try? setEnabled(false); collectAll(drain: true); timer?.invalidate(); timer = nil }
    private func cancelPendingApproval() {
        if let sheet = pendingSheet, pendingWindow?.attachedSheet === sheet { pendingWindow?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }
    private func persist(event: String, id: UInt64, provenance: String = "host", fields: [String: Any] = [:]) {
        later(event, session: sessions[id] ?? "unknown", provenance: provenance, fields: ["pane_session_id": id].merging(fields) { _, new in new })
    }
    /// Routine observations are written off the main thread; the store keeps them in order with synchronous appends.
    private func later(_ event: String, session: String, provenance: String, fields: [String: Any]) {
        store.appendLater(event: event, session: session, provenance: provenance, fields: fields) { [weak self] message in self?.failure = message }
    }
    private func collectAll(drain: Bool = false) {
        for terminal in source() where !terminal.isShutdown { register(terminal); record(terminal, drain: drain) }
    }
    /// The timer can skip `control_audit` only when the snapshot already shows no agent lease and no unseen sequence.
    /// Blocked keystrokes under a lease are audited without bumping that revision, so a leased pane is always read.
    /// A missing snapshot is not proof of idleness. `drain` is the shutdown, export, and approval path.
    nonisolated static func canSkipAuditRead(agent: Bool?, auditSeq: UInt64?, cursor: UInt64) -> Bool {
        guard agent == false, let auditSeq else { return false }
        return auditSeq <= cursor
    }
    private func record(_ terminal: TerminalView, drain: Bool = false) {
        let id = terminal.session.id, after = cursors[id] ?? 0
        let control = terminal.snapshot?.control
        if drain || !Self.canSkipAuditRead(agent: control?.agent, auditSeq: control?.audit_seq, cursor: after) {
            do {
                let page = try JSONSerialization.jsonObject(with: terminal.session.controlAudit(after: after)) as? [String: Any]
                if let oldest = page?["oldest_seq"] as? UInt64, oldest > after + 1 {
                    later("source_gap", session: sessions[id] ?? "unknown", provenance: "host", fields: ["after": after, "oldest_available": oldest])
                }
                for event in page?["events"] as? [[String: Any]] ?? [] {
                    guard let sequence = event["seq"] as? UInt64, let name = event["event"] as? String else { continue }
                    var fields: [String: Any] = ["pane_session_id": id, "core_sequence": sequence, "observed_time_ms": event["time_ms"] ?? NSNull()]
                    if let command = event["command"] as? String { fields["command_sha256"] = AgentEventStore.digest(command); fields["command_bytes"] = command.utf8.count }
                    if let actor = event["actor"] as? String { fields["host_actor_label"] = actor }
                    later(name, session: sessions[id] ?? "unknown", provenance: name.contains("untrusted") ? "shell_untrusted" : "host", fields: fields)
                    cursors[id] = sequence
                }
            } catch { failure = error.localizedDescription }
        }
        if let status = terminal.snapshot?.program_status {
            let counts = Dictionary(grouping: status.records, by: \.state).mapValues(\.count)
            if reports[id] != counts {
                later("program_status_observed", session: sessions[id] ?? "unknown", provenance: "program_untrusted", fields: ["pane_session_id": id, "state_counts": counts])
                reports[id] = counts
            }
        }
    }
    private func paneID(_ terminal: TerminalView) -> String { "\(instance)/\(terminal.session.id)" }
    enum Origin {
        case localProcess(LocalPeer), siri
        var actor: String {
            switch self { case .localProcess(let peer): return "local process \(peer.pid)"; case .siri: return "Siri / Shortcuts" }
        }
        func isValid(enabled: Bool) -> Bool {
            switch self { case .localProcess(let peer): return enabled && peer.connected; case .siri: return true }
        }
        var fields: [String: Any] {
            switch self {
            case .localProcess(let peer): return ["peer_uid": peer.uid, "peer_pid": peer.pid]
            case .siri: return ["request_source": "siri_shortcuts"]
            }
        }
        var explanation: String {
            switch self {
            case .localProcess(let peer): return "Connection opened by OS process \(peer.pid), user \(peer.uid). Agent/product identity and shell-reported directory are not verified. This command uses your shell's permissions. Reclaim returns input without stopping it."
            case .siri: return "Requested through Siri or Shortcuts. Review the exact command and target; speech recognition may differ from what you intended. The directory is reported by the shell and is not verified. This command uses your shell's permissions. Reclaim returns input without stopping it."
            }
        }
    }
    /// System intents and socket requests share approval and audit handling.
    /// Siri does not enable the local socket or carry core authorizations.
    func request(_ command: String, in terminal: TerminalView, origin: Origin) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !stopped, origin.isValid(enabled: enabled), !terminal.isShutdown,
              source().contains(where: { $0 === terminal }), let window = terminal.window else {
            throw AkittyError.core("Request source or target terminal is no longer available.")
        }
        try AgentCommandHost.validateCommand(command)
        guard activeRequest == nil else { throw AkittyError.core("Another command request is awaiting approval.") }
        guard ProcessInfo.processInfo.systemUptime >= nextPromptTime else { throw AkittyError.core("Local requests are rate limited. Wait before requesting again.") }
        guard failure == nil else { throw AkittyError.core("Event recording failed; restart AkiTTY after restoring event storage.") }
        let id = UUID(); activeRequest = id
        if case .localProcess = origin { pendingLocalRequest = true }
        // The cooldown only follows a sheet the human actually saw: a request that failed before display
        // (a busy shell) must not lock out the immediate retry.
        var prompted = false
        defer {
            activeRequest = nil; pendingLocalRequest = false; pendingWindow = nil; pendingSheet = nil
            if prompted { nextPromptTime = ProcessInfo.processInfo.systemUptime + cooldownInterval }
        }
        startRecording(); register(terminal)
        let eventSession = sessions[terminal.session.id] ?? "unknown"
        do {
            return try await withTaskCancellationHandler {
                // Persist intent before acquiring authority; an I/O failure prevents dispatch.
                try await store.appendDurably(event: "execution_requested", session: eventSession, provenance: "host",
                    fields: origin.fields.merging(["pane_session_id": terminal.session.id, "command_sha256": AgentEventStore.digest(command), "command_bytes": command.utf8.count]) { _, value in value })
                try Task.checkCancellation()
                guard !stopped, origin.isValid(enabled: enabled) else { throw AkittyError.core("Request service or caller has stopped.") }
                let receipt = try await AgentCommandHost(session: terminal.session).execute(actor: origin.actor, command: command) { [weak self] request in
                    // A cancelled intent is not a human denial: throwing releases the lease instead of denying it.
                    if Task.isCancelled { throw CancellationError() }
                    guard let self, !self.stopped, origin.isValid(enabled: self.enabled), !terminal.isShutdown,
                          terminal.window === window, window.attachedSheet == nil else { return false }
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    let alert = AgentCommandHost.approvalAlert(request, callerDescription: origin.explanation)
                    self.pendingWindow = window; self.pendingSheet = alert.window
                    prompted = true
                    let accepted = await Self.present(alert, in: window, valid: { [weak self, weak terminal] in
                        guard let self, let terminal else { return false }
                        return !self.stopped && origin.isValid(enabled: self.enabled) && !terminal.isShutdown && terminal.window === window && window.isVisible
                    })
                    // The sheet ended from a hidden window or cancelled intent; never let that read as approval.
                    if Task.isCancelled { throw CancellationError() }
                    return accepted && !self.stopped && origin.isValid(enabled: self.enabled) && !terminal.isShutdown
                }
                record(terminal, drain: true)
                guard failure == nil else { throw AkittyError.core("Command was dispatched, but event recording failed. Outcome is uncertain; do not retry automatically.") }
                return ["accepted": receipt.dispatch.accepted, "after_command_id": receipt.dispatch.after_command_id, "event_session": eventSession,
                    "completion_untrusted": true, "input_remains_leased": true,
                    "next_step": "Review the terminal, then use Reclaim Terminal Control. It does not stop the process."]
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.activeRequest == id else { return }
                    self.cancelPendingApproval()
                }
            }
        } catch {
            collectAll(drain: true)
            if error is CancellationError {
                // The intent was cancelled (not denied by a human); record who ended the wait before rethrowing.
                do { try await store.appendDurably(event: "request_cancelled", session: eventSession, provenance: "host") }
                catch { failure = error.localizedDescription }
            }
            if error.localizedDescription.contains("Dispatch outcome is unknown") {
                do { try await store.appendDurably(event: "dispatch_outcome_unknown", session: eventSession, provenance: "host") }
                catch { failure = error.localizedDescription }
            }
            throw error
        }
    }
    func handle(_ data: Data, peer: LocalPeer) async -> Data {
        do {
            guard enabled, peer.connected else { throw AkittyError.core("Local requests are disabled or the caller disconnected.") }
            guard let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = input["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  let operation = input["op"] as? String else { throw AkittyError.core("Invalid local request schema.") }
            let panes = source()
            let result: [String: Any]
            if operation == "list", Set(input.keys).isSubset(of: ["version", "op", "offset"]) {
                let offset: Int
                if let number = input["offset"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue), (0...64).contains(number.intValue) { offset = number.intValue }
                else if input["offset"] == nil { offset = 0 }
                else { throw AkittyError.core("Invalid pane-list offset.") }
                result = ["panes": panes.dropFirst(offset).prefix(16).map { terminal -> [String: Any] in
                    ["pane": paneID(terminal), "event_session": sessions[terminal.session.id] ?? "unknown", "title_untrusted": String(ProgramStatusRecord.displayText(terminal.snapshot?.title ?? "Terminal").prefix(32)),
                     "input_agent_controlled": terminal.snapshot?.control?.agent == true,
                     "execution": "request_requires_human_approval", "ordinary_agent_operations": "observation_only"]
                }, "next_offset": offset + 16 < panes.count ? offset + 16 : NSNull(), "total_panes": panes.count]
            } else if operation == "request", Set(input.keys) == ["version", "op", "pane", "command"],
                      let supplied = input["pane"] as? String, let command = input["command"] as? String {
                // An ID copied by hand from older list output can still carry JSON's `\/` escape (issue #26).
                let pane = supplied.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\/", with: "/")
                guard let terminal = panes.first(where: { paneID($0) == pane }) else {
                    throw AkittyError.core(pane.hasPrefix(instance + "/")
                        ? "Pane \(pane) is no longer open. Run list again and use a current pane value."
                        : "Pane identifier is from another AkiTTY launch or was copied incorrectly. Run list again and use a current pane value.")
                }
                result = try await request(command, in: terminal, origin: .localProcess(peer))
            } else if operation == "request" || operation == "list" {
                throw AkittyError.core("Unknown or missing fields for \(operation). See akitty-agent usage.")
            } else { throw AkittyError.core("Unsupported request operation.") }
            return try JSONSerialization.data(withJSONObject: ["version": 1, "ok": true, "data": result], options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            collectAll(drain: true)
            return (try? JSONSerialization.data(withJSONObject: ["version": 1, "ok": false, "error": error.localizedDescription], options: [.withoutEscapingSlashes])) ?? Data()
        }
    }
    // The injected monotonic clock lets tests cross the deadline without racing AppKit's timer.
    static func present(_ alert: NSAlert, in window: NSWindow, timeout: TimeInterval = 120, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, valid: @escaping () -> Bool = { true }) async -> Bool {
        let deadline = now() + timeout
        return await withCheckedContinuation { continuation in
            // The continuation must resume exactly once. If the window closes underneath the sheet (a shell
            // exiting closes its window directly), AppKit may never call the completion handler; without the
            // fallback below the request would hang and the server would answer "busy" until restarted.
            let once = ResumeOnce(continuation)
            var timers: [Timer] = []
            let finish: (Bool) -> Void = { approved in timers.forEach { $0.invalidate() }; once.resume(approved) }
            timers.append(Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak window, weak alert] _ in
                MainActor.assumeIsolated {
                    if let alert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
                    else { finish(false) }
                }
            })
            timers.append(Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak window, weak alert] _ in
                MainActor.assumeIsolated {
                    guard let alert, let window, window.attachedSheet === alert.window else { finish(false); return }
                    if !valid() { window.endSheet(alert.window, returnCode: .alertSecondButtonReturn) }
                }
            })
            alert.beginSheetModal(for: window) {
                finish($0 == .alertFirstButtonReturn && now() < deadline && valid())
            }
            alert.window.makeFirstResponder(alert.buttons[1])
        }
    }
    func showTimeline() {
        collectAll(drain: true)
        do {
            let data = try store.export()
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 820, height: 460)); text.isEditable = false; text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .medium
            let entries = data.split(separator: 10).map { line -> String in
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let event = record["event"] as? String, let source = record["provenance"] as? String else { return "Unreadable local record — evidence is incomplete." }
                let time = (record["time_ms"] as? Double).map { formatter.string(from: Date(timeIntervalSince1970: $0 / 1000)) } ?? "Unknown time"
                let provenance = source == "host" ? "Host record" : source == "shell_untrusted" ? "Shell report (unverified)" : "Program report (unverified)"
                var details: [String] = []
                if let fields = record["fields"] as? [String: Any] {
                    if let pid = fields["peer_pid"] { details.append("Connection opened by process \(pid)") }
                    if let pane = fields["pane_session_id"] { details.append("Terminal \(pane)") }
                    if let hash = fields["command_sha256"] as? String { details.append("Command fingerprint \(hash.prefix(12))") }
                    if let counts = fields["state_counts"] as? [String: Int] {
                        let summary = counts.keys.sorted().map { "\($0) \(counts[$0]!)" }.joined(separator: ", ")
                        details.append(summary.isEmpty ? "No active reports" : "Reported states: \(summary)")
                    }
                    if event == "source_gap" || event == "retention_rotated" || event == "incomplete_record_dropped" { details.append("Some earlier observations are unavailable") }
                }
                let session = String((record["session"] as? String ?? "unknown").prefix(8))
                return "\(time) · \(ProgramStatusRecord.displayText(event.replacingOccurrences(of: "_", with: " ")))\n  \(provenance) · Session \(session)\(details.isEmpty ? "" : " · " + details.joined(separator: " · "))"
            }
            text.string = "Local event timeline. Program and shell observations are unverified. Commands are fingerprinted, not stored here. Earlier records may be missing. This is not a tamper-proof audit.\n\(failure.map { "Recording warning: \($0)\n" } ?? "")\n" + entries.joined(separator: "\n\n")
            text.setAccessibilityLabel("Agent event timeline with event sources and retention warnings")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 840, height: 480)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            text.frame = NSRect(origin: .zero, size: scroll.contentSize)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
            text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true; scroll.documentView = text
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Agent Event Timeline"; window.contentView = scroll; window.center()
            timeline = NSWindowController(window: window); timeline?.showWindow(nil); window.makeKeyAndOrderFront(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    func exportEvents() {
        collectAll(drain: true)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "akitty-events.jsonl"
        panel.message = "Exports retained local metadata with command hashes. Program and shell reports are unverified; records may have gaps."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export().write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }
}

/// Resumes a checked continuation at most once; later calls are ignored. Main-thread only.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
        continuation?.resume(returning: value); continuation = nil
    }
}
