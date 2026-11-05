import XCTest
import AppKit
@testable import AkittyKit

final class PasteTests: XCTestCase {
    private enum Dispatch { case command, keyDown, keyEquivalent }
    @MainActor func testPastePreferenceChangesPreservePaneZoom() throws {
        _ = NSApplication.shared
        let suite = "akitty-paste-zoom-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = TerminalPreferences()
        let terminal = try TerminalView(headless: true, forceSoftware: true, forceShaderFailure: false, initial: settings, defaults: defaults)
        defer { terminal.shutdown() }
        let original = terminal.cellSize
        terminal.changeFont(6)
        let zoomed = terminal.cellSize
        XCTAssertGreaterThan(zoomed.height, original.height)
        settings.confirmPaste = false; try settings.save(to: defaults)
        XCTAssertEqual(terminal.cellSize, zoomed, "saving Don't ask again must not reset pane zoom")
        terminal.changeFont(nil)
        XCTAssertEqual(terminal.cellSize, original)
        settings.fontSize = 24; try settings.save(to: defaults)
        XCTAssertGreaterThan(terminal.cellSize.height, zoomed.height, "an explicit font-size preference still applies")
    }
    @MainActor func testPalettePasteCanPresentConfirmationAfterDismissingThePalette() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { terminal.shutdown(); window.close() }
        let palette = PaletteController { command in
            XCTAssertEqual(command, .paste)
            terminal.paste("first\nsecond")
        }
        let panel = try XCTUnwrap(palette.window)
        window.beginSheet(panel, completionHandler: { _ in })
        let search = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Paste Text"
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertTrue(search.sendAction(try XCTUnwrap(search.action), to: search.target))
        for _ in 0..<200 where window.attachedSheet == nil || window.attachedSheet === panel {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let confirmation = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(confirmation === panel)
        window.endSheet(confirmation, returnCode: .alertFirstButtonReturn)
    }
    @MainActor func testRepeatedPastesDoNotQueueAnotherConfirmation() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { terminal.shutdown(); window.close() }
        var statuses: [String] = []; terminal.onStatus = { statuses.append($0) }
        terminal.paste("first\nline")
        let first = try XCTUnwrap(window.attachedSheet)
        terminal.paste("second\nline")
        XCTAssertTrue(window.attachedSheet === first)
        XCTAssertEqual(window.sheets.count, 1)
        XCTAssertTrue(statuses.contains("Finish the current dialog before pasting."))
        window.endSheet(first, returnCode: .alertFirstButtonReturn)
        for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(window.sheets.isEmpty, "cancel must not reveal a queued paste")
    }
    @MainActor func testPasteDoesNotBypassAnotherDialog() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { terminal.shutdown(); window.close() }
        let other = NSAlert(); other.messageText = "Another action"
        other.beginSheetModal(for: window) { _ in }
        var statuses: [String] = []; terminal.onStatus = { statuses.append($0) }
        terminal.paste("plain")
        terminal.paste("two\nlines")
        XCTAssertEqual(window.sheets.count, 1)
        XCTAssertEqual(statuses, Array(repeating: "Finish the current dialog before pasting.", count: 2))
        window.endSheet(other.window, returnCode: .alertFirstButtonReturn)
        for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(window.sheets.isEmpty)
    }
    @MainActor func testDontAskAgainPersistsOnlyAfterPasteAndCanBeReenabled() async throws {
        _ = NSApplication.shared
        func button(in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == "Don't ask again" { return button }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        for approve in [false, true] {
            let suite = "akitty-paste-choice-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let terminal = try TerminalView(headless: true, forceSoftware: true, forceShaderFailure: false, initial: TerminalPreferences(), defaults: defaults)
            let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = terminal
            defer { terminal.shutdown(); window.close() }
            terminal.paste("first\nline")
            let sheet = try XCTUnwrap(window.attachedSheet)
            try XCTUnwrap(button(in: sheet.contentView)).state = .on
            window.endSheet(sheet, returnCode: approve ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            for _ in 0..<100 where !window.sheets.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(TerminalPreferences.load(from: defaults).confirmPaste, !approve)
            if approve {
                let reloaded = TerminalPreferences.load(from: defaults)
                let next = try TerminalView(headless: true, forceSoftware: true, forceShaderFailure: false, initial: reloaded, defaults: defaults)
                let nextWindow = NSWindow(contentRect: next.frame, styleMask: [.titled], backing: .buffered, defer: false)
                nextWindow.isReleasedWhenClosed = false; nextWindow.contentView = next
                defer { next.shutdown(); nextWindow.close() }
                next.paste("second\nline")
                XCTAssertNil(nextWindow.attachedSheet, "a new terminal uses the saved choice")
                var restored = reloaded; restored.confirmPaste = true; try restored.save(to: defaults)
                next.paste("third\nline")
                nextWindow.endSheet(try XCTUnwrap(nextWindow.attachedSheet), returnCode: .alertFirstButtonReturn)
            }
        }
    }
    @MainActor func testPasteCommandDeliversClipboardTextToAnActualPTY() async throws {
        try await exercisePaste(using: .command)
    }
    @MainActor func testCommandVPastesInsteadOfSendingAnEnhancedKeyboardChord() async throws {
        try await exercisePaste(using: .keyDown)
    }
    @MainActor func testFocusedTerminalHandlesThePasteKeyEquivalent() async throws {
        try await exercisePaste(using: .keyEquivalent)
    }
    @MainActor func testMultilineShortcutPasteWaitsForApproval() async throws {
        try await exercisePaste(using: .keyDown, payload: "first\nsecond")
    }
    @MainActor func testCancelledMultilineShortcutPasteWritesNothing() async throws {
        try await exercisePaste(using: .keyDown, payload: "first\nsecond", approve: false)
    }
    @MainActor func testDisabledConfirmationStillDeliversTheMultilinePayload() async throws {
        try await exercisePaste(using: .keyDown, payload: "first\nsecond", confirmPaste: false)
    }
    @MainActor private func exercisePaste(using dispatch: Dispatch, payload: String = "paste 中文", approve: Bool = true, confirmPaste: Bool = true) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("akitty-paste-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = root.appendingPathComponent("reader")
        try """
        #!/usr/bin/python3
        import os, tty
        tty.setraw(0)
        os.write(1, b'\\x1b[?2004h\\x1b[>31u')
        open('ready', 'w').close()
        data = b''
        while not data.endswith(b'\\x1b[201~'):
            chunk = os.read(0, 65536)
            with open('observed', 'ab') as output:
                output.write(chunk)
            data += chunk
        with open('received', 'wb') as output:
            output.write(data)
        """.write(to: reader, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reader.path)
        var preferences = TerminalPreferences()
        preferences.confirmPaste = confirmPaste
        preferences.shell = reader.path; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let app = AkittyApplication()
        let controller = try TerminalWindow(app: app, headless: true)
        let window = try XCTUnwrap(controller.window)
        let previousMenu = NSApp.mainMenu
        defer {
            terminal.shutdown(); controller.panes.forEach { $0.terminal.shutdown() }; window.close()
            NSApp.mainMenu = previousMenu
        }
        app.makeMenu()
        window.contentView?.addSubview(terminal)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(terminal)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        for _ in 0..<100 where try terminal.session.snapshot()?.bracketed_paste != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try terminal.session.snapshot()?.bracketed_paste, true)
        for _ in 0..<100 where terminal.snapshot?.kitty_flags != 31 {
            terminal.poll()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(terminal.snapshot?.kitty_flags, 31)
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertTrue(controller.active === terminal)
        XCTAssertEqual(try terminal.session.snapshot()?.kitty_flags, 31)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        pasteboard.clearContents(); pasteboard.setString(payload, forType: .string)
        let change = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == change {
                pasteboard.clearContents(); pasteboard.writeObjects(saved)
            }
        }
        if dispatch != .command {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            if dispatch == .keyEquivalent { XCTAssertTrue(terminal.performKeyEquivalent(with: event)) }
            else { terminal.keyDown(with: event) }
        } else {
            app.perform(.paste, in: window, sender: NSMenuItem())
        }
        if payload.contains("\n") && confirmPaste {
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("observed").path))
            window.endSheet(sheet, returnCode: approve ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            if !approve {
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("observed").path))
                return
            }
        }
        let received = root.appendingPathComponent("received")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: received.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("observed")), Data("\u{1b}[200~\(payload)\u{1b}[201~".utf8))
    }
}
