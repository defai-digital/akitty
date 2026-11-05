import XCTest
import AppKit
@testable import AkittyKit

final class PasteTests: XCTestCase {
    private enum Dispatch { case command, keyDown, keyEquivalent }
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
    @MainActor private func exercisePaste(using dispatch: Dispatch, payload: String = "paste 中文", approve: Bool = true) async throws {
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
        if payload.contains("\n") {
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
