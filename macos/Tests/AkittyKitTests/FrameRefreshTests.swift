import AppKit
import XCTest
@testable import AkittyKit

@MainActor final class FrameRefreshTests: XCTestCase {
    private final class Job {
        let deadline: Double, operation: () -> Void
        var cancelled = false
        init(_ deadline: Double, _ operation: @escaping () -> Void) { self.deadline = deadline; self.operation = operation }
    }
    private final class Clock {
        var time = 0.0, interval = 1.0 / 30
        var jobs: [Job] = []
        func schedule(_ delay: TimeInterval, _ operation: @escaping () -> Void) -> (() -> Void) {
            let job = Job(time + delay, operation); jobs.append(job)
            return { job.cancelled = true }
        }
        func advance(to time: Double) {
            self.time = time
            var count = 0
            while let job = jobs.first(where: { !$0.cancelled && $0.deadline <= time }), count < 100 {
                job.cancelled = true; job.operation(); count += 1
            }
            XCTAssertLessThan(count, 100, "refresh callback rescheduled endlessly")
        }
    }
    func testBurstKeepsOnlyOneDeadlineAndDeliversTheFinalStateWithoutAnotherWake() {
        let clock = Clock()
        var model = 0, observed: [Int] = []
        let refresh = FrameRefresh(now: { clock.time }, interval: { clock.interval }, schedule: clock.schedule, perform: { observed.append(model) })
        refresh.request()
        clock.time = 0.01
        for value in 1...300 { model = value; refresh.request() }
        XCTAssertEqual(observed, [0])
        XCTAssertEqual(clock.jobs.filter { !$0.cancelled }.count, 1)
        clock.advance(to: 0.034)
        XCTAssertEqual(observed, [0, 300], "the last change needs no later wake")
        clock.advance(to: 1)
        XCTAssertEqual(observed, [0, 300], "an idle pane must not keep rescheduling")
    }
    func testFocusGainCancelsTheOldDeadlineAndLateCallbacksCannotReplaceNewWork() {
        let clock = Clock()
        var calls = 0
        let refresh = FrameRefresh(now: { clock.time }, interval: { clock.interval }, schedule: clock.schedule, perform: { calls += 1 })
        refresh.request(); clock.time = 0.01; refresh.request()
        let old = clock.jobs[0]
        clock.interval = 0; refresh.request(); refresh.request()
        XCTAssertEqual(calls, 3, "focused requests are immediate")
        clock.interval = 1.0 / 30; refresh.request()
        old.operation()
        XCTAssertEqual(clock.jobs.filter { !$0.cancelled }.count, 1)
        clock.advance(to: 0.05)
        XCTAssertEqual(calls, 4)
    }
    func testVisibilityRestoreBringsThePendingDeadlineForward() {
        let clock = Clock(); clock.interval = 0.25
        var calls = 0
        let refresh = FrameRefresh(now: { clock.time }, interval: { clock.interval }, schedule: clock.schedule, perform: { calls += 1 })
        refresh.request(); clock.time = 0.01; refresh.request()
        clock.interval = 1.0 / 30; refresh.request()
        clock.advance(to: 0.04)
        XCTAssertEqual(calls, 2, "a hidden-pane deadline must not delay the newly visible pane")
    }
    func testHidingBeforeADeadlineRechecksTheNewCadence() {
        let clock = Clock()
        var calls = 0
        let refresh = FrameRefresh(now: { clock.time }, interval: { clock.interval }, schedule: clock.schedule, perform: { calls += 1 })
        refresh.request(); clock.time = 0.01; refresh.request()
        clock.interval = 0.25
        clock.advance(to: 0.04); XCTAssertEqual(calls, 1)
        clock.advance(to: 0.26); XCTAssertEqual(calls, 2)
    }
    func testShutdownRejectsScheduledAndFutureRequests() {
        let clock = Clock()
        var calls = 0
        let refresh = FrameRefresh(now: { clock.time }, interval: { clock.interval }, schedule: clock.schedule, perform: { calls += 1 })
        refresh.request(); clock.time = 0.01; refresh.request()
        let old = clock.jobs[0]
        refresh.invalidate(); old.operation(); refresh.request(); clock.advance(to: 1)
        XCTAssertEqual(calls, 1)
    }
    func testUnfocusedTailSnapshotKeepsTitleAndBellAndStopsAfterShutdown() async throws {
        _ = NSApplication.shared
        var preferences = TerminalPreferences(); preferences.silentMode = true
        let terminal = try TerminalView(headless: true, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { terminal.shutdown(); window.close() }
        try await Task.sleep(nanoseconds: 150_000_000)
        var titles: [String] = [], bells = 0, polls = 0
        terminal.onTitle = { titles.append($0) }; terminal.onBell = { bells += 1 }
        terminal.onNativeFrameEvent = { if case .snapshotStarted = $0 { polls += 1 } }
        for value in 0..<40 {
            _ = try terminal.session.call("feed", ["text": "\u{1b}[Hupdate \(value)"])
            terminal.requestAutomaticRefresh()
        }
        _ = try terminal.session.call("feed", ["text": "\u{1b}]2;final-tail\u{7}\r\nTAIL_MARKER\u{7}"])
        terminal.requestAutomaticRefresh()
        let deadline = Date().addingTimeInterval(1)
        while (terminal.snapshot?.text.contains("TAIL_MARKER") != true || !titles.contains("final-tail") || bells != 1), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(terminal.snapshot?.text.contains("TAIL_MARKER") == true)
        XCTAssertTrue(titles.contains("final-tail")); XCTAssertEqual(bells, 1)
        terminal.requestAutomaticRefresh(); terminal.shutdown()
        let beforeShutdown = polls
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(polls, beforeShutdown, "late deadlines must not poll a closed session")
    }
    func testNativePolicyKeepsHiddenCadenceAndBypassesForFocusOrInteraction() {
        XCTAssertEqual(TerminalView.refreshInterval(visible: false, focused: true, recentInput: true), 0.25)
        XCTAssertEqual(TerminalView.refreshInterval(visible: true, focused: true, recentInput: false), 0)
        XCTAssertEqual(TerminalView.refreshInterval(visible: true, focused: false, recentInput: true), 0)
        XCTAssertEqual(TerminalView.refreshInterval(visible: true, focused: false, recentInput: false), 1.0 / 30)
    }
}
