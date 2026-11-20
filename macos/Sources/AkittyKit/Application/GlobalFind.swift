import AppKit

enum GlobalFindScope { case window, all }

/// One listed hit. Identity is the session plus the row id and the generation of its cells,
/// so a tab can move between windows before the result is opened. A row that leaves
/// scrollback, or is reset and reprinted, no longer matches.
struct GlobalFindHit: Equatable {
    let sessionID: UInt64
    let rowID: UInt64
    let generation: UInt64
    let col: Int
    let endCol: Int
    let query: String
    let snippet: String
    let windowID: ObjectIdentifier
    let tabID: ObjectIdentifier
    let windowTitle: String
    let tabTitle: String
    let paneTitle: String
    let folder: String?
}

/// Find in All Terminals. Command-F stays on one pane; this panel lists retained output
/// from the open panes in one window or in every window.
@MainActor final class GlobalFindController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static let perPaneLimit = 32
    private static let totalLimit = 100
    private let debounce: TimeInterval = 0.15
    private weak var app: AkittyApplication?
    weak var anchor: TerminalWindow?
    var scope: GlobalFindScope = .all { didSet { scopeControl.selectedSegment = scope == .window ? 0 : 1 } }
    private(set) var hits: [GlobalFindHit] = []
    private(set) var statusText = ""
    private var listStatus = ""
    private var actionStatus = ""
    private var generation = 0
    /// Token of the results on screen. Return ignores a selection from an older query.
    private var shownToken = 0
    private enum DisplayRow { case header(String), hit(GlobalFindHit) }
    private var rows: [DisplayRow] = []
    private let scopeControl = NSSegmentedControl(labels: ["This Window", "All Terminals"], trackingMode: .selectOne, target: nil, action: nil)
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")

    var rowDescriptions: [String] {
        rows.map {
            switch $0 {
            case .header(let text): return "header:\(text)"
            case .hit(let hit): return "hit:\(hit.snippet)"
            }
        }
    }

    init(app: AkittyApplication) {
        self.app = app
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Find in All Terminals"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 280)
        super.init(window: panel)
        let content = NSView()
        panel.contentView = content
        scopeControl.selectedSegment = 1
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.setAccessibilityIdentifier("global-find-scope")
        field.placeholderString = "Find in open terminals"
        field.delegate = self
        field.setAccessibilityLabel("Find in open terminals")
        field.setAccessibilityIdentifier("global-find-query")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.width = 640
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityIdentifier("global-find-results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("global-find-status")
        for view in [scopeControl, field, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scopeControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scopeControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.heightAnchor.constraint(equalToConstant: 16),
        ])
        panel.initialFirstResponder = field
    }
    required init?(coder: NSCoder) { nil }

    func show(anchor: TerminalWindow?) {
        self.anchor = anchor
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        beginSearch(stepped: true)
    }

    /// Synchronous search used by tests.
    func searchNow(_ query: String) {
        if field.stringValue != query { field.stringValue = query }
        beginSearch(stepped: false)
    }

    private func beginSearch(stepped: Bool) {
        generation += 1
        run(field.stringValue, token: generation, stepped: stepped)
    }

    func controlTextDidChange(_ obj: Notification) { schedule() }

    /// Return opens the selected hit. A new keystroke cancels a search that is still walking panes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { window?.orderOut(nil); return true }
        if selector == #selector(moveDown(_:)) || selector == #selector(moveUp(_:)) {
            moveSelection(selector == #selector(moveDown(_:)) ? 1 : -1)
            return true
        }
        return false
    }

    @discardableResult func activate(_ hit: GlobalFindHit) -> String {
        guard let target = locate(hit.sessionID) else { return fail("This pane is closed.") }
        do {
            let data = try target.terminal.session.call("find_reveal", [
                "text": hit.query, "row_id": NSNumber(value: hit.rowID), "generation": NSNumber(value: hit.generation),
                "col": hit.col, "end_col": hit.endCol,
            ])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["expired"] as? Bool == true || object?["found"] as? Bool != true {
                return fail("This match is no longer in the pane's scrollback.")
            }
        } catch { return fail("This pane is closed.") }
        for other in app?.windows.flatMap(\.panes) ?? [] where other.terminal.session.id != hit.sessionID {
            _ = try? other.terminal.session.call("find", ["clear": true])
            other.terminal.poll()
        }
        target.terminal.poll()
        app?.revealTerminal(target.terminal)
        actionStatus = ""
        publish()
        return ""
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .hit = rows[row] { return true }
        return false
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 18 }
        return 36
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setAccessibilityIdentifier("global-find-header")
            return label
        case .hit(let hit):
            let place = [hit.paneTitle, hit.folder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let label = NSTextField(wrappingLabelWithString: "\(place)\n\(hit.snippet)")
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityIdentifier("global-find-hit")
            label.setAccessibilityLabel("\(hit.windowTitle), \(hit.tabTitle), \(place), \(hit.snippet)")
            return label
        }
    }

    @objc private func scopeChanged() {
        scope = scopeControl.selectedSegment == 0 ? .window : .all
        beginSearch(stepped: true)
    }
    @objc private func openSelected() {
        guard generation == shownToken, rows.indices.contains(table.selectedRow), case .hit(let hit) = rows[table.selectedRow] else { return }
        _ = activate(hit)
    }
    private func schedule() {
        generation += 1
        let token = generation
        let query = field.stringValue
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, self.generation == token else { return }
            self.run(query, token: token, stepped: true)
        }
    }
    private func run(_ query: String, token: Int, stepped: Bool) {
        guard generation == token, let app else { return }
        actionStatus = ""
        if scope == .window && (anchor == nil || !app.windows.contains(where: { $0 === anchor })) {
            apply(token, hits: [], capped: false, query: query, closedWindow: true)
            return
        }
        if query.isEmpty {
            apply(token, hits: [], capped: false, query: query, closedWindow: false)
            return
        }
        if stepped { status.stringValue = "Searching…"; statusText = "Searching…" }
        // One chunk per turn while typing. Each call reads at most 256 rows and then releases
        // that pane's model lock, so a busy terminal's output and the field stay responsive.
        walk(query, token: token, panes: targets(), index: 0, found: [], capped: false, stepped: stepped)
    }
    private func walk(_ query: String, token: Int, panes: [Target], index: Int, found: [GlobalFindHit], capped: Bool, stepped: Bool) {
        guard generation == token else { return }
        if index >= panes.count || (found.count == Self.totalLimit && capped) {
            apply(token, hits: found, capped: capped, query: query, closedWindow: false)
            return
        }
        let room = min(Self.perPaneLimit, Self.totalLimit - found.count)
        scan(panes[index], query: query, limit: room, token: token, before: nil, found: [], stepped: stepped) { [weak self] hits, paneCapped in
            guard let self, self.generation == token else { return }
            var found = found
            found.append(contentsOf: hits.prefix(room))
            self.continueWalk(query, token: token, panes: panes, index: index + 1, found: found, capped: capped || paneCapped, stepped: stepped)
        }
    }
    private func continueWalk(_ query: String, token: Int, panes: [Target], index: Int, found: [GlobalFindHit], capped: Bool, stepped: Bool) {
        guard generation == token else { return }
        if stepped {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.walk(query, token: token, panes: panes, index: index, found: found, capped: capped, stepped: stepped)
            }
        } else {
            walk(query, token: token, panes: panes, index: index, found: found, capped: capped, stepped: stepped)
        }
    }
    /// Reads one pane from the bottom, 256 rows at a time. A full page is capped only after a later hit is seen.
    /// Typing yields between chunks. A synchronous search stays in this loop so a long scrollback cannot grow the stack.
    private func scan(_ target: Target, query: String, limit: Int, token: Int, before: ScanCursor?, found: [GlobalFindHit], stepped: Bool, done: @escaping ([GlobalFindHit], Bool) -> Void) {
        guard generation == token else { return }
        var before = before
        var found = found
        while generation == token {
            let room = limit - found.count
            let nextCursor: ScanCursor?
            if room <= 0 {
                // A full list still needs evidence of an omitted hit, even in a pane not yet scanned.
                let probe = chunk(target, query: query, limit: 1, before: before)
                if !probe.hits.isEmpty || probe.capped { done(found, true); return }
                guard let next = probe.next, before != .some(next) else { done(found, false); return }
                nextCursor = next
            } else {
                let page = chunk(target, query: query, limit: room, before: before)
                found.append(contentsOf: page.hits.prefix(room))
                if page.capped { done(found, true); return }
                guard let next = page.next, before != .some(next) else { done(found, false); return }
                nextCursor = next
            }
            if stepped {
                let resumeBefore = nextCursor
                let resumeFound = found
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.scan(target, query: query, limit: limit, token: token, before: resumeBefore, found: resumeFound, stepped: true, done: done)
                }
                return
            }
            before = nextCursor
        }
    }
    private func apply(_ token: Int, hits: [GlobalFindHit], capped: Bool, query: String, closedWindow: Bool) {
        guard generation == token else { return }
        shownToken = token
        self.hits = hits
        listStatus = Self.message(count: hits.count, capped: capped, query: query, closedWindow: closedWindow)
        var shown: [DisplayRow] = []
        var windowID: ObjectIdentifier?
        var tabID: ObjectIdentifier?
        for hit in hits {
            if windowID != hit.windowID {
                shown.append(.header(hit.windowTitle))
                windowID = hit.windowID
                tabID = nil
            }
            if tabID != hit.tabID {
                shown.append(.header(hit.tabTitle))
                tabID = hit.tabID
            }
            shown.append(.hit(hit))
        }
        rows = shown
        publish()
        if let first = rows.firstIndex(where: { if case .hit = $0 { return true }; return false }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
    }
    private func publish() {
        statusText = actionStatus.isEmpty ? listStatus : actionStatus
        status.stringValue = statusText
        table.reloadData()
    }
    private func fail(_ message: String) -> String {
        actionStatus = message
        publish()
        return message
    }
    private static func message(count: Int, capped: Bool, query: String, closedWindow: Bool) -> String {
        if closedWindow { return "This window is closed." }
        if query.isEmpty { return "" }
        if count == 0 { return "No matches" }
        let noun = count == 1 ? "match" : "matches"
        if capped { return "Showing \(count) \(noun). More matches were not listed." }
        return "\(count) \(noun)"
    }
    private func moveSelection(_ delta: Int) {
        let selectable = rows.indices.filter { if case .hit = rows[$0] { return true }; return false }
        guard !selectable.isEmpty else { return }
        let current = selectable.firstIndex(of: table.selectedRow) ?? (delta > 0 ? -1 : 0)
        let next = selectable[(current + delta + selectable.count) % selectable.count]
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
    private func locate(_ sessionID: UInt64) -> Target? {
        guard let app else { return nil }
        for window in app.windows {
            for item in window.tabs.tabViewItems {
                let panes = (item.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? []
                if let pane = panes.first(where: { $0.terminal.session.id == sessionID && !$0.terminal.isShutdown }) {
                    return Target(window: window, tab: item, terminal: pane.terminal)
                }
            }
        }
        return nil
    }
    private func targets() -> [Target] {
        guard let app else { return [] }
        let windows: [TerminalWindow]
        switch scope {
        case .window:
            guard let anchor, app.windows.contains(where: { $0 === anchor }) else { return [] }
            windows = [anchor]
        case .all:
            var ordered = app.windows
            if let anchor, let index = ordered.firstIndex(where: { $0 === anchor }) {
                ordered.insert(ordered.remove(at: index), at: 0)
            }
            windows = ordered
        }
        var found: [Target] = []
        for window in windows {
            var items = Array(window.tabs.tabViewItems)
            if let selected = window.tabs.selectedTabViewItem, let index = items.firstIndex(where: { $0 === selected }) {
                items.insert(items.remove(at: index), at: 0)
            }
            for item in items {
                var panes = (item.view as? NSSplitView)?.arrangedSubviews.compactMap { $0 as? TerminalPane } ?? []
                if item === window.tabs.selectedTabViewItem, let active = window.active, let index = panes.firstIndex(where: { $0.terminal === active }) {
                    panes.insert(panes.remove(at: index), at: 0)
                }
                for pane in panes where !pane.terminal.isShutdown {
                    found.append(Target(window: window, tab: item, terminal: pane.terminal))
                }
            }
        }
        return found
    }
    private func chunk(_ target: Target, query: String, limit: Int, before: ScanCursor?) -> (hits: [GlobalFindHit], capped: Bool, next: ScanCursor?) {
        var args: [String: Any] = ["text": query, "limit": limit, "max_lines": 256]
        if let before {
            args["before_row_id"] = NSNumber(value: before.rowID)
            args["before_generation"] = NSNumber(value: before.generation)
        }
        guard let data = try? target.terminal.session.call("find_matches", args),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = object["matches"] as? [[String: Any]] else { return ([], false, nil) }
        if object["lost"] as? Bool == true { return ([], false, nil) }
        let state = matches.isEmpty ? nil : (try? target.terminal.session.shellState())
        let paneTitle = state?.title.flatMap { $0.isEmpty ? nil : $0 } ?? target.tab.label
        let folder = state?.shell?.cwd.flatMap { $0.isEmpty ? nil : $0 }
        var hits: [GlobalFindHit] = []
        for match in matches {
            guard let rowID = (match["row_id"] as? NSNumber)?.uint64Value,
                  let generation = (match["generation"] as? NSNumber)?.uint64Value,
                  let col = (match["col"] as? NSNumber)?.intValue, let endCol = (match["end_col"] as? NSNumber)?.intValue,
                  let snippet = match["snippet"] as? String else { continue }
            hits.append(GlobalFindHit(
                sessionID: target.terminal.session.id, rowID: rowID, generation: generation, col: col, endCol: endCol,
                query: query, snippet: snippet,
                windowID: ObjectIdentifier(target.window), tabID: ObjectIdentifier(target.tab),
                windowTitle: target.window.window?.title ?? "Akitty", tabTitle: target.tab.label,
                paneTitle: paneTitle, folder: folder
            ))
        }
        let next: ScanCursor?
        if let rowID = (object["next_row_id"] as? NSNumber)?.uint64Value,
           let generation = (object["next_generation"] as? NSNumber)?.uint64Value {
            next = ScanCursor(rowID: rowID, generation: generation)
        } else {
            next = nil
        }
        return (hits, object["capped"] as? Bool ?? false, next)
    }
}

private struct ScanCursor: Equatable {
    let rowID: UInt64
    let generation: UInt64
}

private struct Target {
    let window: TerminalWindow
    let tab: NSTabViewItem
    let terminal: TerminalView
}
