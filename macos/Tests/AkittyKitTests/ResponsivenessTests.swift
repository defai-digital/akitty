import XCTest
import AppKit
@testable import AkittyKit

/// Main-thread responsiveness of a pane: scroll math, low-rate hidden polling, per-image texture limits and the
/// change detection that keeps a busy frame from rebuilding the tab strip.
final class ResponsivenessTests: XCTestCase {
    // MARK: Scrolling

    func testPreciseScrollingAccumulatesPointsIntoWholeLines() {
        var remainder: CGFloat = 0
        XCTAssertEqual(TerminalView.scrollLines(delta: 8, cellHeight: 16, remainder: &remainder), 0, "half a cell is no line yet")
        XCTAssertEqual(remainder, 8)
        XCTAssertEqual(TerminalView.scrollLines(delta: 8, cellHeight: 16, remainder: &remainder), 1)
        XCTAssertEqual(remainder, 0)
        XCTAssertEqual(TerminalView.scrollLines(delta: -35, cellHeight: 16, remainder: &remainder), -2, "a flick emits several lines")
        XCTAssertEqual(remainder, -3, "the fraction carries to the next event")
        XCTAssertEqual(TerminalView.scrollLines(delta: 1e9, cellHeight: 16, remainder: &remainder), 1000, "an absurd delta is clamped")
    }

    func testPreciseScrollingSurvivesNonFiniteDeltas() {
        var remainder: CGFloat = 0
        XCTAssertEqual(TerminalView.scrollLines(delta: .nan, cellHeight: 16, remainder: &remainder), 0)
        XCTAssertEqual(TerminalView.scrollLines(delta: .infinity, cellHeight: 16, remainder: &remainder), 0)
        XCTAssertEqual(TerminalView.scrollLines(delta: -8, cellHeight: .nan, remainder: &remainder), 0, "a broken cell height emits nothing")
        XCTAssertEqual(TerminalView.scrollLines(delta: 8, cellHeight: 0, remainder: &remainder), 0)
        XCTAssertEqual(remainder, 0, "a rejected delta never perturbs the accumulator")
    }

    // MARK: Polling

    func testHiddenPanesPollAtFourHertz() {
        XCTAssertEqual(TerminalView.refreshInterval(visible: false, focused: false, recentInput: false), 0.25)
        XCTAssertEqual(TerminalView.refreshInterval(visible: true, focused: true, recentInput: false), 0,
                       "a focused visible pane keeps immediate polling")
    }

    /// The idle safety net is one poll per second; the core's wakeup pipe drives the rest.
    @MainActor func testSafetyPollIntervalIsOneSecond() {
        XCTAssertEqual(TerminalView.safetyPollInterval, 1)
    }

    /// A poll requested while another is in flight must not be dropped: the running one may have been built before
    /// the change, and with no 30 Hz timer the next chance would be the one-second safety tick.
    @MainActor func testPollRequestedDuringAnInFlightPollRunsAfterIt() async throws {
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        terminal.poll()
        // Block main so the first poll's snapshot is built off-main before the feed, while its completion (which
        // clears `pollInFlight`) is still queued behind this test on the main thread.
        Thread.sleep(forTimeInterval: 0.1)
        _ = try terminal.session.call("feed", ["text": "SECOND_POLL_MARKER"])
        terminal.poll()
        let start = Date()
        while terminal.snapshot?.text.contains("SECOND_POLL_MARKER") != true, Date().timeIntervalSince(start) < 0.5 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(terminal.snapshot?.text.contains("SECOND_POLL_MARKER") == true, "the second poll was dropped")
    }

