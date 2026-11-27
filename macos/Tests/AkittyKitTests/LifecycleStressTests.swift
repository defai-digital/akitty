import XCTest
import AppKit
@testable import AkittyKit

private final class WeakTerminal {
    weak var value: TerminalView?
    init(_ value: TerminalView) { self.value = value }
}

private final class BackingScaleWindow: NSWindow {
    var simulatedScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { simulatedScale }
}

final class LifecycleStressTests: XCTestCase {
    @MainActor func testRealPanesResizePollAndReleaseAfterRepeatedShutdown() async throws {
        try await runRepeatedShutdownTest(forceSoftware: true, rounds: 4, resizeSteps: 8)
    }

    @MainActor func testRealMetalPanesResizeHideRestoreAndReleaseAfterRepeatedShutdown() async throws {
        try await runRepeatedShutdownTest(forceSoftware: false, rounds: 2, resizeSteps: 4)
    }

    @MainActor func testBackingScaleChangeDiscardsTheInFlightFrameAtTheSamePointSize() async throws {
        _ = NSApplication.shared
        for forceSoftware in [true, false] {
            let window = BackingScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                            styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var preferences = TerminalPreferences()
            preferences.fontName = "Menlo"
            let pane = try TerminalView(headless: true, forceSoftware: forceSoftware, forceShaderFailure: false, initial: preferences)
            defer { pane.onNativeFrameEvent = nil; pane.shutdown(); pane.removeFromSuperview(); window.close() }
            if !forceSoftware { try XCTSkipIf(pane.health.usesSoftware, "Metal renderer unavailable") }

            pane.frame = try XCTUnwrap(window.contentView).bounds
            window.contentView?.addSubview(pane)
            _ = try pane.session.call("feed", ["text": "backing scale"])

            var readyFrames = 0
            var firstPublication: Int?
            pane.onNativeFrameEvent = { event in
                switch event {
                case .rasterReady:
                    readyFrames += 1
                    if readyFrames == 1 {
                        let pointSize = pane.bounds.size
                        window.simulatedScale = 1
                        pane.viewDidChangeBackingProperties()
                        XCTAssertEqual(pane.bounds.size, pointSize)
                    }
                case .handedOff, .rasterCompleted:
                    if firstPublication == nil { firstPublication = readyFrames }
                default: break
                }
            }
            pane.poll()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (firstPublication == nil || readyFrames < 2), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(firstPublication, 2, "the first publication must come from the replacement raster")
            if !forceSoftware { XCTAssertFalse(pane.health.usesSoftware) }
        }
    }

    /// `releaseRetainedFrames` drops the presenter's textures on the main thread while the composer is reset
    /// on the raster queue, so a text frame composed before a hide can reach its handoff afterwards. Before the
    /// release-generation guard that either failed the full-repaint check -- and `renderFailed` disables Metal
    /// for the pane for good -- or drew from freshly allocated blank pages.
    ///
    /// Hiding and un-hiding inside `.rasterReady` fixes the ordering deterministically: that event fires on
    /// the main thread inside the handoff, after the frame was composed on the raster queue and before it is
    /// published, so the release always lands in exactly the window the guard exists for.
    @MainActor func testAFrameComposedBeforeAHideIsDroppedInsteadOfDisablingMetal() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var preferences = TerminalPreferences()
        preferences.shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lifecycle-shell.sh").path
        preferences.directory = "/tmp"; preferences.scrollback = 100
        let pane = try TerminalView(headless: false, forceSoftware: false, forceShaderFailure: false, initial: preferences)
        window.contentView?.addSubview(pane)
        defer { pane.onNativeFrameEvent = nil; pane.shutdown(); pane.removeFromSuperview(); window.close() }
        try XCTSkipIf(pane.health.usesSoftware, "Metal renderer unavailable")

        var races = 0, handoffs = 0, racing = false
        pane.onNativeFrameEvent = { event in
            switch event {
            case .handedOff:
                handoffs += 1
            case .rasterReady where racing && races < 4:
                // Un-hiding redraws, which starts another frame: only race the first few, or the observer
                // re-triggers itself forever and the main thread never gets to poll again.
                let before = pane.releaseGeneration
                pane.isHidden = true
                XCTAssertGreaterThan(pane.releaseGeneration, before, "hiding released the presenter's textures")
                pane.isHidden = false
                races += 1
            default:
                break
            }
        }

        // Wait for the fixture shell to be reading before sending it any input.
        let ready = Date().addingTimeInterval(5)
        while pane.snapshot?.text.contains("PANE_READY") != true, Date() < ready {
            pane.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try XCTSkipIf(pane.health.usesSoftware, "Metal renderer unavailable")
        XCTAssertTrue(pane.snapshot?.text.contains("PANE_READY") == true)

        // Let the initial full-repaint frame publish first. Racing it would only ever exercise full frames,
        // and only a partial frame can fail the full-repaint guard this test exists for.
        let initial = Date().addingTimeInterval(5)
        while handoffs == 0, Date() < initial {
            pane.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(handoffs, 0, "the initial frame published before any race")
        racing = true
        let deadline = Date().addingTimeInterval(5)
        while races < 4, Date() < deadline {
            // Fresh output each pass so a new frame is composed and raced every time.
            _ = try pane.session.call("input", ["text": "printf 'RACE\\n'\r"])
            pane.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(races, 4, "the hide/restore interleaving actually happened")
        // Wait for a post-race frame to be handed off, not merely for the snapshot to have moved on: a bug
        // that starved every later frame would otherwise pass here.
        let published = handoffs
        let settle = Date().addingTimeInterval(5)
        while handoffs == published, Date() < settle {
            // Keep producing output: without a new frame there would be no handoff to wait for at all.
            _ = try pane.session.call("input", ["text": "printf 'RACE\\n'\r"])
            pane.poll()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(handoffs, published, "a post-race frame was handed off")
        XCTAssertNil(pane.health.failure, "a stale frame must never reach renderFailed")
        XCTAssertFalse(pane.health.usesSoftware, "a stale frame must not permanently disable Metal")
        XCTAssertTrue(pane.snapshot?.text.contains("RACE") == true, "the pane recovered by composing again")
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
