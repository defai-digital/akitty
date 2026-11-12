import AppKit
import XCTest
@testable import AkittyKit

final class TerminalExitTests: XCTestCase {
    /// A bare `exit` inherits the previous command's status, including failure.
    @MainActor func testBareExitAfterFailedCommandClosesThePane() async throws {
        _ = NSApplication.shared
        var preferences = TerminalPreferences()
        preferences.shell = "/bin/sh"
        preferences.directory = "/tmp"
        preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        defer { terminal.shutdown() }
        var exits = 0
        terminal.onExit = { exits += 1 }
        try terminal.session.input("false\rexit\r")
        for _ in 0..<500 where terminal.snapshot?.exited != true {
            terminal.poll()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let snapshot = try XCTUnwrap(terminal.snapshot)
        XCTAssertTrue(snapshot.exited, "the real shell must have exited")
        XCTAssertEqual(snapshot.exit_code, 1, "bare exit inherits false's status")
        XCTAssertNil(snapshot.error)
        // The close callback is deferred to the main queue after applying the snapshot.
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(exits, 1, "an exited shell must not leave an unresponsive pane")
    }

    @MainActor func testReportedShellExitRequestsCloseOnlyOnce() async throws {
        _ = NSApplication.shared
        for code in [0, 1, 7, 255] {
            let terminal = try TerminalView(headless: true, forceSoftware: true)
            defer { terminal.shutdown() }
            var exits = 0
            terminal.onExit = { [weak terminal] in exits += 1; terminal?.shutdown() }
            let snapshot = try exitSnapshot(terminal, code: code)
            terminal.applySnapshot(.success(snapshot))
            terminal.applySnapshot(.success(snapshot))
            for _ in 0..<100 where exits == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(exits, 1, "exit status \(code) must close its pane exactly once")
            XCTAssertThrowsError(try terminal.session.snapshot(), "the removed pane's session is closed")
            terminal.onExit = nil
        }
    }

    @MainActor func testFailuresAndUnknownExitStatusRemainAvailableForRestart() async throws {
        _ = NSApplication.shared
        let cases: [(Int?, String?)] = [
            (nil, nil),
            (0, "Terminal engine error. Use Shell → Restart Terminal."),
            (1, "PTY read failed")
        ]
        for (code, error) in cases {
            let terminal = try TerminalView(headless: true, forceSoftware: true)
            defer { terminal.shutdown() }
            var exits = 0
            terminal.onExit = { exits += 1 }
            let snapshot = try exitSnapshot(terminal, code: code, error: error)
            terminal.applySnapshot(.success(snapshot))
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertEqual(exits, 0)
            XCTAssertNoThrow(try terminal.session.snapshot())
        }
    }

    @MainActor private func exitSnapshot(_ terminal: TerminalView, code: Int?, error: String? = nil) throws -> Snapshot {
        let data = try terminal.session.call("snapshot", ["compact": true])
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        value["exited"] = true
        value["exit_code"] = code
        value["error"] = error
        return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
