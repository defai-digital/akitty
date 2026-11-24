import AppKit

@MainActor private final class AgentOverviewTable: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\r", event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           selectedRow >= 0, let action = doubleAction {
            NSApp.sendAction(action, to: target, from: self)
        } else { super.keyDown(with: event) }
    }
}

/// One pane in the agent overview, built only from snapshot fields. Sources stay apart: `controller` is the core's
/// control lease (host state), `programStatus` is program chrome any PTY program can send, and `shellDirectory` is
/// untrusted shell metadata. Terminal text is never read, so no status is inferred from output.
struct AgentOverviewRow: Equatable {
    let sessionID: UInt64
    let title: String
    let controller: String
    let agentControlled: Bool
    let programStatus: String?
    let shellDirectory: String?
    let state: String
    let executionEntry: String
    /// Host-held approval queue for this pane, e.g. "2 waiting · oldest 14 s".
    let approvals: String
    /// The conversation an agent in this pane reported, e.g. "Claude Code · 0f3a…"; unverified.
    let agentSession: String

    static func describe(_ session: AgentRequests.AgentSession) -> String {
        let name = AgentRequests.agentNames[session.agent] ?? session.agent
        return "\(name) · \(session.sessionID.prefix(8))\(session.sessionID.count > 8 ? "…" : "")\(session.ended ? " (ended)" : "")"
    }

    init(sessionID: UInt64, snapshot: Snapshot?, requestsEnabled: Bool = false, pending: (count: Int, oldestWait: TimeInterval)? = nil, agentSession: String? = nil) {
        self.sessionID = sessionID
        self.agentSession = agentSession ?? "—"
        approvals = pending.map { "\($0.count) waiting · oldest \(Int($0.oldestWait.rounded(.down))) s" } ?? "None"
        title = snapshot?.title ?? ""
        agentControlled = snapshot?.control?.agent == true
        controller = agentControlled ? "Agent: \(snapshot?.control?.owner ?? "unknown")" : "Human"
        var reported: [String] = []
        switch snapshot?.chrome?.mark {
        case .idle?: reported.append("idle")
        case .busy?: reported.append("busy")
        case .error?: reported.append("error")
        case .frame?, nil: break
        }
        if let presentation = snapshot?.chrome?.presentation { reported.append(presentation) }
        if let status = snapshot?.program_status?.presentation { reported.insert(status, at: 0) }
        programStatus = reported.isEmpty ? nil : reported.joined(separator: " · ")
        shellDirectory = snapshot?.shell?.cwd
        executionEntry = agentControlled ? "Host input lease" : requestsEnabled && snapshot?.shell?.ready == true ? "Request with human approval" : "Observation only"
        if let snapshot, snapshot.exited { state = "Exited (\(snapshot.exit_code.map(String.init) ?? "closed"))" }
        else { state = snapshot == nil ? "Starting" : "Running" }
    }
}

