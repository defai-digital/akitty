import XCTest
import AppKit
@testable import AkittyKit

private final class WeakTerminal {
    weak var value: TerminalView?
    init(_ value: TerminalView) { self.value = value }
}

final class LifecycleStressTests: XCTestCase {
    @MainActor func testRealPanesResizePollAndReleaseAfterRepeatedShutdown() async throws {
        _ = NSApplication.shared
        for round in 0..<4 {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var preferences = TerminalPreferences()
            preferences.shell = "/bin/sh"; preferences.directory = "/tmp"; preferences.scrollback = 100
            var panes = try (0..<4).map { index in
                let pane = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
                pane.frame = NSRect(x: (index % 2) * 400, y: (index / 2) * 250, width: 400, height: 250)
                window.contentView?.addSubview(pane)
                return pane
            }
            let weakPanes = panes.map(WeakTerminal.init)
            let sessions = panes.map(\.session)
            defer { panes.forEach { $0.shutdown(); $0.removeFromSuperview() }; window.close() }
            for pane in panes { pane.send("stty -echo; printf '\\033[2J\\033[HPANE_READY\\n'\r") }
            for step in 0..<8 {
                for pane in panes {
                    pane.setFrameSize(NSSize(width: 360 + step * 4, height: 220 + step * 2))
                    pane.layout(); pane.poll()
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let deadline = Date().addingTimeInterval(5)
            while !panes.allSatisfy({ $0.snapshot?.text.contains("PANE_READY") == true }) && Date() < deadline {
                panes.forEach { $0.poll() }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(panes.allSatisfy { $0.snapshot?.text.contains("PANE_READY") == true }, "round \(round)")
            let closed = expectation(description: "all repeated shutdown callbacks")
            closed.expectedFulfillmentCount = panes.count * 2
            for pane in panes {
                pane.send("while :; do printf 'busy\\n'; done\r")
                pane.shutdown { closed.fulfill() }
                pane.shutdown { closed.fulfill() }
            }
            await fulfillment(of: [closed], timeout: 5)
            for session in sessions { XCTAssertThrowsError(try session.snapshot()) }
            panes.forEach { $0.removeFromSuperview() }
            panes.removeAll(); window.close()
            // Queued raster/snapshot closures must release their views after teardown.
            for _ in 0..<100 where weakPanes.contains(where: { $0.value != nil }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(weakPanes.allSatisfy { $0.value == nil }, "pane/timer retained after round \(round)")
        }
    }
}
