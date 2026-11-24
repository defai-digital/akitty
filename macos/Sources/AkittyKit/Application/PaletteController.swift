import AppKit

/// A borderless panel that can take keyboard focus for the query field but never becomes the main window.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One palette row: the command's symbol and title, with its shortcut aligned to the trailing edge.
@MainActor final class PaletteRow: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let shortcut = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown; icon.contentTintColor = .secondaryLabelColor; icon.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 14); title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .regular); shortcut.textColor = .secondaryLabelColor
        shortcut.alignment = .right; shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setAccessibilityElement(false)
        for view in [icon, title, shortcut] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        textField = title; imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), shortcut.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func show(_ entry: CommandDescriptor) {
        title.stringValue = entry.title; shortcut.stringValue = entry.shortcut
        icon.image = NSImage(systemSymbolName: entry.id.symbolName, accessibilityDescription: nil)
        setAccessibilityLabel(entry.shortcut.isEmpty ? entry.title : "\(entry.title), \(entry.shortcut)")
    }
}

/// The command palette: a floating panel near the top of its terminal window, in the manner of Spotlight. Typing
/// filters the Rust-ranked catalog; Return or a click runs the selection; Escape, clicking elsewhere, or a sheet
/// arriving on the window (an approval request, for example) dismisses it.
@MainActor final class PaletteController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 34
    static let visibleRows = 8
    private let commands: CommandProvider
    let searchField = NSTextField()
    let table = NSTableView()
    let warning = NSTextField(labelWithString: "")
    let emptyState = NSTextField(labelWithString: "No matching commands")
    private(set) var entries: [CommandDescriptor] = []
    private let execute: (NativeCommand) -> Void
    private weak var parentWindow: NSWindow?
    private var sheetObserver: NSObjectProtocol?
    private var tableHeight: NSLayoutConstraint!
    private var dismissed = false
    init(commands: CommandProvider? = nil, execute: @escaping (NativeCommand) -> Void) {
        self.commands = commands ?? CommandProvider()
        self.execute = execute
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Command Palette"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = true; panel.isMovable = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        super.init(window: panel)
        panel.delegate = self
        let workspace = NSWorkspace.shared
        let background: NSView
        let stack = NSStackView()
        if PaneStatusCapsule.usesGlass(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency, increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast) {
            let glass = NSGlassEffectView(); glass.cornerRadius = 16; glass.contentView = stack; background = glass
        } else {
            // Resolves its colours against the panel's appearance, which `present` copies from the terminal window.
            let solid = SolidChromeView(cornerRadius: 16); solid.contain(stack)
            background = solid
        }
        panel.contentView = background

        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        magnifier.contentTintColor = .secondaryLabelColor; magnifier.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        magnifier.setAccessibilityElement(false)
        searchField.placeholderString = "Search commands"; searchField.font = .systemFont(ofSize: 19)
        searchField.isBezeled = false; searchField.drawsBackground = false; searchField.focusRingType = .none
        searchField.delegate = self; searchField.cell?.usesSingleLineMode = true; searchField.lineBreakMode = .byTruncatingTail
        searchField.setAccessibilityLabel("Search commands"); searchField.setAccessibilityIdentifier("palette-query")
        let query = NSStackView(views: [magnifier, searchField]); query.orientation = .horizontal; query.spacing = 10
        query.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.style = .inset; table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight; table.intercellSpacing = .zero; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(runClicked); table.refusesFirstResponder = true
        table.setAccessibilityLabel("Commands"); table.setAccessibilityIdentifier("palette-commands")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        emptyState.textColor = .secondaryLabelColor; emptyState.alignment = .center; emptyState.isHidden = true
        warning.font = .systemFont(ofSize: 11); warning.textColor = .secondaryLabelColor; warning.isHidden = true
        warning.setAccessibilityIdentifier("palette-warning")
        let separator = NSBox(); separator.boxType = .separator

        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0)
        for view in [query, separator, scroll, emptyState, warning] { stack.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            query.heightAnchor.constraint(equalToConstant: 48), query.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), tableHeight,
            emptyState.widthAnchor.constraint(equalTo: stack.widthAnchor), emptyState.heightAnchor.constraint(equalToConstant: 40),
            warning.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18), warning.heightAnchor.constraint(equalToConstant: 18)
        ])
        stack.setCustomSpacing(4, after: separator)
        panel.initialFirstResponder = searchField
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    /// Shows the palette over `parent`: centred, just below its tab row, and attached so it moves with the window.
    func present(over parent: NSWindow) {
        guard let panel = window else { return }
        parentWindow = parent
        panel.appearance = parent.appearance
        resize()
        let frame = parent.frame, height = panel.frame.height
        var origin = NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - 76 - height)
        if let visible = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
        }
    }
    var isPresented: Bool { window?.isVisible == true && !dismissed }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    func refresh() {
        entries = commands.search(searchField.stringValue)
        warning.stringValue = commands.warning ?? ""; warning.isHidden = commands.warning == nil
        emptyState.isHidden = !entries.isEmpty
        table.reloadData()
        if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
        resize()
    }
    /// Grows and shrinks with the matches, keeping the top edge where it was.
    private func resize() {
        guard let panel = window else { return }
        tableHeight.constant = CGFloat(max(entries.isEmpty ? 0 : 1, min(entries.count, Self.visibleRows))) * Self.rowHeight
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(panel.contentView?.fittingSize.height ?? 360)
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
        panel.invalidateShadow()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("palette-row"), owner: nil) as? PaletteRow) ?? {
            let view = PaletteRow(); view.identifier = NSUserInterfaceItemIdentifier("palette-row"); return view
        }()
        if entries.indices.contains(row) { cell.show(entries[row]) }
        return cell
    }
    @objc private func runClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        runSelected()
    }
    func runSelected() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let id = entries[table.selectedRow].id
        dismiss(restoreFocus: true)
        execute(id)
    }
    override func cancelOperation(_ sender: Any?) { dismiss(restoreFocus: true) }
    /// `restoreFocus` returns the keyboard to the terminal window; a click on another window keeps it there.
    func dismiss(restoreFocus: Bool) {
        guard !dismissed else { return }
        dismissed = true
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
        sheetObserver = nil
        guard let panel = window else { return }
        let parent = parentWindow ?? panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus, let parent, parent.isVisible { parent.makeKey() }
    }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !entries.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = (max(0, table.selectedRow) + delta + entries.count) % entries.count
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss(restoreFocus: true); return true
        default:
            return false
        }
    }
}
