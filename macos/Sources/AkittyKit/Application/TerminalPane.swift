import AppKit

/// One pane's status message and the source that decides how it is shown. Program reports and host state stay
/// apart: only the core's control record produces `.agent`, so a program cannot paint itself as the host.
struct PaneStatus: Equatable {
    enum Kind: Equatable {
        /// Nothing to report beyond the grid size. Shown briefly only when the size changes.
        case geometry
        /// Status a program in the pane reported. Untrusted text, never styled like host state.
        case program
        /// An agent holds the host's input lease for this pane.
        case agent
        /// A core error, renderer fallback or shell exit. Stays while the state lasts.
        case problem
        /// A short note about the user's own action, such as a paste or a copy.
        case notice
        /// An operation the user asked for failed.
        case failure
    }
    let text: String
    let kind: Kind
    /// The shorter text the capsule shows; `text` is the complete message.
    let display: String
    init(text: String, kind: Kind, display: String? = nil) {
        self.text = text; self.kind = kind; self.display = display ?? text
    }
    /// Host-owned states outrank a short note and are never faded or click-through.
    var isHostState: Bool { kind == .agent || kind == .problem }
}

/// What a pane's status capsule shows over time. Snapshot-derived states replace each other; notes and failures are
/// held for a few seconds so the next frame cannot erase them before they are read. Pure value logic, so tests can
/// drive the clock.
struct PaneStatusSchedule {
    static let noticeDuration: TimeInterval = 4
    static let failureDuration: TimeInterval = 6
    static let geometryDuration: TimeInterval = 1.2
    private(set) var steady: PaneStatus?
    private(set) var held: PaneStatus?
    private var heldUntil: TimeInterval = 0
    private var geometryUntil: TimeInterval = 0
    private var lastGeometry: String?
    mutating func receive(_ status: PaneStatus, now: TimeInterval) {
        switch status.kind {
        case .notice, .failure:
            held = status
            heldUntil = now + (status.kind == .failure ? Self.failureDuration : Self.noticeDuration)
        case .geometry, .program, .agent, .problem:
            if status.kind == .geometry {
                // The first size is the pane opening, not a change the user made.
                if let lastGeometry, lastGeometry != status.text { geometryUntil = now + Self.geometryDuration }
                lastGeometry = status.text
            }
            if status.isHostState { held = nil }
            steady = status
        }
    }
    /// The status to show (nil hides the capsule) and the text its label holds either way.
    func current(at now: TimeInterval) -> (shown: PaneStatus?, label: String) {
        // An agent's lease or a problem stays on screen with its Reclaim button; a note never covers it.
        if let steady, steady.isHostState { return (steady, steady.display) }
        if let held, now < heldUntil { return (held, held.display) }
        guard let steady else { return (nil, "") }
        if steady.kind == .geometry { return (now < geometryUntil ? steady : nil, steady.display) }
        return (steady, steady.display)
    }
    /// When the shown status next changes without new input, if it will.
    func nextChange(after now: TimeInterval) -> TimeInterval? {
        if steady?.isHostState == true { return nil }
        return [held == nil ? 0 : heldUntil, steady?.kind == .geometry ? geometryUntil : 0].filter { $0 > now }.min()
    }
}