    /// A real PTY pane must show shell output without the test calling poll(): either the core's
    /// notify pipe (visible pane) or the one-second safety tick must deliver it.
    @MainActor func testRealPTYOutputAppearsWithoutExplicitPoll() async throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: false, forceSoftware: true)
        defer { terminal.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        defer { window.close() }
        try terminal.session.input("printf 'CORE_WAKE_MARKER\\n'\r")
        let start = Date()
        while terminal.snapshot?.text.contains("CORE_WAKE_MARKER") != true, Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(terminal.snapshot?.text.contains("CORE_WAKE_MARKER") == true, "no explicit poll() was issued")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.2, "output must arrive within about one safety interval")
    }

    // MARK: Image textures

    func testImagesBeyondTheTextureSideAreSkipped() {
        XCTAssertTrue(MetalPresenter.imageFits(width: 16384, height: 512, limit: 16384))
        XCTAssertFalse(MetalPresenter.imageFits(width: 20000, height: 400, limit: 16384), "under 8 Mi pixels, still too wide")
        XCTAssertFalse(MetalPresenter.imageFits(width: 400, height: 20000, limit: 16384))
        XCTAssertFalse(MetalPresenter.imageFits(width: 0, height: 10, limit: 16384))
        XCTAssertFalse(MetalPresenter.imageFits(width: 10, height: -1, limit: 16384))
    }

    // MARK: Snapshot change detection

    @MainActor func testRepeatedSnapshotsPublishTitleChromeAndStatusOnce() throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        var titles: [String] = [], statuses: [String] = [], chromes = 0
        terminal.onTitle = { titles.append($0) }
        terminal.onStatus = { statuses.append($0) }
        terminal.onChrome = { _ in chromes += 1 }
        for revision in 1...3 {
            terminal.applySnapshot(.success(try snapshot(revision: UInt64(revision), title: "vim", mark: "busy")))
        }
        XCTAssertEqual(titles, ["vim"])
        XCTAssertEqual(chromes, 1, "a frame that repeats the chrome must not rebuild the tab strip")
        XCTAssertEqual(statuses.count, 1, "status: \(statuses)")
        terminal.applySnapshot(.success(try snapshot(revision: 4, title: "nvim", mark: "busy")))
        XCTAssertEqual(titles, ["vim", "nvim"])
        XCTAssertEqual(chromes, 1, "the title changed, not the chrome")
        terminal.applySnapshot(.success(try snapshot(revision: 5, title: "nvim", mark: "error")))
        XCTAssertEqual(chromes, 2)
    }

    @MainActor func testSnapshotDamageIsMergedBeforeReentrantTitleCallbacks() throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: false, forceSoftware: true)
        defer { terminal.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        defer { window.close() }
        terminal.applySnapshot(.success(try snapshot(revision: 1, title: "old")))
        terminal.onTitle = { [weak terminal] _ in
            guard let terminal else { return }
            XCTAssertEqual(terminal.gridDamage.rows, [0], "a reentrant redraw must not use the previous frame's damage")
            terminal.unmarkText()
        }
        terminal.applySnapshot(.success(try snapshot(revision: 2, title: "new", partial: true, dirty: [0])))
    }

    @MainActor func testStatusTextRepublishesOnlyWhenItChanges() throws {
        _ = NSApplication.shared
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        defer { terminal.shutdown() }
        var statuses: [String] = []
        terminal.onStatus = { statuses.append($0) }
        // The core's error text outranks the renderer state, so the dedupe is tested without depending on Metal.
        terminal.applySnapshot(.success(try snapshot(revision: 1, error: "boom")))
        terminal.applySnapshot(.success(try snapshot(revision: 2, error: "boom")))
        XCTAssertEqual(statuses, ["boom"])
        terminal.applySnapshot(.success(try snapshot(revision: 3, error: "bang")))
        XCTAssertEqual(statuses, ["boom", "bang"])
    }

    @MainActor func testBitmapRasterReadyInvalidatesAtlasBeforeIMEReentry() async throws {
        _ = NSApplication.shared
        let terminal: TerminalView
        do { terminal = try TerminalView(headless: true, forceSoftware: false) }
        catch { throw XCTSkip("Metal unavailable: \(error)") }
        defer { terminal.onNativeFrameEvent = nil; terminal.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        defer { window.close() }
        terminal.applySnapshot(.success(try terminal.session.snapshot()))
        let atlasStart = Date()
        while !terminal.lastTextFramed, Date().timeIntervalSince(atlasStart) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(terminal.lastTextFramed, "the warm-up must present an atlas frame")
        // An emoji cluster stays on the CPU reference path even after the IME mark is cleared, which a
        // fitted wide CJK scalar no longer does.
        _ = try terminal.session.call("feed", ["text": "\u{1b}[1;1H👨\u{200D}👩\u{200D}👧"])
        let previous = terminal.snapshot
        let next = try terminal.session.snapshot(since: previous?.revision, base: previous)
        var reentered = false, completedAfterReentry = false
        terminal.onNativeFrameEvent = { event in
            if case .handedOff(let revision) = event, revision == next?.revision, reentered { completedAfterReentry = true }
            if case .rasterReady(let revision) = event, revision == next?.revision, terminal.hasMarkedText() {
                XCTAssertFalse(terminal.lastTextFramed, "CPU completion must invalidate atlas reuse before observers run")
                terminal.unmarkText()
                reentered = true
            }
        }
        terminal.setMarkedText("x", selectedRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.applySnapshot(.success(next))
        let start = Date()
        while (!reentered || !completedAfterReentry), Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(reentered)
        XCTAssertTrue(completedAfterReentry, "the reentrant frame must also complete")
        XCTAssertFalse(terminal.lastTextFramed, "an emoji cluster remains on the CPU reference path")
    }

    @MainActor func testRasterStartedObserverCannotGiveItsDamageToTheOlderFrame() async throws {
        _ = NSApplication.shared
        let terminal: TerminalView
        do { terminal = try TerminalView(headless: true, forceSoftware: false) }
        catch { throw XCTSkip("Metal unavailable: \(error)") }
        defer { terminal.onNativeFrameEvent = nil; terminal.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        defer { window.close() }
        terminal.applySnapshot(.success(try terminal.session.snapshot()))
        let atlasStart = Date()
        while !terminal.lastTextFramed, Date().timeIntervalSince(atlasStart) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(terminal.lastTextFramed)
        let initial = terminal.snapshot
        _ = try terminal.session.call("feed", ["text": "\u{1b}[1;1Hx"])
        let ascii = try terminal.session.snapshot(since: initial?.revision, base: initial)
        // An emoji cluster keeps the nested frame on the CPU reference path; a fitted wide CJK scalar no longer does.
        _ = try terminal.session.call("feed", ["text": "\u{1b}[6;1H👨\u{200D}👩\u{200D}👧"])
        let cluster = try terminal.session.snapshot(since: ascii?.revision, base: ascii)
        var applied = false, completed = false
        terminal.onNativeFrameEvent = { event in
            if case .rasterStarted(let revision) = event, revision == ascii?.revision, !applied {
                applied = true
                terminal.applySnapshot(.success(cluster))
            }
            if case .handedOff(let revision) = event, revision == cluster?.revision { completed = true }
        }
        terminal.applySnapshot(.success(ascii))
        let start = Date()
        while !completed, Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(applied)
        XCTAssertTrue(completed, "the nested cluster snapshot must retain its own damage and complete")
        XCTAssertFalse(terminal.lastTextFramed, "the final emoji cluster frame must use the CPU reference path")
    }

    // A snapshot as the core sends it: only the fields a full frame carries, so this decodes exactly like a live one.
    private func snapshot(revision: UInt64, title: String = "", mark: String? = nil, error: String? = nil,
                          partial: Bool = false, dirty: [Int]? = nil) throws -> Snapshot {
        var object: [String: Any] = ["changed": true, "revision": revision, "cols": 6, "rows": 3, "title": title,
            "cells": [] as [[String: Any]], "lines": Array(repeating: String(repeating: " ", count: 6), count: 3),
            "links": [] as [String], "cursor": ["row": 0, "col": 0, "visible": false], "bracketed_paste": false,
            "app_cursor": false, "mouse_mode": false, "mouse_sgr": false, "mouse_drag": false, "mouse_motion": false,
            "focus_reporting": false, "alternate": false, "offset": 0, "history": 0, "clipboard": [] as [String], "exited": false]
        if partial { object["partial"] = true; object["dirty"] = dirty ?? [] }
        var chrome: [String: Any] = [:]
        if let mark { chrome["mark"] = mark }
        if !chrome.isEmpty { object["chrome"] = chrome }
        if let error { object["error"] = error }
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
