import AppKit

/// What a tab's programs report through program chrome, shown in its chip. Several tabs can run agents at once, so
/// the state belongs to each tab rather than to the window.
enum TabActivity: Equatable {
    case none
    /// Progress or the busy mark is current. Pixels are the shown sprite frame, when the program sent a sprite.
    case working(pixels: Data?, width: Int, height: Int)
    /// Work ended while the tab was not in view. Cleared when the tab is shown.
    case finished
    /// The bell rang while the tab was not in view. Cleared when the tab is shown.
    case bell
    case blocked, reportedError, reportedDone
    /// What assistive technology reads for the mark; nil when there is nothing to show.
    var accessibilityName: String? {
        switch self {
        case .none: return nil
        case .working: return "Working"
        case .finished: return "Finished"
        case .bell: return "Bell"
        case .blocked: return "Program reports waiting for you"
        case .reportedError: return "Program reports an error"
        case .reportedDone: return "Program reports completion; result not verified"
        }
    }
}

/// What a tab and the window show for a shell title. Like Ghostty, a bell that rang while the tab was out of view
/// prefixes the title with 🔔 until the tab is shown, so a window in the background says which tab wants attention.
enum TabTitle {
    /// The core's title before a program sets one and after it clears or resets it.
    static let defaultTitle = "Akitty"
    static func label(_ title: String, bell: Bool) -> String { bell ? "🔔 \(title)" : title }
    /// The window names its selected tab, then the app after an em dash unless the tab still has the default title.
    static func window(_ title: String, bell: Bool) -> String {
        let label = label(title, bell: bell)
        return title == defaultTitle ? label : "\(label) — Akitty"
    }
}

/// The chip's activity mark: the program's own sprite while it works, a dot once work it did out of view ends, and a
/// bell when it rang out of view. The bell lives here as well as in the title because the title truncates its head.
@MainActor final class TabActivityMark: NSView {
    var activity: TabActivity = .none {
        didSet {
            guard activity != oldValue else { return }
            image = Self.image(for: activity)
            isHidden = activity == .none
            setAccessibilityLabel(activity.accessibilityName)
            needsDisplay = true
        }
    }
    private var image: NSBitmapImageRep?
    /// Ghostty's bell glyph, in the warning colour so it reads apart from the working and finished dots.
    private static let bellImage = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.systemOrange])))
    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityIdentifier("tab-activity")
    }
    required init?(coder: NSCoder) { nil }
    /// Copies one straight-alpha RGBA8 frame into a bitmap; nil when the size does not match.
    static func bitmap(pixels: Data, width: Int, height: Int) -> NSBitmapImageRep? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: width * 4, bitsPerPixel: 32),
              let destination = rep.bitmapData else { return nil }
        pixels.withUnsafeBytes { raw in
            if let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) { destination.update(from: source, count: pixels.count) }
        }
        return rep
    }
    /// Whole-number enlargement keeps pixel art crisp; any other scale (a detailed sprite on a 1x display) is smoothed.
    nonisolated static func interpolation(edge: Int, devicePixels: CGFloat) -> NSImageInterpolation {
        let ratio = devicePixels / CGFloat(max(1, edge))
        return ratio >= 1 && ratio.rounded() == ratio ? .none : .high
    }
    private static func image(for activity: TabActivity) -> NSBitmapImageRep? {
        guard case let .working(pixels?, width, height) = activity else { return nil }
        return bitmap(pixels: pixels, width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        switch activity {
        case .none: return
        case .finished:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
        case .bell:
            guard let bell = Self.bellImage else { return }
            let size = bell.size
            bell.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .blocked, .reportedError, .reportedDone:
            let name = activity == .blocked ? "pause.circle.fill" : activity == .reportedError ? "exclamationmark.circle.fill" : "checkmark.circle"
            NSImage(systemSymbolName: name, accessibilityDescription: activity.accessibilityName)?.draw(in: bounds)
        case .working:
            guard let image else {
                // A program that reports work without a sprite gets a plain accent dot.
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
                return
            }
            let side = min(bounds.width, bounds.height)
            let edge = max(image.pixelsWide, image.pixelsHigh)
            let scale = side / CGFloat(edge)
            let size = NSSize(width: CGFloat(image.pixelsWide) * scale, height: CGFloat(image.pixelsHigh) * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            let interpolation = Self.interpolation(edge: edge, devicePixels: side * (window?.backingScaleFactor ?? 2))
            NSGraphicsContext.current?.imageInterpolation = interpolation
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: interpolation.rawValue)])
        }
    }
}