/// A small glass capsule at the pane's top-right corner. It floats over the terminal instead of taking a row from
/// it, so a status appearing or clearing never resizes the PTY. Program reports and notes are click-through and
/// fade while the pointer is over them, so the text beneath stays reachable; host state keeps its tint and stays
/// put, and an agent's input lease offers Reclaim directly.
@MainActor final class PaneStatusCapsule: NSView {
    let label = NSTextField(labelWithString: "")
    let reclaimButton = NSButton(title: "Reclaim", target: nil, action: #selector(TerminalView.reclaimAgentControl(_:)))
    private let glass = NSGlassEffectView()
    /// Replaces the glass when Reduce Transparency or Increase Contrast is on, so text never shows through.
    private let solid = SolidChromeView(cornerRadius: 12)
    private let stack = NSStackView()
    private let icon = NSImageView()
    private(set) var shown: PaneStatus?
    private var hovering = false { didSet { if hovering != oldValue { updateOpacity(animated: true) } } }
    init() {
        super.init(frame: .zero)
        isHidden = true
        label.font = .systemFont(ofSize: 11, weight: .medium); label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("pane-status")
        reclaimButton.controlSize = .small; reclaimButton.bezelStyle = .push; reclaimButton.isHidden = true
        reclaimButton.toolTip = "Return keyboard input to you. The running process keeps running."
        reclaimButton.setAccessibilityLabel("Reclaim terminal control"); reclaimButton.setAccessibilityIdentifier("pane-status-reclaim")
        icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
        for view in [icon, label, reclaimButton] { stack.addArrangedSubview(view) }
        stack.orientation = .horizontal; stack.spacing = 5; stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        glass.cornerRadius = 12
        for view in [glass, solid] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 13), icon.heightAnchor.constraint(equalToConstant: 13)])
        setAccessibilityElement(false)
    }
    /// Glass normally; an opaque capsule when the person asked for less transparency or more contrast.
    nonisolated static func usesGlass(reduceTransparency: Bool, increaseContrast: Bool) -> Bool { !reduceTransparency && !increaseContrast }
    private(set) var glassBacked = true
    private var backgroundChosen = false
    /// Moves the content only when the background kind changes, so a status update never pulls keyboard or
    /// VoiceOver focus off the Reclaim button; tint changes are applied in place.
    private func chooseBackground(tint: NSColor?) {
        let workspace = NSWorkspace.shared
        let glassy = Self.usesGlass(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency, increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        if !backgroundChosen || glassy != glassBacked {
            backgroundChosen = true; glassBacked = glassy
            stack.removeFromSuperview(); glass.contentView = nil
            if glassy { glass.contentView = stack }
            else { solid.contain(stack) }
            glass.isHidden = !glassy; solid.isHidden = glassy
        }
        if glassy { glass.tintColor = tint?.withAlphaComponent(0.28) } else { solid.border = tint ?? .separatorColor }
    }
    required init?(coder: NSCoder) { nil }
    /// `label` keeps the latest text even while hidden, as the old status line did.
    func show(_ status: PaneStatus?, label text: String, reclaimTarget: AnyObject?) {
        label.stringValue = text
        shown = status
        guard let status, !status.display.isEmpty else { isHidden = true; hovering = false; return }
        let symbol: String?, tint: NSColor?
        switch status.kind {
        case .agent: symbol = "hand.raised.fill"; tint = .systemOrange
        case .problem, .failure: symbol = "exclamationmark.triangle.fill"; tint = .systemRed
        case .geometry, .program, .notice: symbol = nil; tint = nil
        }
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = tint; icon.isHidden = symbol == nil
        chooseBackground(tint: tint)
        label.textColor = tint == nil && glassBacked ? .secondaryLabelColor : .labelColor
        // Say where the text came from, as Agent Overview does: a program's report is not the host's word.
        label.setAccessibilityLabel(Self.spokenSource(status.kind) + status.display)
        label.font = status.kind == .geometry ? .monospacedDigitSystemFont(ofSize: 11, weight: .medium) : .systemFont(ofSize: 11, weight: .medium)
        reclaimButton.isHidden = status.kind != .agent
        reclaimButton.target = status.kind == .agent ? reclaimTarget : nil
        isHidden = false
        updateOpacity(animated: false)
    }
    nonisolated static func spokenSource(_ kind: PaneStatus.Kind) -> String {
        switch kind {
        case .program: return "Program reports, unverified: "
        case .agent, .problem: return "AkiTTY: "
        case .geometry, .notice, .failure: return ""
        }
    }
    /// Only host state takes clicks; everything else lets the terminal underneath keep its mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { shown?.isHostState == true ? super.hitTest(point) : nil }
    private var fades: Bool { !(shown?.isHostState ?? true) && shown?.kind != .failure }
    private func updateOpacity(animated: Bool) {
        let alpha: CGFloat = hovering && fades ? 0.08 : 1
        guard alphaValue != alpha else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; animator().alphaValue = alpha }
        } else { alphaValue = alpha }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// Shows which pane has keyboard focus in a tab with more than one pane: the focused pane gets a thin accent
