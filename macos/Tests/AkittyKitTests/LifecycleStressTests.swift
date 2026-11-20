import XCTest
import AppKit
@testable import AkittyKit

private final class WeakTerminal {
    weak var value: TerminalView?
    init(_ value: TerminalView) { self.value = value }
}

final class LifecycleStressTests: XCTestCase {
    @MainActor func testRealPanesResizePollAndReleaseAfterRepeatedShutdown() async throws {
        try await runRepeatedShutdownTest(forceSoftware: true, rounds: 4, resizeSteps: 8)
    }

    @MainActor func testRealMetalPanesResizeHideRestoreAndReleaseAfterRepeatedShutdown() async throws {
        try await runRepeatedShutdownTest(forceSoftware: false, rounds: 2, resizeSteps: 4)
    }

    @MainActor private func runRepeatedShutdownTest(forceSoftware: Bool, rounds: Int, resizeSteps: Int) async throws {
        _ = NSApplication.shared
        for round in 0..<rounds {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var preferences = TerminalPreferences()
            preferences.shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/lifecycle-shell.sh").path
            preferences.directory = "/tmp"; preferences.scrollback = 100
            var panes = try (0..<4).map { index in
                let pane = try TerminalView(headless: false, forceSoftware: forceSoftware, forceShaderFailure: false, initial: preferences)
                pane.frame = NSRect(x: (index % 2) * 400, y: (index / 2) * 250, width: 400, height: 250)
                window.contentView?.addSubview(pane)
                return pane
            }
            var rasters = Array(repeating: 0, count: panes.count)
            for (index, pane) in panes.enumerated() {
                pane.onNativeFrameEvent = { event in if case .rasterStarted = event { rasters[index] += 1 } }
            }
            let weakPanes = panes.map(WeakTerminal.init)
            let sessions = panes.map(\.session)
            defer { panes.forEach { $0.onNativeFrameEvent = nil; $0.shutdown(); $0.removeFromSuperview() }; window.close() }
            for step in 0..<resizeSteps {
                for pane in panes {
                    pane.setFrameSize(NSSize(width: 360 + step * 4, height: 220 + step * 2))
                    pane.layout(); pane.poll()
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let deadline = Date().addingTimeInterval(5)
            while !panes.allSatisfy({ $0.snapshot?.text.contains("PANE_READY") == true }), Date() < deadline {
                panes.forEach { $0.poll() }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(panes.allSatisfy { $0.snapshot?.text.contains("PANE_READY") == true }, "round \(round)")
            if !forceSoftware {
                try XCTSkipIf(panes.contains(where: \.health.usesSoftware), "Metal renderer unavailable")
            }

            panes.forEach { $0.isHidden = true }
            let hiddenRasterCounts = rasters
            for pane in panes {
                _ = try pane.session.call("input", ["text": "printf 'HIDDEN_UPDATE\\n'\r"])
            }
            let hiddenDeadline = Date().addingTimeInterval(5)
            while !panes.allSatisfy({ $0.snapshot?.text.contains("HIDDEN_UPDATE") == true }), Date() < hiddenDeadline {
                panes.forEach { $0.poll() }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(panes.allSatisfy { $0.snapshot?.text.contains("HIDDEN_UPDATE") == true }, "round \(round)")
            XCTAssertEqual(rasters, hiddenRasterCounts, "hidden panes must not rasterize")

            panes.forEach { $0.isHidden = false; $0.poll() }
            let visibleDeadline = Date().addingTimeInterval(5)
            while rasters == hiddenRasterCounts, Date() < visibleDeadline {
                panes.forEach { $0.poll() }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertGreaterThan(rasters.reduce(0, +), hiddenRasterCounts.reduce(0, +), "restored panes must render")

            let closed = expectation(description: "all repeated shutdown callbacks")
            closed.expectedFulfillmentCount = panes.count * 2
            for pane in panes { pane.send("while :; do printf 'busy\\n'; done\r") }
            let outputDeadline = Date().addingTimeInterval(5)
            while !panes.allSatisfy({ $0.snapshot?.text.contains("busy") == true }), Date() < outputDeadline {
                panes.forEach { $0.poll() }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(panes.allSatisfy { $0.snapshot?.text.contains("busy") == true }, "busy output never started in round \(round)")
            for pane in panes {
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
