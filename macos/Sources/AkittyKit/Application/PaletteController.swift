import AppKit

@MainActor final class PaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let features = FeatureHost()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let warning = NSTextField(labelWithString: "")
    private var entries: [CommandDescriptor] = []
    private let execute: (NativeCommand) -> Void
    init(execute: @escaping (NativeCommand) -> Void) {
        self.execute = execute
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 520,height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Command Palette"
        super.init(window: panel)
        let content = NSView(); panel.contentView = content
        search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false
        search.placeholderString = "Search commands…"; search.delegate = self; search.target = self; search.action = #selector(runSelected)
        search.setAccessibilityLabel("Search commands")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")); column.width = 480; table.addTableColumn(column)
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.target = self; table.doubleAction = #selector(runSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        warning.font = .systemFont(ofSize: 11); warning.textColor = .secondaryLabelColor
        for view in [search, scroll, warning] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor,constant: 16), search.leadingAnchor.constraint(equalTo: content.leadingAnchor,constant: 16),search.trailingAnchor.constraint(equalTo: content.trailingAnchor,constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor,constant: 12),scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),scroll.bottomAnchor.constraint(equalTo: warning.topAnchor,constant: -8),
            warning.leadingAnchor.constraint(equalTo: search.leadingAnchor),warning.trailingAnchor.constraint(equalTo: search.trailingAnchor),warning.bottomAnchor.constraint(equalTo: content.bottomAnchor,constant: -12),warning.heightAnchor.constraint(equalToConstant: 18)
        ])
        refresh(); panel.initialFirstResponder = search
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() { entries = features.search(search.stringValue); warning.stringValue = features.warning ?? "TypeScript command ranking · native Mac actions"; table.reloadData(); if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) } }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "\(entries[row].title)     \(entries[row].shortcut)"); label.font = .systemFont(ofSize: 14); return label
    }
    @objc private func runSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let id = entries[table.selectedRow].id
        dismiss(); execute(id)
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    private func dismiss() { if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) } }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(moveDown(_:)) || selector == #selector(moveUp(_:)) {
            let delta = selector == #selector(moveDown(_:)) ? 1 : -1
            if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: (max(0,table.selectedRow)+delta+entries.count)%entries.count), byExtendingSelection: false) }; return true
        }
        if selector == #selector(cancelOperation(_:)) { dismiss(); return true }
        return false
    }
}
