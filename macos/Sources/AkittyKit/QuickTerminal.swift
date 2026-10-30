import AppKit
import Carbon

@MainActor final class GlobalShortcut {
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var selected: Int?
    var onPress: (() -> Void)?
    static let names = ["Control–Option–Space", "Control–Option–`", "Command–Option–Return"]
    private static let codes: [UInt32] = [49, 50, 36]
    func configure(enabled: Bool, choice: Int) throws {
        guard Self.codes.indices.contains(choice) else { throw AkittyError.core("Invalid quick terminal shortcut.") }
        guard enabled else { stop(); return }
        if key != nil && selected == choice { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x414b5459 else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                    guard let choice = shortcut.selected, id.id == UInt32(choice + 1) else { return OSStatus(eventNotHandledErr) }
                    shortcut.onPress?(); return noErr
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw AkittyError.core("Could not register the quick terminal event handler (\(status)).") }
        }
        var replacement: EventHotKeyRef?
        let modifiers = UInt32(optionKey) | UInt32(choice == 2 ? cmdKey : controlKey)
        let status = RegisterEventHotKey(Self.codes[choice], modifiers, EventHotKeyID(signature: 0x414b5459, id: UInt32(choice + 1)), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else {
            if key == nil, let handler { RemoveEventHandler(handler); self.handler = nil }
            throw AkittyError.core("Quick terminal shortcut is unavailable or already in use (\(status)). Choose another shortcut.")
        }
        if let key { UnregisterEventHotKey(key) }
        key = replacement; selected = choice
    }
    func stop() {
        if let key { UnregisterEventHotKey(key) }; key = nil; selected = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    deinit {
        if let key { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor final class QuickTerminalController {
    private let shortcut = GlobalShortcut()
    private let makeWindow: () throws -> TerminalWindow
    private(set) var terminalWindow: TerminalWindow?
    private var previousApp: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    var restoreFocus: (() -> Void)?
    var onError: ((Error) -> Void)?
    init(makeWindow: @escaping () throws -> TerminalWindow) {
        self.makeWindow = makeWindow
        shortcut.onPress = { [weak self] in do { try self?.toggle() } catch { self?.onError?(error) } }
    }
    func configure(_ preferences: TerminalPreferences) throws {
        try shortcut.configure(enabled: preferences.quickTerminal, choice: preferences.quickShortcut)
        if !preferences.quickTerminal { hide() }
    }
    func toggle() throws {
        if terminalWindow?.window?.isVisible == true { hide(); return }
        previousApp = NSWorkspace.shared.frontmostApplication; previousWindow = NSApp.keyWindow
        if terminalWindow == nil {
            let controller = try makeWindow()
            controller.quickDismiss = { [weak self] in self?.hide() }
            terminalWindow = controller
        }
        guard let window = terminalWindow?.window else { throw AkittyError.core("Quick terminal window unavailable.") }
        // Join the current Space and coexist with full-screen apps; position on the pointer's display.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.closeButton)?.toolTip = "Hide Quick Terminal (keeps sessions running)"
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrame(NSRect(x: frame.minX + frame.width * 0.1, y: frame.midY, width: frame.width * 0.8, height: frame.height * 0.5), display: true)
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        if let terminal = terminalWindow?.active { window.makeFirstResponder(terminal); terminal.poll() }
    }
    func hide() {
        guard let window = terminalWindow?.window, window.isVisible else { return }
        window.orderOut(nil)
        if let restoreFocus { restoreFocus() }
        else if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousWindow?.makeKeyAndOrderFront(nil) }
        else { previousApp?.activate(options: []) }
        previousApp = nil; previousWindow = nil
    }
    func closed(_ controller: TerminalWindow) { if terminalWindow === controller { terminalWindow = nil } }
    func stop() { shortcut.stop() }
}