/// outline and the others a light veil of their own background. Click-through, so a click on a dimmed pane still
/// reaches it. Increase Contrast drops the veil, which would lower text contrast, and strengthens the outline.
@MainActor final class PaneFocusVeil: NSView {
    enum State: Equatable { case plain, focused, dimmed }
    /// The terminal's background, so a dimmed pane fades towards its own colours rather than towards grey.
    var color: NSColor = .black { didSet { if color != oldValue { updateLayer(for: state) } } }
    private(set) var state = State.plain
    var dimmed: Bool { state == .dimmed }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; setAccessibilityElement(false); setAccessibilityIdentifier("pane-focus-veil")
        updateLayer(for: .plain)
    }
    required init?(coder: NSCoder) { nil }
    nonisolated static func veilOpacity(increaseContrast: Bool) -> CGFloat { increaseContrast ? 0 : 0.2 }
    nonisolated static func outlineOpacity(increaseContrast: Bool) -> CGFloat { increaseContrast ? 0.9 : 0.5 }
    private func updateLayer(for state: State) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = state == .dimmed ? color.withAlphaComponent(Self.veilOpacity(increaseContrast: contrast)).cgColor : nil
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(Self.outlineOpacity(increaseContrast: contrast)).cgColor
        }
        layer?.borderWidth = state == .focused ? (contrast ? 2 : 1) : 0
    }
    func setState(_ value: State, animated: Bool) {
        guard value != state else { return }
        state = value
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12; context.allowsImplicitAnimation = true
                updateLayer(for: value)
            }
        } else {
            CATransaction.begin(); CATransaction.setDisableActions(true); updateLayer(for: value); CATransaction.commit()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class TerminalPane: NSView {
    private var terminalStorage: TerminalView?
    var terminal: TerminalView { terminalStorage! }
    let capsule = PaneStatusCapsule()
    let veil = PaneFocusVeil()
    /// The latest status text, kept even while the capsule is hidden.
    var status: NSTextField { capsule.label }
    /// Directory passed at creation. Nil means the Settings directory.
    let launchDirectory: String?
    private var schedule = PaneStatusSchedule()
    private var statusTimer: Timer?
    /// Tests replace the clock to step through held and transient states.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    init(headless: Bool = false, directory: String? = nil, profile: UUID? = nil, restoredText: String? = nil) throws {
        launchDirectory = directory
        super.init(frame: .zero)
        terminalStorage = try TerminalView(headless: headless, directory: directory, profile: profile, restoredText: restoredText)
        for view in [terminal, veil, capsule] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        let capsuleWidth = capsule.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor), terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor), terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            veil.topAnchor.constraint(equalTo: topAnchor), veil.leadingAnchor.constraint(equalTo: leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: trailingAnchor), veil.bottomAnchor.constraint(equalTo: bottomAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: 6), capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            capsule.heightAnchor.constraint(equalToConstant: 24), capsuleWidth
        ])
        terminal.onPaneStatus = { [weak self] status in self?.receive(status) }
    }
    required init?(coder: NSCoder) { nil }
    /// A pane leaving its window (closed, or between windows while its tab moves) drops its wake-up; arriving shows
    /// whatever is current.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { statusTimer?.invalidate(); statusTimer = nil } else { renderStatus() }
    }
    func receive(_ status: PaneStatus) {
        schedule.receive(status, now: clock())
        renderStatus()
    }
    /// Shows what the schedule says now and wakes once when that will change on its own.
    func renderStatus() {
        let now = clock(), current = schedule.current(at: now)
        capsule.show(current.shown, label: current.label, reclaimTarget: terminal)
        statusTimer?.invalidate(); statusTimer = nil
        guard let next = schedule.nextChange(after: now) else { return }
        let timer = Timer(timeInterval: max(0.05, next - now), repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.renderStatus() } }
        RunLoop.main.add(timer, forMode: .common); statusTimer = timer
    }
    /// The veil follows the pane's own theme background; `recolour` re-reads it after a theme change.
    func setFocusState(_ value: PaneFocusVeil.State, animated: Bool = true, recolour: Bool = false) {
        if recolour || value != veil.state { veil.color = NSColor(cgColor: terminal.renderAppearance.backgroundColor) ?? .black }
        veil.setState(value, animated: animated)
    }
}

/// An opaque rounded background for chrome shown with Reduce Transparency or Increase Contrast. It resolves its
/// colours in `updateLayer`, so they follow the view's own appearance (which may differ from the app's) and change
/// with it.
@MainActor final class SolidChromeView: NSView {
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var border: NSColor = .separatorColor { didSet { needsDisplay = true } }
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = cornerRadius; layer?.masksToBounds = true; layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
    }
    /// Pins `content` to all four edges.
    func contain(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
