import AppKit
import XCTest
@testable import AkittyKit

/// Reopening a workspace offers each pane's agent conversation by its ID; nothing starts until the human asks.
final class AgentResumeTests: XCTestCase {
    @MainActor private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true")
    }
    private func suite() -> UserDefaults {
        let name = "akitty-resume-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private static let claude = AgentConversation(agent: "claude-code", sessionID: "f9042739-25af-4e2a-b81b-ea40affd269b", reported: 1_800_000_000)

    func testOnlyKnownAgentsAndPlainIDsCanBeResumed() {
        XCTAssertEqual(Self.claude.resumeCommand, "claude --resume f9042739-25af-4e2a-b81b-ea40affd269b")
        for id in ["-rf", "a b", "x;rm", "$(x)", "", String(repeating: "a", count: 129), "é1"] {
            XCTAssertNil(AgentConversation(agent: "claude-code", sessionID: id, reported: 0).resumeCommand, id)
        }
        XCTAssertNil(AgentConversation(agent: "other", sessionID: "abc", reported: 0).resumeCommand)
        XCTAssertFalse(AgentConversation(agent: "claude-code", sessionID: "abc", reported: .nan).isResumable)
    }

    func testLayoutDecodingDropsConversationsAkiTTYCannotResume() throws {
        let good = try JSONDecoder().decode(WindowLayout.Pane.self, from: JSONEncoder().encode(WindowLayout.Pane(directory: "/tmp", agent: Self.claude)))
        XCTAssertEqual(good.agent, Self.claude)
        for bad in [#"{"directory":"/tmp","agent":{"agent":"claude-code","sessionID":"--help","reported":1}}"#,
                    #"{"directory":"/tmp","agent":{"agent":"sh","sessionID":"abc","reported":1}}"#,
                    #"{"directory":"/tmp","agent":"claude"}"#] {
            let pane = try JSONDecoder().decode(WindowLayout.Pane.self, from: Data(bad.utf8))
            XCTAssertNil(pane.agent, bad); XCTAssertEqual(pane.directory, "/tmp")
        }
    }

    func testWorkspaceStoreKeepsNoTextAndTurningOffClearsIt() {
        let defaults = suite()
        XCTAssertFalse(WorkspaceStore.isEnabled(defaults))
        WorkspaceStore.setEnabled(true, defaults)
        let pane = WindowLayout.Pane(directory: "/tmp", scrollback: "secret output", agent: Self.claude)
        WorkspaceStore.save(WindowLayout(name: "Workspace", windows: [.init(tabs: [.init(panes: [pane])])]), defaults)
        let loaded = WorkspaceStore.load(defaults)?.windows.first?.tabs.first?.panes.first
        XCTAssertNil(loaded?.scrollback)
        XCTAssertEqual(loaded?.agent, Self.claude)
        XCTAssertFalse(String(decoding: defaults.data(forKey: WorkspaceStore.workspaceKey) ?? Data(), as: UTF8.self).contains("secret"))
        WorkspaceStore.save(WindowLayout(name: "Workspace", windows: []), defaults)
        XCTAssertEqual(WorkspaceStore.load(defaults)?.windows.first?.tabs.first?.panes.first?.agent, Self.claude, "closing the last window keeps the previous save")
        WorkspaceStore.save(WindowLayout(name: "Workspace", windows: [.init(tabs: [.init(panes: [pane])])]), defaults)
        WorkspaceStore.setEnabled(false, defaults)
        XCTAssertNil(defaults.data(forKey: WorkspaceStore.workspaceKey))
    }

    @MainActor func testRestoreOffersEachPaneItsOwnConversationAndResumesOnlyOnRequest() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); app.workspaceDefaults = suite()
        defer { for window in app.windows { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() } }
        XCTAssertFalse(try app.restoreWorkspaceIfEnabled(headless: true), "restore is off by default")
        WorkspaceStore.setEnabled(true, app.workspaceDefaults)
        XCTAssertFalse(try app.restoreWorkspaceIfEnabled(headless: true), "nothing saved yet")
        // Two conversations in the same repo, and a plain shell pane.
        let other = AgentConversation(agent: "claude-code", sessionID: "0b7e1c2d-other", reported: 1_800_000_100)
        let panes = [WindowLayout.Pane(directory: "/tmp", agent: Self.claude), WindowLayout.Pane(directory: "/tmp", agent: other), WindowLayout.Pane(directory: "/tmp")]
        WorkspaceStore.save(WindowLayout(name: "Workspace", windows: [.init(tabs: [.init(panes: panes)])]), app.workspaceDefaults)
        XCTAssertTrue(try app.restoreWorkspaceIfEnabled(headless: true))
        let restored = try XCTUnwrap(app.windows.first).panes.map(\.terminal)
        XCTAssertEqual(restored.count, 3)
        let service = app.agentRequests
        XCTAssertEqual(service.resumeOffer(for: restored[0].session.id)?.conversation, Self.claude)
        XCTAssertEqual(service.resumeOffer(for: restored[1].session.id)?.conversation, other)
        XCTAssertNil(service.resumeOffer(for: restored[2].session.id))
        XCTAssertTrue(try restored[0].session.recentText().contains("conversation \(Self.claude.sessionID)"), "the pane says what it can resume")
        XCTAssertEqual(service.describeConversation(for: restored[0].session.id), "Claude Code · f9042739… (can resume)")

        var typed: [(UInt64, String)] = []
        service.typeInput = { typed.append(($0.session.id, $1)) }
        // Resume needs an idle integrated prompt under human control.
        XCTAssertThrowsError(try service.resume(in: restored[2]))
        XCTAssertThrowsError(try service.resume(in: restored[0]), "no integrated prompt yet")
        _ = try restored[0].session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let lease = try restored[0].session.acquireControl(actor: "agent")
        XCTAssertThrowsError(try service.resume(in: restored[0]), "a pane an agent controls is not typed into")
        try restored[0].session.releaseControl(lease)
        try service.resume(in: restored[0])
        XCTAssertFalse(service.canResume(restored[0]), "a started resume cannot be typed twice")
        XCTAssertThrowsError(try service.resume(in: restored[0]))
        XCTAssertEqual(typed.count, 1)
        XCTAssertEqual(typed.first?.0, restored[0].session.id)
        XCTAssertEqual(typed.first?.1, "\u{15}claude --resume f9042739-25af-4e2a-b81b-ea40affd269b\r", "exactly this pane's conversation, by ID, on a cleared line")
        XCTAssertEqual(service.describeConversation(for: restored[0].session.id), "Claude Code · f9042739… (resuming…)")
        // The agent reporting the same ID in this pane confirms the resume; ending it later shows it ended.
        service.report(agent: "claude-code", event: "session_start", sessionID: Self.claude.sessionID, in: restored[0])
        XCTAssertEqual(service.resumeOffer(for: restored[0].session.id)?.state, AgentRequests.ResumeState.resumed)
        XCTAssertEqual(service.describeConversation(for: restored[0].session.id), "Claude Code · f9042739… (resumed)")
        service.report(agent: "claude-code", event: "session_end", sessionID: Self.claude.sessionID, in: restored[0])
        XCTAssertEqual(service.describeConversation(for: restored[0].session.id), "Claude Code · f9042739… (ended)")

        // A new conversation in the second pane replaces its offer instead of being taken for the old one.
        service.report(agent: "claude-code", event: "session_start", sessionID: "brand-new", in: restored[1])
        XCTAssertNil(service.resumeOffer(for: restored[1].session.id))
        XCTAssertEqual(service.conversation(for: restored[1])?.sessionID, "brand-new")

        // Saving again keeps the resumed conversation and the new one, by pane.
        app.saveWorkspace()
        let saved = WorkspaceStore.load(app.workspaceDefaults)?.windows.first?.tabs.first?.panes.map(\.agent?.sessionID)
        XCTAssertEqual(saved, [Self.claude.sessionID, "brand-new", nil])
    }

    @MainActor func testUnconfirmedResumeCanBeRetried() async throws {
        _ = NSApplication.shared
        let app = AkittyApplication(); app.workspaceDefaults = suite()
        defer { for window in app.windows { window.panes.forEach { $0.terminal.shutdown() }; window.window?.close() } }
        WorkspaceStore.setEnabled(true, app.workspaceDefaults)
        WorkspaceStore.save(WindowLayout(name: "Workspace", windows: [.init(tabs: [.init(panes: [.init(directory: "/tmp", agent: Self.claude)])])]), app.workspaceDefaults)
        XCTAssertTrue(try app.restoreWorkspaceIfEnabled(headless: true))
        let terminal = try XCTUnwrap(app.windows.first?.panes.first?.terminal)
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let service = app.agentRequests
        service.resumeConfirmationTimeout = 0.1
        service.typeInput = { _, _ in }
        try service.resume(in: terminal)
        try await waitUntil { service.resumeOffer(for: terminal.session.id)?.state == .unconfirmed }
        XCTAssertEqual(service.describeConversation(for: terminal.session.id), "Claude Code · f9042739… (resume not confirmed)")
        XCTAssertTrue(service.canResume(terminal))
        // Retry types the same conversation again.
        var typed: [String] = []
        service.typeInput = { typed.append($1) }
        try service.resume(in: terminal)
        XCTAssertEqual(typed, ["\u{15}claude --resume \(Self.claude.sessionID)\r"])
        // A different conversation starting instead is not taken for the chosen one, and the offer stays to retry.
        service.report(agent: "claude-code", event: "session_start", sessionID: "something-else", in: terminal)
        XCTAssertEqual(service.resumeOffer(for: terminal.session.id)?.state, AgentRequests.ResumeState.unconfirmed)
        XCTAssertTrue(service.canResume(terminal))
        service.report(agent: "claude-code", event: "session_start", sessionID: "yet-another", in: terminal)
        XCTAssertEqual(service.resumeOffer(for: terminal.session.id)?.state, AgentRequests.ResumeState.unconfirmed, "still offered after giving up")
        // A late report of the chosen conversation still confirms it.
        service.report(agent: "claude-code", event: "session_start", sessionID: Self.claude.sessionID, in: terminal)
        XCTAssertEqual(service.resumeOffer(for: terminal.session.id)?.state, AgentRequests.ResumeState.resumed)
    }
}
