import XCTest
import AppKit
@testable import AkittyKit

/// Manual qualification: sleep the Mac, wake it, and confirm the same session resumes input/output and rendering.
final class SleepWakeTests: XCTestCase {
    @MainActor func testManualSystemSleepWakePreservesSession() async throws {
        guard ProcessInfo.processInfo.environment["AKITTY_SLEEP_WAKE_MANUAL"] == "1" else {
            throw XCTSkip("set AKITTY_SLEEP_WAKE_MANUAL=1 and manually sleep/wake the Mac within 15 minutes")
        }
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: false, forceSoftware: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { terminal.shutdown(); window.close() }
        terminal.send("printf 'BEFORE_SLEEP\\n'\r")
        let beforeDeadline = Date().addingTimeInterval(10)
        while terminal.snapshot?.text.contains("BEFORE_SLEEP") != true, Date() < beforeDeadline {
            terminal.poll(); try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(terminal.snapshot?.text.contains("BEFORE_SLEEP") == true)
        let rendererWasHealthy = !terminal.health.usesSoftware

        let slept = expectation(description: "system slept")
        let woke = expectation(description: "system woke")
        let center = NSWorkspace.shared.notificationCenter
        var observers: [NSObjectProtocol] = []
        defer { observers.forEach { center.removeObserver($0) } }
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in slept.fulfill() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in woke.fulfill() })
        await fulfillment(of: [slept, woke], timeout: 900)

        terminal.poll()
        terminal.send("printf 'AFTER_WAKE\\n'\r")
        let afterDeadline = Date().addingTimeInterval(30)
        while terminal.snapshot?.text.contains("AFTER_WAKE") != true, Date() < afterDeadline {
            terminal.poll(); try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(terminal.snapshot?.text.contains("AFTER_WAKE") == true, "the session must accept and render input after wake")
        XCTAssertFalse(terminal.isShutdown)
        XCTAssertEqual(rendererWasHealthy, !terminal.health.usesSoftware, "the renderer health must not silently change")
    }
}
