import AppKit
import XCTest
@testable import AgentIPC
@testable import AkittyKit

/// Agent permission prompts answered in AkiTTY: the agent runs the tool, AkiTTY only returns the human's answer.
final class AgentDecisionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/akitty-decide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    @MainActor private func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<500 {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true")
    }

    func testSettingsInstallIsIdempotentAndRemoveKeepsUserHooks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("settings.json").path
        let original: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/audit"]]]],
                "PermissionRequest": [["matcher": "Edit", "hooks": [["type": "command", "command": "/usr/local/bin/mine"]]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: URL(fileURLWithPath: path))
        let settings = AgentHookSettings(path: path, executable: "/Applications/Akitty.app/Contents/MacOS/akitty-agent")
        XCTAssertEqual(try settings.state(), .notInstalled)
        try settings.install(); try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        let installed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permission.count, 2, "the user's group stays and AkiTTY adds exactly one")
        let ours = permission.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter { ($0["command"] as? String)?.hasSuffix(" claude-hook") == true }
        XCTAssertEqual(ours.count, 1)
        XCTAssertEqual(ours.first?["timeout"] as? Int, 150)
        XCTAssertEqual(ours.first?["command"] as? String, "'/Applications/Akitty.app/Contents/MacOS/akitty-agent' claude-hook")
        XCTAssertNotNil(hooks["SessionStart"]); XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertEqual(installed["model"] as? String, "opus")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".akitty-backup"))
        try settings.uninstall()
        XCTAssertEqual(try settings.state(), .notInstalled)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: restored), NSDictionary(dictionary: original))

        // Files and hook shapes AkiTTY would have to overwrite are never rewritten.
        for text in ["[1, 2]", "{\"hooks\": []}", "{\"hooks\": {\"PermissionRequest\": \"mine\"}}"] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try settings.install(), text)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
        }
        // A missing file is created.
        let fresh = AgentHookSettings(path: root.appendingPathComponent("new/settings.json").path, executable: "/x/akitty-agent")
        try fresh.install()
        XCTAssertEqual(try fresh.state(), .installed)
    }

    func testInstallerQuotingMatchingPartialStatePermissionsAndSymlinks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        // A path with shell metacharacters stays one literal argument.
        let odd = AgentHookSettings(path: root.appendingPathComponent("a.json").path, executable: "/Apps/It's $(x) `y`/akitty-agent")
        XCTAssertEqual(odd.command, "'/Apps/It'\\''s $(x) `y`/akitty-agent' claude-hook")
        XCTAssertTrue(odd.isManaged(["command": odd.command]))
        XCTAssertTrue(odd.isManaged(["command": "'/Applications/Akitty Old.app/Contents/MacOS/akitty-agent' claude-hook"]), "another AkiTTY bundle")
        // A user's own command that mentions akitty-agent, even in AkiTTY's exact form, is not AkiTTY's.
        for user in ["/usr/local/bin/my-akitty-agent-wrapper claude-hook", "akitty-agent claude-hook", "\"/x/akitty-agent\" claude-hook",
                     "'/opt/mytools/akitty-agent' claude-hook"] {
            XCTAssertFalse(odd.isManaged(["command": user]), user)
        }
        // One managed hook out of three is partial; uninstall removes it; uninstalling an untouched file writes nothing.
        let path = root.appendingPathComponent("settings.json").path
        let settings = AgentHookSettings(path: path, executable: "/x/Akitty.app/Contents/MacOS/akitty-agent")
        // AkiTTY's entry shares a group with the user's own hook; removing ours keeps theirs.
        let one: [String: Any] = ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": settings.command], ["type": "command", "command": "/usr/bin/mine"]]]],
                                            "Stop": [["hooks": [["type": "command", "command": "/bin/true"]]]]]]
        try JSONSerialization.data(withJSONObject: one).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try settings.state(), .partial)
        // An entry for another AkiTTY copy also counts as partial.
        let other = AgentHookSettings(path: path, executable: "/elsewhere/Akitty.app/Contents/MacOS/akitty-agent")
        XCTAssertEqual(try other.state(), .partial)
        _ = chmod(path, 0o600)
        try settings.uninstall()
        XCTAssertEqual(try settings.state(), .notInstalled)
        var info = stat(); XCTAssertEqual(stat(path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600, "a private settings file stays private")
        let kept = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let start = ((kept["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(start?.compactMap { $0["command"] as? String }, ["/usr/bin/mine"])
        let untouched = root.appendingPathComponent("untouched.json").path
        try Data("{\"model\":\"x\"}".utf8).write(to: URL(fileURLWithPath: untouched))
        try AgentHookSettings(path: untouched, executable: "/x/akitty-agent").uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched + ".akitty-backup"))
        // A symlinked settings file is written through; the backup sits beside the link, not in the link's target folder.
        let dotfiles = root.appendingPathComponent("dotfiles"); try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("settings.json"); try Data("{}".utf8).write(to: real)
        let link = root.appendingPathComponent("linked.json").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.path)
        try AgentHookSettings(path: link, executable: "/x/akitty-agent").install()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), real.path)
        XCTAssertEqual(try AgentHookSettings(path: real.path, executable: "/x/akitty-agent").state(), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link + ".akitty-backup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.path + ".akitty-backup"))
    }

    func testHookStatusDetectsAChangedPermissionMatcherAndReinstallRepairsIt() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("settings.json")
        let settings = AgentHookSettings(path: config.path, executable: "/Applications/Akitty.app/Contents/MacOS/akitty-agent")
        try settings.install()
        let original = try String(contentsOf: config, encoding: .utf8)
        let changed = original.replacingOccurrences(of: "\"matcher\" : \"Bash\"", with: "\"matcher\" : \"Edit\"")
        XCTAssertNotEqual(changed, original)
        try Data(changed.utf8).write(to: config)
        XCTAssertEqual(try settings.state(), .partial)
        try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    @MainActor private func readyPane() throws -> (TerminalView, NSWindow) {
        let terminal = try TerminalView(headless: true, forceSoftware: true)
        _ = try terminal.session.call("feed", ["text": "\u{1b}]7;file:///tmp\u{7}\u{1b}]133;A\u{7}"])
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        return (terminal, window)
    }
    private static let bash = AgentRequests.PermissionRequest(agent: "claude-code", tool: "Bash", command: "make test", cwd: "/repo", reason: nil)

    @MainActor func testDecisionQueuesWithCommandsPresentsWhileLeasedAndNeverDeniesWithoutAnAnswer() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (terminal, window) = try readyPane()
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); terminal.shutdown(); window.close() }
        // A command request at the head; the agent's prompt waits behind it and appears once it ends.
        let command = Task { @MainActor () -> Error? in
            do { _ = try await service.request("echo first", in: terminal, origin: .siri, requestID: "cmd"); return nil } catch { return error }
        }
        try await waitUntil { window.attachedSheet != nil }
        let decision = Task { @MainActor in try await service.decide(Self.bash, in: terminal, origin: .siri, requestID: "dec") }
        try await waitUntil { service.status(of: "dec")?["state"] as? String == "queued" }
        let first = try XCTUnwrap(window.attachedSheet)
        window.endSheet(first, returnCode: .alertSecondButtonReturn)
        _ = await command.value
        try await waitUntil { window.attachedSheet != nil && window.attachedSheet !== first }
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human", "a decision never takes the lease")
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let answer = try await decision.value
        XCTAssertEqual(answer["decision"] as? String, "allow")
        XCTAssertEqual(answer["akitty_sent_input"] as? Bool, false)
        // The agent's own pane may be leased to another request's approved command; a decision still appears.
        let lease = try terminal.session.acquireControl(actor: "other agent")
        let leased = Task { @MainActor in try await service.decide(Self.bash, in: terminal, origin: .siri, requestID: "leased") }
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        let leasedAnswer = try await leased.value
        XCTAssertEqual(leasedAnswer["decision"] as? String, "deny")
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "other agent")
        try terminal.session.releaseControl(lease)

        // Unanswered: expiry is not a denial, so the agent keeps its own prompt.
        service.requestTimeout = 1; service.minimumReviewTime = 0.2
        let expiring = Task { @MainActor () -> Error? in
            do { _ = try await service.decide(Self.bash, in: terminal, origin: .siri, requestID: "late"); return nil } catch { return error }
        }
        try await waitUntil { window.attachedSheet != nil }
        let expired = await expiring.value
        XCTAssertTrue(expired?.localizedDescription.contains("expired without an answer") == true, "\(String(describing: expired))")
        XCTAssertEqual(service.status(of: "late")?["state"] as? String, "expired")
        XCTAssertTrue(String(decoding: try service.store.export(), as: UTF8.self).contains("request_expired"))

        // The pane closing under the sheet is not a denial either.
        service.requestTimeout = 120
        let closing = Task { @MainActor () -> Error? in
            do { _ = try await service.decide(Self.bash, in: terminal, origin: .siri, requestID: "gone"); return nil } catch { return error }
        }
        try await waitUntil { window.attachedSheet != nil }
        terminal.shutdown()
        let gone = await closing.value
        XCTAssertNotNil(gone)
        XCTAssertNotEqual(service.status(of: "gone")?["state"] as? String, "denied")
        XCTAssertFalse(service.hasActiveRequest)
    }

    @MainActor func testOnlyAClickIsAnAnswer() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFront(nil); defer { window.close() }
        for (code, expected) in [(NSApplication.ModalResponse.alertFirstButtonReturn, AgentRequests.Answer.allow), (.alertSecondButtonReturn, .deny), (.abort, .unanswered)] {
            let alert = AgentRequests.decisionAlert(Self.bash, pane: 1)
            let pending = Task { await AgentRequests.answer(alert, in: window, timeout: 30) }
            try await waitUntil { window.attachedSheet != nil }
            window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: code)
            let answer = await pending.value
            XCTAssertEqual(answer, expected)
            try await waitUntil { window.attachedSheet == nil }
        }
        // AkiTTY's own dismissals (timeout, a caller that went away) are never a Deny.
        let timed = await AgentRequests.answer(AgentRequests.decisionAlert(Self.bash, pane: 1), in: window, timeout: 0.05)
        XCTAssertEqual(timed, .unanswered)
        try await waitUntil { window.attachedSheet == nil }
        var alive = true
        let dropped = Task { await AgentRequests.answer(AgentRequests.decisionAlert(Self.bash, pane: 1), in: window, timeout: 30, valid: { alive }) }
        try await waitUntil { window.attachedSheet != nil }
        alive = false
        let droppedAnswer = await dropped.value
        XCTAssertEqual(droppedAnswer, .unanswered)
    }

    @MainActor func testDecisionPassesCommandsWaitingOnlyForTheLease() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (terminal, window) = try readyPane()
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); terminal.shutdown(); window.close() }
        // An approved command still holds the lease: the next command waits for reclaim.
        let lease = try terminal.session.acquireControl(actor: "approved earlier")
        let blocked = Task { @MainActor () -> Error? in
            do { _ = try await service.request("echo later", in: terminal, origin: .siri, requestID: "blocked"); return nil } catch { return error }
        }
        try await waitUntil { service.status(of: "blocked")?["state"] as? String == "queued" }
        let decision = Task { @MainActor in try await service.decide(Self.bash, in: terminal, origin: .siri, requestID: "agent") }
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertEqual(service.status(of: "agent")?["state"] as? String, "awaiting_approval")
        XCTAssertEqual(service.status(of: "blocked")?["state"] as? String, "queued")
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let answer = try await decision.value
        XCTAssertEqual(answer["decision"] as? String, "allow")
        // Once reclaimed, the waiting command gets its turn.
        try terminal.session.releaseControl(lease)
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertEqual(service.status(of: "blocked")?["state"] as? String, "awaiting_approval")
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        _ = await blocked.value
        XCTAssertFalse(service.hasActiveRequest)
    }

    @MainActor func testSessionEndMarksOnlyTheReportedConversation() throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (terminal, window) = try readyPane()
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        defer { service.stop(); terminal.shutdown(); window.close() }
        service.report(agent: "claude-code", event: "session_start", sessionID: "one", in: terminal)
        service.report(agent: "claude-code", event: "session_end", sessionID: "other", in: terminal)
        XCTAssertEqual(service.agentSession(for: terminal.session.id)?.ended, false, "an unrelated end does not close the shown conversation")
        service.report(agent: "claude-code", event: "session_end", sessionID: "one", in: terminal)
        let ended = try XCTUnwrap(service.agentSession(for: terminal.session.id))
        XCTAssertTrue(ended.ended)
        XCTAssertEqual(AgentOverviewRow.describe(ended), "Claude Code · one (ended)")
        var sent: [[String: Any]] = []
        let end = try JSONSerialization.data(withJSONObject: ["session_id": "one", "hook_event_name": "SessionEnd", "reason": "exit"])
        XCTAssertNil(AgentHook.respond(to: end) { data, _, _ in sent.append(try JSONSerialization.jsonObject(with: data) as! [String: Any]); return Data("{}".utf8) })
        XCTAssertEqual(sent.first?["event"] as? String, "session_end")
    }

    func testCodexUsesTheSameContractWithItsOwnFileCommandAndTimeouts() throws {
        // The same PermissionRequest maps to a decide for Codex, and the answer uses the shared output shape.
        let prompt = try JSONSerialization.data(withJSONObject: ["session_id": "01a1f59f-a4e3-7ce1-9cc8-fd0b666e313c", "hook_event_name": "PermissionRequest",
                                                                 "turn_id": "t1", "permission_mode": "default", "cwd": "/repo",
                                                                 "tool_name": "Bash", "tool_input": ["command": "cargo test", "description": "Run tests outside the sandbox"]])
        var sent: [String: Any] = [:]
        let output = AgentHook.respond(to: prompt, agent: .codex) { data, _, _ in
            sent = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: ["version": 1, "ok": true, "data": ["decision": "deny"]])
        }
        XCTAssertEqual(sent["agent"] as? String, "codex")
        XCTAssertEqual(sent["command"] as? String, "cargo test")
        XCTAssertEqual(sent["reason"] as? String, "Run tests outside the sandbox")
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(output)) as? [String: Any])
        let decision = (answer["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        // apply_patch, MCP tools, network approvals and requests with fields the sheet cannot show stay with Codex.
        let kept: [(String, [String: Any])] = [("apply_patch", ["command": "x"]), ("mcp__fs__write", ["command": "x"]),
                                               ("Bash", ["command": "curl example.com", "description": "network-access example.com"]),
                                               ("Bash", ["command": "make", "sandbox_permissions": "require_escalated"])]
        for (tool, input) in kept {
            let other = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input])
            XCTAssertNil(AgentHook.respond(to: other, agent: .codex) { _, _, _ in XCTFail("not forwarded"); return Data() }, "\(tool) \(input)")
        }
        var reported: [String: Any] = [:]
        let start = try JSONSerialization.data(withJSONObject: ["session_id": "01a1f59f", "hook_event_name": "SessionStart", "source": "resume"])
        var deadline: TimeInterval = 0
        XCTAssertNil(AgentHook.respond(to: start, agent: .codex) { data, _, timeout in deadline = timeout; reported = try JSONSerialization.jsonObject(with: data) as! [String: Any]; return Data() })
        XCTAssertLessThan(deadline, 3, "a report finishes inside Codex's 3-second SessionEnd limit")
        XCTAssertEqual(reported["agent"] as? String, "codex"); XCTAssertEqual(reported["event"] as? String, "session_start")

        // Codex's own hooks file, command and timeouts; SessionEnd stays within Codex's 3-second limit.
        XCTAssertTrue(HookAgent.codex.defaultSettingsPath.hasSuffix("/hooks.json"))
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("hooks.json").path
        try Data(#"{"description":"mine","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}"#.utf8).write(to: URL(fileURLWithPath: path))
        let codex = AgentHookSettings(agent: .codex, path: path, executable: "/Applications/Akitty.app/Contents/MacOS/akitty-agent")
        XCTAssertEqual(codex.command, "'/Applications/Akitty.app/Contents/MacOS/akitty-agent' codex-hook")
        try codex.install(); try codex.install()
        XCTAssertEqual(try codex.state(), .installed)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(written["description"] as? String, "mine")
        let hooks = try XCTUnwrap(written["hooks"] as? [String: Any])
        func timeout(_ event: String) -> Int? { (((hooks[event] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int) }
        XCTAssertEqual(timeout("SessionEnd"), 3); XCTAssertEqual(timeout("PermissionRequest"), 150)
        XCTAssertEqual((hooks["PermissionRequest"] as? [[String: Any]])?.count, 1, "installing twice keeps one copy")
        // A Claude Code entry is not Codex's, and the other way round.
        let claude = AgentHookSettings(agent: .claudeCode, path: path, executable: "/Applications/Akitty.app/Contents/MacOS/akitty-agent")
        XCTAssertFalse(claude.isManaged(["command": codex.command]))
        XCTAssertEqual(try claude.state(), .notInstalled)
        try codex.uninstall()
        let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual((cleaned["hooks"] as? [String: Any])?.keys.sorted(), ["Stop"])
    }

    @MainActor func testServiceAcceptsCodexDecisionsAndReports() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (terminal, window) = try readyPane()
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        service.cooldownInterval = 0
        defer { service.stop(); terminal.shutdown(); window.close() }
        let request = AgentRequests.PermissionRequest(agent: "codex", tool: "Bash", command: "cargo test", cwd: "/repo", reason: "Run tests outside the sandbox")
        let decision = Task { @MainActor in try await service.decide(request, in: terminal, origin: .siri, requestID: "codex-1") }
        try await waitUntil { window.attachedSheet != nil }
        let alert = try XCTUnwrap(window.attachedSheet?.contentView?.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: "\n"))
        XCTAssertTrue(alert.contains("Codex"), alert)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let answer = try await decision.value
        XCTAssertEqual(answer["executor"] as? String, "codex")
        XCTAssertEqual(answer["akitty_sent_input"] as? Bool, false)
        service.report(agent: "codex", event: "session_start", sessionID: "01a1f59f-a4e3-7ce1-9cc8-fd0b666e313c", in: terminal)
        XCTAssertEqual(service.describeConversation(for: terminal.session.id), "Codex · 01a1f59f…")
        XCTAssertEqual(service.conversation(for: terminal)?.resumeCommand, "codex resume 01a1f59f-a4e3-7ce1-9cc8-fd0b666e313c")
    }

    func testHookMapsOnlyBashPromptsAndFallsBackOnAnyFailure() throws {
        func event(_ fields: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["session_id": "abc-123", "cwd": "/repo", "hook_event_name": "PermissionRequest"].merging(fields) { $1 })
        }
        let bash = try event(["tool_name": "Bash", "tool_input": ["command": "rm -rf build\nls", "description": "Clean build output"]])
        var sent: [[String: Any]] = []
        func reply(_ text: String) -> (Data, String, TimeInterval) throws -> Data {
            { data, _, _ in sent.append(try JSONSerialization.jsonObject(with: data) as! [String: Any]); return Data(text.utf8) }
        }
        let allow = try XCTUnwrap(AgentHook.respond(to: bash, send: reply("{\"version\":1,\"ok\":true,\"data\":{\"decision\":\"allow\"}}")))
        let allowed = try XCTUnwrap(JSONSerialization.jsonObject(with: allow) as? [String: Any])
        let output = try XCTUnwrap(allowed["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((output["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        XCTAssertEqual(sent.last?["op"] as? String, "decide")
        XCTAssertEqual(sent.last?["command"] as? String, "rm -rf build\nls")
        XCTAssertEqual(sent.last?["cwd"] as? String, "/repo")
        XCTAssertEqual(sent.last?["reason"] as? String, "Clean build output")
        XCTAssertNil(sent.last?["pane"], "the pane comes from the caller's terminal, never from the hook")
        let deny = try XCTUnwrap(AgentHook.respond(to: bash, send: reply("{\"version\":1,\"ok\":true,\"data\":{\"decision\":\"deny\"}}")))
        let denied = (try JSONSerialization.jsonObject(with: deny) as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual((denied?["decision"] as? [String: Any])?["behavior"] as? String, "deny")
        // Errors, unknown answers, transport failures and other tools leave Claude Code's own prompt in place.
        XCTAssertNil(AgentHook.respond(to: bash, send: reply("{\"version\":1,\"ok\":false,\"error\":\"expired\"}")))
        XCTAssertNil(AgentHook.respond(to: bash, send: reply("{\"version\":1,\"ok\":true,\"data\":{\"decision\":\"maybe\"}}")))
        XCTAssertNil(AgentHook.respond(to: bash, send: { _, _, _ in throw AgentIPCError.failure("refused") }))
        let count = sent.count
        XCTAssertNil(AgentHook.respond(to: try event(["tool_name": "Edit", "tool_input": ["file_path": "/x"]]), send: reply("{}")))
        XCTAssertNil(AgentHook.respond(to: try event(["tool_name": "Bash", "tool_input": ["command": String(repeating: "a", count: 4097)]]), send: reply("{}")))
        XCTAssertNil(AgentHook.respond(to: Data("not json".utf8), send: reply("{}")))
        XCTAssertEqual(sent.count, count, "unsupported prompts are never sent")
        // Session events are reported and print nothing.
        let start = try JSONSerialization.data(withJSONObject: ["session_id": "abc-123", "hook_event_name": "SessionStart", "source": "startup"])
        XCTAssertNil(AgentHook.respond(to: start, send: reply("{\"version\":1,\"ok\":true,\"data\":{}}")))
        XCTAssertEqual(sent.last?["op"] as? String, "report")
        XCTAssertEqual(sent.last?["event"] as? String, "session_start")
        XCTAssertEqual(sent.last?["session_id"] as? String, "abc-123")
    }

    @MainActor func testHookInsideAPaneIsAnsweredWithoutInputAndOutsideCallersAreRefused() async throws {
        _ = NSApplication.shared
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let terminal = try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal; window.orderFront(nil)
        let path = root.appendingPathComponent("requests.sock").path
        let service = AgentRequests(source: { [terminal] }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: path)
        service.cooldownInterval = 0; try service.setEnabled(true)
        defer { service.stop(); terminal.shutdown(); window.close() }
        try await waitUntil { (try terminal.session.shellState()).tty_device != nil }
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent").path
        let start = root.appendingPathComponent("start.json"), prompt = root.appendingPathComponent("prompt.json")
        try JSONSerialization.data(withJSONObject: ["session_id": "conv-42", "hook_event_name": "SessionStart", "source": "startup"]).write(to: start)
        try JSONSerialization.data(withJSONObject: ["session_id": "conv-42", "cwd": root.path, "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": "touch '\(root.appendingPathComponent("typed-by-akitty").path)'", "description": "Create a marker"]]).write(to: prompt)
        // Run the hook the way Claude Code would: as a process inside the pane, its stdin the event.
        for (index, answer) in [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn].enumerated() {
            let out = root.appendingPathComponent("out\(index).json"), done = root.appendingPathComponent("done\(index)")
            try terminal.session.input("'\(cli)' --socket '\(path)' claude-hook < '\(start.path)'; '\(cli)' --socket '\(path)' claude-hook < '\(prompt.path)' > '\(out.path)'; : > '\(done.path)'\r", paste: false)
            try await waitUntil { window.attachedSheet != nil }
            XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human", "a decision never leases the pane")
            XCTAssertEqual(service.agentSession(for: terminal.session.id)?.sessionID, "conv-42")
            let sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertEqual(sheet.defaultButtonCell?.title, "Deny")
            window.endSheet(sheet, returnCode: answer)
            try await waitUntil { FileManager.default.fileExists(atPath: done.path) }
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
            let decision = ((reply["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String
            XCTAssertEqual(decision, index == 0 ? "allow" : "deny")
        }
        XCTAssertEqual(try terminal.session.snapshot()?.control?.owner, "human")
        // If AkiTTY had typed the agent's command, the pane's shell would have run it once the hook exited.
        try terminal.session.input("sleep 0.3; : > '\(root.appendingPathComponent("settled").path)'\r", paste: false)
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("settled").path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("typed-by-akitty").path), "AkiTTY must not type the agent's command")
        let events = String(decoding: try service.store.export(), as: UTF8.self)
        XCTAssertTrue(events.contains("permission_allowed")); XCTAssertTrue(events.contains("permission_denied"))
        XCTAssertFalse(events.contains("typed-by-akitty"))

        // Codex starts hooks in a new session, without a terminal: the pane is found through the agent that started it.
        let codexPrompt = root.appendingPathComponent("codex.json"), codexOut = root.appendingPathComponent("codex-out.json"), codexDone = root.appendingPathComponent("codex-done")
        try JSONSerialization.data(withJSONObject: ["session_id": "01a1f59f", "cwd": root.path, "hook_event_name": "PermissionRequest", "turn_id": "t",
            "tool_name": "Bash", "tool_input": ["command": "make check", "description": "Run checks"]]).write(to: codexPrompt)
        let detached = "import os,sys\npid=os.fork()\nif pid==0:\n os.setsid()\n fd=os.open(sys.argv[2],os.O_RDONLY); os.dup2(fd,0)\n out=os.open(sys.argv[3],os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); os.dup2(out,1)\n os.execv(sys.argv[1],[sys.argv[1],'--socket',sys.argv[4],'codex-hook'])\nos.waitpid(pid,0)"
        try detached.write(to: root.appendingPathComponent("detach.py"), atomically: true, encoding: .utf8)
        try terminal.session.input("/usr/bin/python3 '\(root.appendingPathComponent("detach.py").path)' '\(cli)' '\(codexPrompt.path)' '\(codexOut.path)' '\(path)'; : > '\(codexDone.path)'\r", paste: false)
        try await waitUntil { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await waitUntil { FileManager.default.fileExists(atPath: codexDone.path) }
        let codexReply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: codexOut)) as? [String: Any])
        XCTAssertEqual(((codexReply["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String, "deny")

        // This test process does not run inside the pane, so it cannot ask on the pane's behalf.
        let outside = try JSONSerialization.data(withJSONObject: ["version": 1, "op": "decide", "agent": "claude-code", "tool": "Bash", "command": "echo x"])
        let refused = try await Task.detached { try LocalSocket.request(outside, path: path) }.value
        XCTAssertTrue(String(decoding: refused, as: UTF8.self).contains("not running inside an AkiTTY pane"))
        XCTAssertNil(window.attachedSheet)
        for bad: [String: Any] in [["version": 1, "op": "decide", "agent": "other", "tool": "Bash", "command": "x"],
                                   ["version": 1, "op": "decide", "agent": "grok", "tool": "Bash", "command": "x"],
                                   ["version": 1, "op": "decide", "agent": "muse", "tool": "Bash", "command": "x"],
                                   ["version": 1, "op": "decide", "agent": "kimi", "tool": "Bash", "command": "x"],
                                   ["version": 1, "op": "decide", "agent": "agy", "tool": "Bash", "command": "x"],
                                   ["version": 1, "op": "decide", "agent": "claude-code", "tool": "Edit", "command": "x"],
                                   ["version": 1, "op": "decide", "agent": "claude-code", "tool": "Bash", "command": "x", "pane": "p"],
                                   ["version": 1, "op": "report", "agent": "claude-code", "event": "session_start", "session_id": "bad id"],
                                   ["version": 1, "op": "report", "agent": "ax-code", "event": "session_start", "session_id": "one", "reporter_id": UUID().uuidString],
                                   ["version": 1, "op": "report", "agent": "ax-code", "event": "session_start", "session_id": "one", "reporter_id": UUID().uuidString, "reporter_sequence": "0"]] {
            let data = try JSONSerialization.data(withJSONObject: bad)
            let reply = try JSONSerialization.jsonObject(with: try await Task.detached { try LocalSocket.request(data, path: path) }.value) as? [String: Any]
            XCTAssertEqual(reply?["ok"] as? Bool, false, "\(bad)")
        }
    }

    @MainActor func testDecisionCommandsMayWrapButNotHideText() {
        XCTAssertNoThrow(try AgentRequests.validateDecisionCommand("for f in *; do\n\techo \"$f\"\ndone"))
        for bad in ["", "  \n", "echo \u{1b}[31m", "echo \u{202e}x", "echo \u{200b}", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try AgentRequests.validateDecisionCommand(bad), bad)
        }
    }

    @MainActor func testOverviewShowsReportedAgentSession() {
        let row = AgentOverviewRow(sessionID: 1, snapshot: nil, agentSession: AgentOverviewRow.describe(.init(agent: "claude-code", sessionID: "0f3a9c21-77", ended: false, reported: Date())))
        XCTAssertEqual(row.agentSession, "Claude Code · 0f3a9c21…")
        XCTAssertEqual(AgentOverviewRow(sessionID: 1, snapshot: nil).agentSession, "—")
    }
}
