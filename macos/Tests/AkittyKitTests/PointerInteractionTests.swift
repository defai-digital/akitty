import AppKit
import XCTest
@testable import AkittyKit

final class PointerInteractionTests: XCTestCase {
    @MainActor private func wait(_ terminal: TerminalView, until predicate: (Snapshot) -> Bool) async throws {
        for _ in 0..<150 {
            terminal.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
            if let snapshot = terminal.snapshot, predicate(snapshot) { return }
        }
        XCTFail("terminal snapshot did not update")
    }
    @MainActor func testMultipleClicksSelectWordsLinesAndWideCombiningText() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        defer { terminal.shutdown(); window.close() }
        _ = try terminal.session.call("feed", ["text": "ALPHA BRAVO CHARLIE\r\n中e\u{301} next"])
        try await wait(terminal) { $0.text.contains("BRAVO") }
        func click(row: Int, col: Int, count: Int, flags: NSEvent.ModifierFlags = []) throws {
            let point = terminal.convert(NSPoint(x: 8 + (CGFloat(col) + 0.5) * terminal.cellSize.width,
                                                y: 8 + (CGFloat(row) + 0.5) * terminal.cellSize.height), to: nil)
            terminal.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)))
        }
        try click(row: 0, col: 8, count: 2)
        XCTAssertEqual(terminal.accessibilitySelectedText(), "BRAVO")
        try click(row: 0, col: 8, count: 3)
        XCTAssertEqual(terminal.accessibilitySelectedText()?.trimmingCharacters(in: .whitespaces), "ALPHA BRAVO CHARLIE")
        try click(row: 1, col: 1, count: 2)
        XCTAssertEqual(terminal.accessibilitySelectedText(), "中e\u{301}")
        _ = try terminal.session.call("feed", ["text": "\u{1b}[?1000h"])
        try await wait(terminal) { $0.mouse_mode }
        try click(row: 0, col: 8, count: 1, flags: .option)
        XCTAssertEqual(terminal.accessibilitySelectedText(), "")
        try click(row: 0, col: 8, count: 2)
        XCTAssertEqual(terminal.accessibilitySelectedText(), "", "program mouse reporting owns the click")
        try click(row: 0, col: 8, count: 2, flags: .option)
        XCTAssertEqual(terminal.accessibilitySelectedText(), "BRAVO")
    }
    @MainActor func testDisabledAlternateScrollDoesNotAttemptPTYInput() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        terminal.playAlertSound = {}
        var errors: [String] = []
        terminal.onStatus = { if $0.contains("no PTY") { errors.append($0) } }
        _ = try terminal.session.call("feed", ["text": "\u{1b}[?1049h\u{1b}[?1007l"])
        try await wait(terminal) { $0.alternate && $0.alternate_scroll == false }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
        terminal.scrollWheel(with: wheel)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(errors.isEmpty, "mode 1007 off must leave input untouched")
        _ = try terminal.session.call("feed", ["text": "\u{1b}[?1007h"])
        try await wait(terminal) { $0.alternate_scroll == true }
        terminal.scrollWheel(with: wheel)
        for _ in 0..<100 where errors.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(errors.isEmpty, "mode 1007 on must attempt to send cursor keys")
    }
}