/// Lists every terminal pane with who controls it and what its programs report, and offers the human actions that
/// already exist: show the pane and reclaim control. It never approves, executes, or sends input.
@MainActor final class AgentOverviewController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    struct Entry {
        weak var window: TerminalWindow?
        weak var terminal: TerminalView?
        let row: AgentOverviewRow
    }
    private let source: () -> [TerminalWindow]
    private let requestsEnabled: () -> Bool
    private let pending: (UInt64) -> (count: Int, oldestWait: TimeInterval)?
    private let agentSession: (UInt64) -> String?
    private let resume: (TerminalView) throws -> Void
    private let onShow: (TerminalWindow, TerminalView) -> Void
    private(set) var entries: [Entry] = []
    let table: NSTableView = AgentOverviewTable()
    let showButton = NSButton(title: "Show Terminal", target: nil, action: nil)
    let reclaimButton = NSButton(title: "Reclaim Control", target: nil, action: nil)
    let resumeButton = NSButton(title: "Resume Conversation", target: nil, action: nil)
    private var timer: Timer?
    var refreshTimerActive: Bool { timer?.isValid == true }
    private static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("terminal", "Terminal", 180), ("control", "Control (host)", 140), ("program", "Program reports (unverified)", 200),
        ("directory", "Shell directory (unverified)", 180), ("execution", "Execution entry", 180), ("approvals", "Approvals (host)", 150), ("session", "Agent session (reported)", 170), ("state", "Shell state", 90)
    ]

    init(source: @escaping () -> [TerminalWindow], requestsEnabled: @escaping () -> Bool = { false },
         pending: @escaping (UInt64) -> (count: Int, oldestWait: TimeInterval)? = { _ in nil },
         agentSession: @escaping (UInt64) -> String? = { _ in nil }, resume: @escaping (TerminalView) throws -> Void = { _ in },
         onShow: @escaping (TerminalWindow, TerminalView) -> Void) {
        self.source = source; self.requestsEnabled = requestsEnabled; self.pending = pending; self.agentSession = agentSession; self.resume = resume; self.onShow = onShow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 340), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Agent Overview"; window.minSize = NSSize(width: 520, height: 200); window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        for column in Self.columns {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            item.title = column.title; item.width = column.width
            table.addTableColumn(item)
        }
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.target = self; table.doubleAction = #selector(showSelected(_:))
        table.setAccessibilityLabel("Terminal panes and their controllers")
        table.setAccessibilityHelp("Select a terminal with the arrow keys. Show Terminal focuses it and its approval request, if one is waiting. Reclaim Control returns input to you without stopping its running process.")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let note = NSTextField(wrappingLabelWithString: "Input control is enforced by AkiTTY. Local requests require human approval; ordinary program operations are observation only. Program reports and shell directories are unverified.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        showButton.target = self; showButton.action = #selector(showSelected(_:))
        reclaimButton.target = self; reclaimButton.action = #selector(reclaimSelected(_:))
        reclaimButton.setAccessibilityHelp("Revokes the selected agent's input control and unused command approval. Does not stop the running process.")
        resumeButton.target = self; resumeButton.action = #selector(resumeSelected(_:))
        resumeButton.setAccessibilityHelp("Starts the selected pane's restored agent conversation by its ID at the pane's idle shell prompt.")
        let buttons = NSStackView(views: [note, showButton, reclaimButton, resumeButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSView()
        for view in [scroll, buttons] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        window.contentView = content
        window.initialFirstResponder = table
        table.nextKeyView = showButton; showButton.nextKeyView = reclaimButton; reclaimButton.nextKeyView = resumeButton; resumeButton.nextKeyView = table
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        window?.makeFirstResponder(table)
        // Cached snapshots are read once a second; each pane's own poll keeps them current.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { guard let self, self.window?.isVisible == true else { return }; self.pollPanes(); self.refresh() }
            }
        }
    }
    override func close() { timer?.invalidate(); timer = nil; super.close() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    /// Asks each pane for a snapshot since its last revision, so hidden windows do not show stale control state.
    private func pollPanes() { source().flatMap(\.panes).forEach { $0.terminal.poll() } }

    func refresh() {
        let selected = table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow].row.sessionID : nil
        let next = source().flatMap { window in
            window.panes.map { Entry(window: window, terminal: $0.terminal, row: AgentOverviewRow(sessionID: $0.terminal.session.id, snapshot: $0.terminal.snapshot, requestsEnabled: requestsEnabled(), pending: pending($0.terminal.session.id), agentSession: agentSession($0.terminal.session.id))) }
        }
        if next.map(\.row.sessionID) != entries.map(\.row.sessionID) {
            entries = next
            table.reloadData()
            table.deselectAll(nil)
            if let selected, let index = entries.firstIndex(where: { $0.row.sessionID == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else if selected != nil, window?.isKeyWindow == true {
                window?.makeFirstResponder(table)
                NSAccessibility.post(element: table, notification: .focusedUIElementChanged)
            }
        } else {
            entries = next
            // Keep row/cell accessibility objects alive during progress and control updates.
            for row in entries.indices {
                for (column, definition) in Self.columns.enumerated() {
                    if let field = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTextField {
                        configure(field, column: definition.id, row: entries[row].row)
                    }
                }
            }
        }
        updateButtons()
    }

    private var selectedEntry: Entry? { table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow] : nil }
    private func updateButtons() {
        showButton.isEnabled = selectedEntry != nil
        reclaimButton.isEnabled = selectedEntry?.row.agentControlled == true
    }
    func select(sessionID: UInt64) {
        guard let index = entries.firstIndex(where: { $0.row.sessionID == sessionID }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        updateButtons()
    }
    @objc func showSelected(_ sender: Any?) {
        guard let entry = selectedEntry, let window = entry.window, let terminal = entry.terminal else { return }
        onShow(window, terminal)
    }
    /// The same human gesture as Edit → Reclaim Terminal Control. It revokes the lease and any grant; the process keeps running.
    /// Resumes the selected pane's restored conversation; the pane is shown so the human sees what starts.
    @objc func resumeSelected(_ sender: Any?) {
        guard let entry = selectedEntry, let window = entry.window, let terminal = entry.terminal else { return }
        do { try resume(terminal); onShow(window, terminal) }
        catch { if let host = self.window { NSAlert(error: error).beginSheetModal(for: host) } }
        refresh()
    }
    @objc func reclaimSelected(_ sender: Any?) {
        guard let entry = selectedEntry, entry.row.agentControlled, let terminal = entry.terminal else { return }
        terminal.reclaimAgentControl(sender)
        refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let field = NSTextField(labelWithString: "")
        configure(field, column: id, row: entries[row].row)
        return field
    }
    private func configure(_ field: NSTextField, column id: String, row item: AgentOverviewRow) {
        let text: String
        switch id {
        case "terminal": text = item.title.isEmpty ? "Terminal \(item.sessionID)" : "\(item.sessionID) · \(item.title)"
        case "control": text = item.controller
        case "program": text = item.programStatus ?? "—"
        case "directory": text = item.shellDirectory ?? "—"
        case "execution": text = item.executionEntry
        case "approvals": text = item.approvals
        case "session": text = item.agentSession
        default: text = item.state
        }
        let changed = field.stringValue != text
        if changed { field.stringValue = text }
        let label = Self.columns.first { $0.id == id }?.title ?? id
        field.setAccessibilityLabel(label + ": " + text)
        field.lineBreakMode = .byTruncatingTail
        field.font = id == "control" && item.agentControlled ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        if id == "program" || id == "directory" { field.textColor = .secondaryLabelColor }
        if changed { NSAccessibility.post(element: field, notification: .valueChanged) }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
