import AppKit
import XCTest
@testable import AgentIPC
@testable import AkittyKit

final class AgentIntegrationsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/akitty-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func script(_ name: String, in folder: URL, body: String, mode: Int = 0o755) throws -> String {
        let url = folder.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    func testSearchPathAddsUsualFoldersAfterTheInheritedPathWithoutDuplicates() {
        let home = URL(fileURLWithPath: "/tmp/home-for-test")
        let path = AgentCLI.searchPath(environment: ["PATH": "/usr/bin:relative/bin:/custom/bin"], home: home)
        XCTAssertEqual(Array(path.prefix(2)), ["/usr/bin", "/custom/bin"], "the inherited PATH comes first; relative entries are dropped")
        XCTAssertTrue(path.contains("/tmp/home-for-test/.local/bin")); XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testLocateFindsOnlyExecutableFilesInOrder() throws {
        let first = try directory(), second = try directory()
        _ = try script("codex", in: first, body: "exit 0", mode: 0o644)            // not executable
        try FileManager.default.createDirectory(at: first.appendingPathComponent("claude"), withIntermediateDirectories: false) // a folder
        let codex = try script("codex", in: second, body: "exit 0")
        let claude = try script("claude", in: second, body: "exit 0")
        XCTAssertEqual(AgentCLI.locate("codex", in: [first.path, second.path]), codex)
        XCTAssertEqual(AgentCLI.locate("claude", in: [first.path, second.path]), claude)
        XCTAssertNil(AgentCLI.locate("ax-code", in: [first.path, second.path]))
    }

    func testVersionReadsOneSanitizedLineAndGivesUpOnSlowOrFailingCLIs() async throws {
        let folder = try directory()
        let good = try script("good", in: folder, body: "printf '2.1.327 (Claude Code)\\033[31m\\nsecond line\\n'")
        let version = await AgentCLI.version(of: good)
        XCTAssertEqual(version, "2.1.327 (Claude Code)")
        let slow = try script("slow", in: folder, body: "sleep 5; echo late")
        let slowVersion = await AgentCLI.version(of: slow, timeout: 0.3)
        XCTAssertNil(slowVersion)
        // A large output, and a child left holding the pipe open, cannot hang the probe.
        let noisy = try script("noisy", in: folder, body: "echo 1.0-noisy; yes filler | head -c 200000; exit 0")
        let noisyVersion = await AgentCLI.version(of: noisy, timeout: 3)
        XCTAssertEqual(noisyVersion, "1.0-noisy")
        let lingering = try script("lingering", in: folder, body: "echo 2.0-lingering; (sleep 30 &) ; exit 0")
        let started = Date()
        let lingeringVersion = await AgentCLI.version(of: lingering, timeout: 3)
        XCTAssertEqual(lingeringVersion, "2.0-lingering")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let silent = try script("silent", in: folder, body: "echo 9.9; exit 3")
        let silentVersion = await AgentCLI.version(of: silent)
        XCTAssertNil(silentVersion)
    }

    func testCapabilitiesMatchWhatAkiTTYImplements() {
        let byID = Dictionary(uniqueKeysWithValues: AgentCLI.all.map { ($0.id, $0) })
        XCTAssertEqual(byID["claude-code"]?.hooks, .claudeCode)
        XCTAssertEqual(byID["codex"]?.hooks, .codex)
        XCTAssertNil(byID["ax-code"]?.hooks)
        XCTAssertNotNil(byID["ax-code"]?.unavailableReason)
        XCTAssertTrue(byID["codex"]?.capabilities.allSatisfy(\.available) == true)
        XCTAssertTrue(byID["ax-code"]?.capabilities.allSatisfy { !$0.available } == true)
        // Every agent the service accepts has a row, and every row with hooks is an accepted agent.
        XCTAssertEqual(Set(AgentRequests.agentNames.keys), Set(AgentCLI.all.filter { $0.hooks != nil }.map(\.id)))
        XCTAssertFalse(AgentRequestsLaunchSetting.isOn(UserDefaults(suiteName: "akitty-empty-\(UUID().uuidString)")!), "off by default")
    }

    @MainActor func testLastReportShowsTheNewestConversationOfThatAgent() throws {
        _ = NSApplication.shared
        let root = try directory()
        let panes = try (0..<2).map { _ in try TerminalView(headless: true, forceSoftware: true) }
        let service = AgentRequests(source: { panes }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        defer { service.stop(); panes.forEach { $0.shutdown() } }
        XCTAssertNil(service.lastReport(agent: "codex"))
        service.report(agent: "codex", event: "session_start", sessionID: "old-conversation", in: panes[0])
        service.report(agent: "claude-code", event: "session_start", sessionID: "claude-one", in: panes[1])
        let report = try XCTUnwrap(service.lastReport(agent: "codex", now: Date().addingTimeInterval(125)))
        XCTAssertEqual(report, "old-conv… in pane \(panes[0].session.id), 2 min ago")
        service.report(agent: "codex", event: "session_start", sessionID: "newer", in: panes[1])
        XCTAssertTrue(service.lastReport(agent: "codex")?.hasPrefix("newer in pane \(panes[1].session.id)") == true)
    }
}
