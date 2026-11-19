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
    /// A visible approval sheet. Each window shows at most one; each pane presents only its queue head.
    private struct Presented { weak var window: NSWindow?; weak var sheet: NSWindow?; let local: Bool }
    private var presented: [String: Presented] = [:]
    /// Windows reserved by a request between leaving the queue and attaching its sheet.
    private var reservedWindows: Set<ObjectIdentifier> = []
    /// Per-window time before which the next sheet may not appear: a click meant for one sheet must not land on the next.
    private var windowReadyTime: [ObjectIdentifier: TimeInterval] = [:]
    /// FIFO request IDs per pane session. Only the head can be presented or approved.
    private var queues: [UInt64: [String]] = [:]
    private var records: [String: RequestRecord] = [:]
    private var finishedOrder: [String] = []
    /// Every caller-chosen ID seen this launch, kept after its status record is evicted so an ID never dispatches twice.
    private var seenRequestIDs: Set<String> = []
    static let seenRequestIDLimit = 4096
    /// Requests between enqueue and the end of their unwinding, including audit writes after leaving the queue.
    private var inFlight = 0
    /// Whether any request is queued, presented, or still unwinding.
    var hasActiveRequest: Bool { inFlight > 0 }
    private var stopped = false
    private var timeline: NSWindowController?
    var cooldownInterval: TimeInterval = 3
    /// Total lifetime of a request from enqueue; the sheet receives the remainder.
    var requestTimeout: TimeInterval = 120
    /// A queued request whose remaining time is shorter than this expires instead of flashing a sheet.
    var minimumReviewTime: TimeInterval = 10
    static let perPaneLimit = 8
    static let appLimit = 64
    static let finishedHistoryLimit = 256
    struct RequestRecord {
        let id: String
        let pane: String
        let paneSession: UInt64
        let enqueued: TimeInterval
        var state: String
        /// A permission decision can pass command requests that wait only for the pane's lease.
        var decision = false
    }
    /// A request failure that carries its request ID back to the caller.
    struct RequestFailure: LocalizedError {
        let message: String
        let requestID: String?
        var errorDescription: String? { message }
    }
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
            self.agentSessions.removeValue(forKey: id)
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
            cancelPendingApproval(localOnly: true)
        }
    }
    func stop() { stopped = true; cancelPendingApproval(); try? setEnabled(false); collectAll(drain: true); timer?.invalidate(); timer = nil }
    private func cancelPendingApproval(localOnly: Bool = false) {
        for (id, entry) in presented where !localOnly || entry.local { endSheet(id) }
    }
    private func endSheet(_ id: String) {
        guard let entry = presented[id], let sheet = entry.sheet, let window = entry.window, window.attachedSheet === sheet else { return }
        window.endSheet(sheet, returnCode: .abort)
    }
    /// Pending approvals for one pane: how many, and how long the oldest has waited.
    func pendingSummary(for sessionID: UInt64) -> (count: Int, oldestWait: TimeInterval)? {
        guard let queue = queues[sessionID], let first = queue.first, let record = records[first] else { return nil }
        return (queue.count, max(0, ProcessInfo.processInfo.systemUptime - record.enqueued))
    }
    /// Current state of a request this launch received. Any same-user process can ask, so the reply carries no
    /// command text or fingerprint: a hash of a short command is easy to guess.
    func status(of requestID: String) -> [String: Any]? {
        guard let record = records[requestID] else { return nil }
        var result: [String: Any] = ["request_id": record.id, "state": record.state, "pane": record.pane]
        if let position = queues[record.paneSession]?.firstIndex(of: record.id) { result["queue_position"] = position }
        return result
    }
    static func isValidRequestID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._:-".unicodeScalars.contains($0) }
    }
    /// Leaves the pane's queue at once, so the next request does not wait behind this one's audit write.
    private func dequeue(_ id: String, state: String) {
        guard var record = records[id] else { return }
        record.state = state; records[id] = record
        if var queue = queues[record.paneSession] {
            queue.removeAll { $0 == id }
            queues[record.paneSession] = queue.isEmpty ? nil : queue
        }
    }
    private func finish(_ id: String, state: String) {
        dequeue(id, state: state)
        finishedOrder.append(id)
        while finishedOrder.count > Self.finishedHistoryLimit { records.removeValue(forKey: finishedOrder.removeFirst()) }
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
    /// Ends a request before approval without dispatch. `state` is what `status` reports.
    private struct QueueEnd: LocalizedError {
        let message: String
        let state: String
        var errorDescription: String? { message }
    }
    /// Waits until this request is its pane's oldest and its window can show a sheet. No lease is held while queued,
    /// so a waiting request never blocks human input. Returns the window that will carry the sheet.
    private func waitForTurn(id: String, terminal: TerminalView, origin: Origin, deadline: TimeInterval, requireUnleased: Bool) async throws -> NSWindow {
        var round = 0
        while true {
            try Task.checkCancellation()
            guard !stopped, origin.isValid(enabled: enabled) else {
                throw QueueEnd(message: "The caller disconnected or Local Agent Requests stopped before approval. Nothing was dispatched.", state: "cancelled")
            }
            var head = queues[terminal.session.id]?.first == id
            // A command request held back only by the pane's lease (an approved command awaiting reclaim) must not
            // hold back the agent's own permission prompt behind it.
            if !head, !requireUnleased, records[id]?.decision == true, let queue = queues[terminal.session.id], let index = queue.firstIndex(of: id),
               queue[..<index].allSatisfy({ records[$0]?.decision == false && records[$0]?.state == "queued" }),
               (try? terminal.session.shellState())?.control?.agent == true { head = true }
            // Enumerating panes is the costly check; a request behind others repeats it about once a second.
            let checkSource = head || round % 10 == 0
            round += 1
            guard !terminal.isShutdown, !checkSource || source().contains(where: { $0 === terminal }) else {
                throw QueueEnd(message: "Request source or target terminal is no longer available. Nothing was dispatched.", state: "cancelled")
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard deadline - now >= minimumReviewTime else {
                throw QueueEnd(message: "Approval request expired while queued behind earlier requests for this pane. Nothing was dispatched; do not automatically retry.", state: "expired")
            }
            if head, let window = terminal.window {
                let key = ObjectIdentifier(window)
                // While another approval is on screen, a new sheet attaches quietly and needs a window the human can see.
                // An approved command keeps its pane leased until the human reclaims it. The next request waits for
                // that instead of failing to acquire control; it still expires on its own schedule.
                if !reservedWindows.contains(key), window.attachedSheet == nil, now >= windowReadyTime[key] ?? 0,
                   presented.isEmpty || (window.isVisible && !window.isMiniaturized),
                   !requireUnleased || (try? terminal.session.shellState()).map({ $0.control?.agent != true }) == true { return window }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    /// Checks a request's ID and limits, then queues it for its pane. The caller must balance it with `release`.
    private func admit(requestID: String?, terminal: TerminalView, origin: Origin) throws -> (id: String, deadline: TimeInterval) {
        if let requestID {
            guard Self.isValidRequestID(requestID) else {
                throw RequestFailure(message: "Invalid request_id. Use 1 to 64 letters, digits, '.', '_', ':' or '-'.", requestID: nil)
            }
            // Assigned IDs are in `records` too: a caller must not take over one AkiTTY handed out.
            if seenRequestIDs.contains(requestID) || records[requestID] != nil {
                let state = records[requestID].map { " (state: \($0.state))" } ?? ""
                throw RequestFailure(message: "Request \(requestID) was already received in this launch\(state). It was not queued or dispatched again; use status to check it.", requestID: requestID)
            }
            guard seenRequestIDs.count < Self.seenRequestIDLimit else {
                throw RequestFailure(message: "This launch has recorded \(Self.seenRequestIDLimit) caller-chosen request IDs. Omit request_id to let AkiTTY assign one.", requestID: requestID)
            }
        }
        guard !stopped, origin.isValid(enabled: enabled), !terminal.isShutdown,
              source().contains(where: { $0 === terminal }), terminal.window != nil else {
            throw AkittyError.core("Request source or target terminal is no longer available.")
        }
        guard failure == nil else { throw AkittyError.core("Event recording failed; restart AkiTTY after restoring event storage.") }
        let pane = terminal.session.id
        guard (queues[pane]?.count ?? 0) < Self.perPaneLimit else {
            throw AkittyError.core("This pane already has \(Self.perPaneLimit) requests awaiting approval. Request not queued; do not automatically retry.")
        }
        guard queues.values.reduce(0, { $0 + $1.count }) < Self.appLimit else {
            throw AkittyError.core("AkiTTY already has \(Self.appLimit) requests awaiting approval. Request not queued; do not automatically retry.")
        }
        let id = requestID ?? UUID().uuidString
        let enqueued = ProcessInfo.processInfo.systemUptime
        if requestID != nil { seenRequestIDs.insert(id) }
        records[id] = RequestRecord(id: id, pane: paneID(terminal), paneSession: pane, enqueued: enqueued, state: "queued")
        queues[pane, default: []].append(id)
        inFlight += 1
        return (id, enqueued + requestTimeout)
    }
    /// Ends a request's slot: frees its window (arming the cooldown only after a sheet the human saw) and records its state.
    private func release(_ id: String, reserved: ObjectIdentifier?, prompted: Bool, outcome: String) {
        if let reserved {
            reservedWindows.remove(reserved)
            if prompted {
                let now = ProcessInfo.processInfo.systemUptime
                windowReadyTime = windowReadyTime.filter { $0.value > now }
                windowReadyTime[reserved] = now + cooldownInterval
            }
        }
        presented.removeValue(forKey: id)
        finish(id, state: outcome)
        inFlight -= 1
    }
    /// Shows one approval sheet for the request at its pane's head. Throws, rather than returning a denial, when
    /// no sheet could be shown. Returns the human's answer, or `.unanswered` when the sheet ended any other way.
    private func showSheet(_ alert: NSAlert, id: String, window: NSWindow, terminal: TerminalView, origin: Origin,
                           deadline: TimeInterval, onShown: () -> Void) async throws -> Answer {
        if Task.isCancelled { throw CancellationError() }
        guard !stopped, origin.isValid(enabled: enabled), !terminal.isShutdown,
              terminal.window === window, window.attachedSheet == nil else {
            throw AkittyError.core("The approval could not be shown because the caller, pane or window changed. Nothing was dispatched; do not automatically retry.")
        }
        // Only the first visible approval takes focus; later ones attach quietly and wait for the human.
        // Decided here, from live state, so two windows reaching this point together cannot both activate.
        let quiet = presented.keys.contains(where: { $0 != id })
        // A quiet sheet does not bring its window forward, so the window must still be on screen now.
        if quiet, !window.isVisible || window.isMiniaturized {
            throw AkittyError.core("The approval could not be shown because its window was hidden. Nothing was dispatched; do not automatically retry.")
        }
        if quiet { NSApp.requestUserAttention(.informationalRequest) }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        let local: Bool
        if case .localProcess = origin { local = true } else { local = false }
        presented[id] = Presented(window: window, sheet: alert.window, local: local)
        onShown()
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let answer = await Self.answer(alert, in: window, timeout: remaining, valid: { [weak self, weak terminal] in
            guard let self, let terminal else { return false }
            return !self.stopped && origin.isValid(enabled: self.enabled) && !terminal.isShutdown && terminal.window === window && window.isVisible
        })
        // The sheet ended from a hidden window or cancelled intent; never let that read as approval.
        if Task.isCancelled { throw CancellationError() }
        guard answer == .allow else { return answer }
        return !stopped && origin.isValid(enabled: enabled) && !terminal.isShutdown ? .allow : .unanswered
    }
    /// Records how a request ended and converts the error for its caller.
    private func conclude(_ error: Error, id: String, eventSession: String, outcome: inout String) async -> Error {
        collectAll(drain: true)
        if let end = error as? QueueEnd {
            outcome = end.state
            dequeue(id, state: outcome)
            do { try await store.appendDurably(event: end.state == "expired" ? "request_expired" : "request_cancelled", session: eventSession, provenance: "host", fields: ["request_id": id]) }
            catch { failure = error.localizedDescription }
        } else if error is CancellationError {
            outcome = "cancelled"
            dequeue(id, state: outcome)
            // The intent was cancelled (not denied by a human); record who ended the wait before rethrowing.
            do { try await store.appendDurably(event: "request_cancelled", session: eventSession, provenance: "host", fields: ["request_id": id]) }
            catch { failure = error.localizedDescription }
            return error
        } else if error.localizedDescription.contains("Dispatch outcome is unknown") {
            outcome = "outcome_unknown"
            dequeue(id, state: outcome)
            do { try await store.appendDurably(event: "dispatch_outcome_unknown", session: eventSession, provenance: "host", fields: ["request_id": id]) }
            catch { failure = error.localizedDescription }
        } else if error.localizedDescription.contains("Command execution denied") {
            outcome = "denied"
        } else if outcome != "outcome_unknown" { outcome = "failed" }
        return RequestFailure(message: error.localizedDescription, requestID: id)
    }
    /// System intents and socket requests share approval and audit handling.
    /// Siri does not enable the local socket or carry core authorizations.
    /// Requests for different panes queue independently. Each pane presents only its oldest request, and
    /// a request's lifetime (120 s by default) counts from enqueue; waiting never extends it.
    func request(_ command: String, in terminal: TerminalView, origin: Origin, requestID: String? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        try AgentCommandHost.validateCommand(command)
        let (id, deadline) = try admit(requestID: requestID, terminal: terminal, origin: origin)
        // The cooldown only follows a sheet the human actually saw: a request that failed before display
        // (a busy shell) must not delay the immediate retry.
        var prompted = false
        var reserved: ObjectIdentifier?
        var outcome = "failed"
        defer { release(id, reserved: reserved, prompted: prompted, outcome: outcome) }
        startRecording(); register(terminal)
        let eventSession = sessions[terminal.session.id] ?? "unknown"
        do {
            return try await withTaskCancellationHandler {
                let window = try await waitForTurn(id: id, terminal: terminal, origin: origin, deadline: deadline, requireUnleased: true)
                let key = ObjectIdentifier(window); reserved = key; reservedWindows.insert(key)
                records[id]?.state = "awaiting_approval"
                // Persist intent before acquiring authority; an I/O failure prevents dispatch.
                try await store.appendDurably(event: "execution_requested", session: eventSession, provenance: "host",
                    fields: origin.fields.merging(["pane_session_id": terminal.session.id, "request_id": id, "command_sha256": AgentEventStore.digest(command), "command_bytes": command.utf8.count]) { _, value in value })
                try Task.checkCancellation()
                guard !stopped, origin.isValid(enabled: enabled) else { throw AkittyError.core("Request service or caller has stopped.") }
                let receipt = try await AgentCommandHost(session: terminal.session).execute(actor: origin.actor, command: command) { [weak self] request in
                    // A cancelled intent or an unshown sheet is not a human denial: throwing releases the lease instead.
                    guard let self else { throw CancellationError() }
                    let alert = AgentCommandHost.approvalAlert(request, callerDescription: origin.explanation)
                    // Anything but an explicit allow fails closed for a command: nothing is typed.
                    return try await self.showSheet(alert, id: id, window: window, terminal: terminal, origin: origin, deadline: deadline) { prompted = true } == .allow
                }
                outcome = "dispatched"
                record(terminal, drain: true)
                guard failure == nil else {
                    outcome = "outcome_unknown"
                    throw AkittyError.core("Command was dispatched, but event recording failed. Outcome is uncertain; do not retry automatically.")
                }
                return ["accepted": receipt.dispatch.accepted, "after_command_id": receipt.dispatch.after_command_id, "event_session": eventSession,
                    "request_id": id, "completion_untrusted": true, "input_remains_leased": true,
                    "next_step": "Review the terminal, then use Reclaim Terminal Control. It does not stop the process."]
            } onCancel: {
                Task { @MainActor [weak self] in self?.endSheet(id) }
            }
        } catch {
            throw await conclude(error, id: id, eventSession: eventSession, outcome: &outcome)
        }
    }

    // MARK: Agent permission decisions

    /// An agent's own permission prompt, answered in AkiTTY. The agent runs the tool itself; AkiTTY never writes input.
    struct PermissionRequest {
        let agent: String
        let tool: String
        let command: String
        let cwd: String?
        let reason: String?
    }
    nonisolated static let agentNames = ["claude-code": "Claude Code"]
    /// Shell commands shown for a decision may span lines, but no other control or invisible formatting character.
    static func validateDecisionCommand(_ command: String) throws {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.utf8.count <= 4096,
              !command.unicodeScalars.contains(where: { ($0 != "\n" && $0 != "\t" && CharacterSet.controlCharacters.contains($0)) || $0.properties.generalCategory == .format }) else {
            throw AkittyError.core("Command must be at most 4096 bytes without control characters other than line breaks and tabs, or invisible formatting characters.")
        }
    }
    static func decisionAlert(_ request: PermissionRequest, pane: UInt64) -> NSAlert {
        let name = agentNames[request.agent] ?? request.agent
        let alert = NSAlert(); alert.messageText = "Allow \(name) to run this \(request.tool) command?"
        let reason = request.reason.map { "\nReason given by \(name): \(ProgramStatusRecord.displayText(String($0.prefix(300))))" } ?? ""
        alert.informativeText = "Terminal \(pane)\nDirectory reported by \(name): \(request.cwd.map { ProgramStatusRecord.displayText(String($0.prefix(512))) } ?? "unknown")\(reason)"
        alert.addButton(withTitle: "Allow Once"); alert.addButton(withTitle: "Deny")
        alert.buttons[0].keyEquivalent = ""
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        alert.window.initialFirstResponder = alert.buttons[1]
        alert.buttons[0].setAccessibilityHelp("Answer \(name)'s permission prompt with allow, once. \(name) runs the command itself.")
        alert.buttons[1].setAccessibilityHelp("Answer \(name)'s permission prompt with deny.")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 140))
        text.isEditable = false; text.isSelectable = true; text.isVerticallyResizable = true
        text.isHorizontallyResizable = false; text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.string = request.command
        text.setAccessibilityLabel("Complete exact command")
        let scroll = NSScrollView(frame: text.frame); scroll.hasVerticalScroller = true; scroll.documentView = text
        let note = NSTextField(wrappingLabelWithString: "\(name) asked from a process running in this terminal. \(name) runs the command itself, under its own sandbox and permission settings; AkiTTY only returns your answer and sends no input. The agent's identity, directory and reason are not verified.")
        let stack = NSStackView(views: [scroll, note]); stack.orientation = .vertical; stack.alignment = .leading
        scroll.widthAnchor.constraint(equalToConstant: 480).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        alert.accessoryView = stack
        return alert
    }
    /// Queues an agent's permission prompt behind the pane's other requests and returns the human's answer.
    /// A timeout, cancellation or unshown sheet is not an answer: it throws, so the agent falls back to its own prompt.
    func decide(_ request: PermissionRequest, in terminal: TerminalView, origin: Origin, requestID: String? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        try Self.validateDecisionCommand(request.command)
        let (id, deadline) = try admit(requestID: requestID, terminal: terminal, origin: origin)
        records[id]?.decision = true
        var prompted = false
        var reserved: ObjectIdentifier?
        var outcome = "failed"
        defer { release(id, reserved: reserved, prompted: prompted, outcome: outcome) }
        startRecording(); register(terminal)
        let eventSession = sessions[terminal.session.id] ?? "unknown"
        do {
            return try await withTaskCancellationHandler {
                // The agent's pane is busy running the agent, so neither a ready prompt nor a free lease is required.
                let window = try await waitForTurn(id: id, terminal: terminal, origin: origin, deadline: deadline, requireUnleased: false)
                let key = ObjectIdentifier(window); reserved = key; reservedWindows.insert(key)
                records[id]?.state = "awaiting_approval"
                try await store.appendDurably(event: "permission_requested", session: eventSession, provenance: "host",
                    fields: origin.fields.merging(["pane_session_id": terminal.session.id, "request_id": id, "agent_reported": request.agent, "tool": request.tool,
                                                   "command_sha256": AgentEventStore.digest(request.command), "command_bytes": request.command.utf8.count]) { _, value in value })
                try Task.checkCancellation()
                let alert = Self.decisionAlert(request, pane: terminal.session.id)
                let answer = try await showSheet(alert, id: id, window: window, terminal: terminal, origin: origin, deadline: deadline) { prompted = true }
                // Only a click is an answer. A timeout, or a caller, pane or window that went away, leaves the agent's own prompt.
                guard answer != .unanswered else {
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        throw QueueEnd(message: "The permission prompt expired without an answer. The agent keeps its own prompt.", state: "expired")
                    }
                    throw QueueEnd(message: "The caller disconnected, or the pane or its window went away, before an answer.", state: "cancelled")
                }
                let allowed = answer == .allow
                outcome = allowed ? "allowed" : "denied"
                do { try await store.appendDurably(event: allowed ? "permission_allowed" : "permission_denied", session: eventSession, provenance: "host", fields: ["request_id": id]) }
                catch {
                    // A human Deny stands even if it could not be recorded; an unrecorded Allow fails closed.
                    failure = error.localizedDescription
                    if allowed { outcome = "failed"; throw error }
                }
                return ["decision": allowed ? "allow" : "deny", "request_id": id, "executor": request.agent, "akitty_sent_input": false]
            } onCancel: {
                Task { @MainActor [weak self] in self?.endSheet(id) }
            }
        } catch {
            throw await conclude(error, id: id, eventSession: eventSession, outcome: &outcome)
        }
    }
    /// The pane whose PTY is the caller's controlling terminal. Nil when the caller runs outside every pane.
    func pane(for peer: LocalPeer) -> TerminalView? {
        guard let device = peer.controllingTerminal else { return nil }
        return source().first { !$0.isShutdown && (try? $0.session.shellState())?.tty_device == device }
    }

    // MARK: Agent session reports

    /// What an agent reported about its conversation in a pane. Unverified: any program in the pane could send it.
    struct AgentSession: Equatable {
        let agent: String
        let sessionID: String
        var ended: Bool
        var reported: Date
    }
    private(set) var agentSessions: [UInt64: AgentSession] = [:]
    func agentSession(for sessionID: UInt64) -> AgentSession? { agentSessions[sessionID] }
    static func isValidAgentSessionID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_.".unicodeScalars.contains($0) }
    }
    func report(agent: String, event: String, sessionID: String, in terminal: TerminalView) {
        let pane = terminal.session.id
        if event == "session_end" {
            guard agentSessions[pane]?.sessionID == sessionID else { return }
            agentSessions[pane]?.ended = true; agentSessions[pane]?.reported = Date()
        } else {
            agentSessions[pane] = AgentSession(agent: agent, sessionID: sessionID, ended: false, reported: Date())
        }
        persist(event: event == "session_end" ? "agent_session_ended" : "agent_session_reported", id: pane, provenance: "program_untrusted", fields: ["agent_reported": agent])
    }
    func handle(_ data: Data, peer: LocalPeer) async -> Data {
        var suppliedID: String?
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
            } else if operation == "status", Set(input.keys) == ["version", "op", "request_id"], let requestID = input["request_id"] as? String {
                guard Self.isValidRequestID(requestID) else { throw AkittyError.core("Invalid request_id.") }
                guard let state = status(of: requestID) else { throw AkittyError.core("Unknown request_id for this AkiTTY launch. Finished requests are kept for the most recent \(Self.finishedHistoryLimit).") }
                result = state
            } else if operation == "request", Set(input.keys) == ["version", "op", "pane", "command"] || Set(input.keys) == ["version", "op", "pane", "command", "request_id"],
                      let supplied = input["pane"] as? String, let command = input["command"] as? String {
                let requestID: String?
                if input["request_id"] == nil { requestID = nil }
                else if let value = input["request_id"] as? String { requestID = value; if Self.isValidRequestID(value) { suppliedID = value } }
                else { throw AkittyError.core("Invalid request_id.") }
                // An ID copied by hand from older list output can still carry JSON's `\/` escape (issue #26).
                let pane = supplied.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\/", with: "/")
                guard let terminal = panes.first(where: { paneID($0) == pane }) else {
                    throw AkittyError.core(pane.hasPrefix(instance + "/")
                        ? "Pane \(pane) is no longer open. Run list again and use a current pane value."
                        : "Pane identifier is from another AkiTTY launch or was copied incorrectly. Run list again and use a current pane value.")
                }
                result = try await request(command, in: terminal, origin: .localProcess(peer), requestID: requestID)
            } else if operation == "decide", Set(input.keys).isSubset(of: ["version", "op", "agent", "tool", "command", "cwd", "reason", "request_id"]),
                      let agent = input["agent"] as? String, let tool = input["tool"] as? String, let command = input["command"] as? String {
                guard Self.agentNames[agent] != nil, tool == "Bash" else { throw AkittyError.core("Unsupported agent or tool; the agent keeps its own prompt.") }
                let cwd = input["cwd"], reason = input["reason"], suppliedRequestID = input["request_id"]
                guard cwd == nil || cwd is String, reason == nil || reason is String, suppliedRequestID == nil || suppliedRequestID is String else { throw AkittyError.core("Invalid decide fields.") }
                if let value = suppliedRequestID as? String, Self.isValidRequestID(value) { suppliedID = value }
                guard let terminal = pane(for: peer) else {
                    throw AkittyError.core("The caller is not running inside an AkiTTY pane; the agent keeps its own prompt.")
                }
                result = try await decide(PermissionRequest(agent: agent, tool: tool, command: command, cwd: cwd as? String, reason: reason as? String),
                                          in: terminal, origin: .localProcess(peer), requestID: suppliedRequestID as? String)
            } else if operation == "report", Set(input.keys).isSubset(of: ["version", "op", "agent", "event", "session_id"]),
                      let agent = input["agent"] as? String, let event = input["event"] as? String, let sessionID = input["session_id"] as? String {
                guard Self.agentNames[agent] != nil, ["session_start", "session_end"].contains(event), Self.isValidAgentSessionID(sessionID) else {
                    throw AkittyError.core("Invalid agent report.")
                }
                guard let terminal = pane(for: peer) else { throw AkittyError.core("The caller is not running inside an AkiTTY pane.") }
                report(agent: agent, event: event, sessionID: sessionID, in: terminal)
                result = ["recorded": true, "pane": paneID(terminal)]
            } else if ["request", "list", "status", "decide", "report"].contains(operation) {
                throw AkittyError.core("Unknown or missing fields for \(operation). See akitty-agent usage.")
            } else { throw AkittyError.core("Unsupported request operation.") }
            return try JSONSerialization.data(withJSONObject: ["version": 1, "ok": true, "data": result], options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            collectAll(drain: true)
            var envelope: [String: Any] = ["version": 1, "ok": false, "error": error.localizedDescription]
            if let id = (error as? RequestFailure)?.requestID ?? suppliedID { envelope["request_id"] = id }
            return (try? JSONSerialization.data(withJSONObject: envelope, options: [.withoutEscapingSlashes])) ?? Data()
        }
    }
    /// How an approval sheet ended. Only a click on a button is an answer; AkiTTY's own dismissals end it as `.abort`.
    enum Answer: Equatable { case allow, deny, unanswered }
    // The injected monotonic clock lets tests cross the deadline without racing AppKit's timer.
    static func present(_ alert: NSAlert, in window: NSWindow, timeout: TimeInterval = 120, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, valid: @escaping () -> Bool = { true }) async -> Bool {
        await answer(alert, in: window, timeout: timeout, now: now, valid: valid) == .allow
    }
    static func answer(_ alert: NSAlert, in window: NSWindow, timeout: TimeInterval = 120, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, valid: @escaping () -> Bool = { true }) async -> Answer {
        let deadline = now() + timeout
        return await withCheckedContinuation { continuation in
            // The continuation must resume exactly once. If the window closes underneath the sheet (a shell
            // exiting closes its window directly), AppKit may never call the completion handler; without the
            // fallback below the request would hang and the server would answer "busy" until restarted.
            let once = ResumeOnce(continuation)
            var timers: [Timer] = []
            let finish: (Answer) -> Void = { answer in timers.forEach { $0.invalidate() }; once.resume(answer) }
            timers.append(Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak window, weak alert] _ in
                MainActor.assumeIsolated {
                    if let alert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
                    else { finish(.unanswered) }
                }
            })
            timers.append(Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak window, weak alert] _ in
                MainActor.assumeIsolated {
                    guard let alert, let window, window.attachedSheet === alert.window else { finish(.unanswered); return }
                    if !valid() { window.endSheet(alert.window, returnCode: .abort) }
                }
            })
            alert.beginSheetModal(for: window) { code in
                // A click after the deadline, or once its caller or pane is gone, reaches no one: it is not an answer.
                guard now() < deadline, valid() else { finish(.unanswered); return }
                finish(code == .alertFirstButtonReturn ? .allow : code == .alertSecondButtonReturn ? .deny : .unanswered)
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
private final class ResumeOnce<Value>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
        continuation?.resume(returning: value); continuation = nil
    }
}