/// One tab in the bar, laid out like a native macOS tab (Ghostty's): a close button on the left, the centred title,
/// and the ⌘-number that selects it on the right. The close button shows on the selected tab and on hover; clicking
/// anywhere else selects the tab, and dragging sideways reorders it.
@MainActor final class TabChip: NSView {
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!, target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    let activityMark = TabActivityMark()
    var activity: TabActivity { get { activityMark.activity } set { activityMark.activity = newValue; refresh() } }
    var shortcut: String { get { shortcutLabel.stringValue } set { shortcutLabel.stringValue = newValue } }
    var onSelect: (() -> Void)?, onClose: (() -> Void)?, contextMenu: (() -> NSMenu)?
    /// The pointer's x in the tab strip while this tab is dragged.
    var onDrag: ((CGFloat) -> Void)?
    private var dragStart: CGFloat?, dragging = false
    var label: String { get { title.stringValue } set { title.stringValue = newValue; closeButton.setAccessibilityLabel("Close \(newValue)") } }
    var isSelected = false { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }
    init() {
        super.init(frame: .zero)
        closeButton.isBordered = false; closeButton.imageScaling = .scaleProportionallyDown; closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close tab"; closeButton.setAccessibilityIdentifier("close-terminal-tab")
        closeButton.target = self; closeButton.action = #selector(closeClicked(_:))
        title.font = .systemFont(ofSize: 12); title.alignment = .center
        // Like Ghostty, keep the end of a long title: the deepest directory or the command's arguments.
        title.lineBreakMode = .byTruncatingHead
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.font = .systemFont(ofSize: 11); shortcutLabel.textColor = .tertiaryLabelColor; shortcutLabel.alignment = .right
        shortcutLabel.setAccessibilityElement(false)
        for view in [closeButton, title, activityMark, shortcutLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        // The mark sits just before the ⌘-number; the title keeps clear of it either way, so it does not jump.
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16), closeButton.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4), title.trailingAnchor.constraint(equalTo: activityMark.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28), activityMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityMark.widthAnchor.constraint(equalToConstant: 14), activityMark.heightAnchor.constraint(equalToConstant: 14),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 20)
        ])
        setAccessibilityElement(true); setAccessibilityRole(.radioButton)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func refresh() {
        closeButton.alphaValue = isSelected || hovering ? 1 : 0
        // A narrow tab gives its room to the title first.
        shortcutLabel.isHidden = bounds.width < 120
        title.textColor = isSelected ? .labelColor : .secondaryLabelColor
        let state = activity.accessibilityName.map { ", \($0.lowercased())" } ?? ""
        setAccessibilityLabel(label + state); setAccessibilityValue(isSelected)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovering else { return }
        (isSelected ? NSColor.quaternaryLabelColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func layout() { super.layout(); refresh() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow.x; dragging = false; onSelect?() }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let strip = superview else { return }
        // A few points of slack so a slightly shaky click is still a click.
        if !dragging, abs(event.locationInWindow.x - start) < 4 { return }
        dragging = true
        onDrag?(strip.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil; dragging = false }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    @objc private func closeClicked(_ sender: Any?) { onClose?() }
}

/// A tab menu entry that remembers which tabs it acts on.
final class TabMenuItem: NSMenuItem { var tabs: [NSTabViewItem] = [] }
