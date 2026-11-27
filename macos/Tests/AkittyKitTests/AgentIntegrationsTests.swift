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
        XCTAssertTrue(path.contains("/tmp/home-for-test/.kimi-code/bin")); XCTAssertTrue(path.contains("/tmp/home-for-test/.grok/bin"))
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
        XCTAssertNotNil(byID["ax-code"]?.unavailableReason, "AX Code's own approval prompts stay in AX Code")
        XCTAssertTrue(byID["codex"]?.capabilities.allSatisfy(\.available) == true)
        // AX Code connects through AkiTTY's MCP server and its plugin: command requests, reports and resume.
        XCTAssertEqual(byID["ax-code"]?.usesMCP, true)
        XCTAssertEqual(byID["ax-code"]?.capabilities.map(\.available), [true, true, true])
        for id in ["grok", "muse", "kimi", "agy"] {
            XCTAssertEqual(byID[id]?.usesMCP, true, id)
            XCTAssertNil(byID[id]?.hooks, id)
            XCTAssertEqual(byID[id]?.capabilities.map(\.available), [true, true, true], id)
            XCTAssertNotNil(byID[id]?.unavailableReason, "the client's own approval prompts stay visible")
        }
        XCTAssertEqual(Set(AgentCLI.all.map(\.id)), ["claude-code", "codex", "ax-code", "grok", "muse", "kimi", "agy"])
        // Every agent the service accepts has a row, and every row with an integration is an accepted agent.
        XCTAssertEqual(Set(AgentRequests.agentNames.keys), Set(AgentCLI.all.filter { $0.hooks != nil || $0.usesMCP }.map(\.id)))
        XCTAssertFalse(AgentRequestsLaunchSetting.isOn(UserDefaults(suiteName: "akitty-empty-\(UUID().uuidString)")!), "off by default")
    }

    func testAXCodeMCPServerIsAddedOnlyToThePlainJSONConfigAndNeverReplacesAPersonsServer() throws {
        let root = try directory()
        let path = root.appendingPathComponent("ax-code/ax-code.json").path
        let settings = AXCodeMCPSettings(path: path, executable: "/Applications/Akitty.app/Contents/MacOS/akitty-agent")
        XCTAssertEqual(try settings.state(), .notInstalled)
        try FileManager.default.createDirectory(atPath: root.appendingPathComponent("ax-code").path, withIntermediateDirectories: true)
        try Data(#"{"model":"x","mcp":{"mine":{"type":"remote","url":"https://example.com/mcp"}}}"#.utf8).write(to: URL(fileURLWithPath: path))
        try settings.install(); try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(written["model"] as? String, "x")
        let servers = try XCTUnwrap(written["mcp"] as? [String: Any])
        XCTAssertEqual(servers.keys.sorted(), ["akitty", "mine"])
        XCTAssertEqual((servers["akitty"] as? [String: Any])?["command"] as? [String], ["/Applications/Akitty.app/Contents/MacOS/akitty-agent", "mcp"])
        // The conversation report plugin sits next to the config and starts this companion.
        XCTAssertEqual(settings.pluginPath, root.appendingPathComponent("ax-code/plugin/akitty.js").path)
        let plugin = try String(contentsOfFile: settings.pluginPath, encoding: .utf8)
        XCTAssertTrue(plugin.hasPrefix(AXCodeMCPSettings.pluginMarker))
        XCTAssertTrue(plugin.contains(#"const [companion] = ["/Applications/Akitty.app/Contents/MacOS/akitty-agent"];"#), plugin)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: settings.pluginPath)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for banned in ["eval(", "fetch(", "require("] { XCTAssertFalse(plugin.contains(banned), banned) }
        // Another AkiTTY copy's entry is partial and repaired by installing.
        XCTAssertEqual(try AXCodeMCPSettings(path: path, executable: "/Other/Akitty.app/Contents/MacOS/akitty-agent").state(), .partial)
        try settings.uninstall()
        let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual((cleaned["mcp"] as? [String: Any])?.keys.sorted(), ["mine"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.pluginPath), "uninstall removes AkiTTY's plugin")
        // A plugin/akitty.js the person wrote is never replaced or removed, and nothing else is written either.
        try Data("export const Mine = async () => ({});\n".utf8).write(to: URL(fileURLWithPath: settings.pluginPath))
        XCTAssertEqual(try settings.state(), .conflict)
        XCTAssertThrowsError(try settings.install())
        try settings.uninstall()
        XCTAssertEqual(try String(contentsOfFile: settings.pluginPath, encoding: .utf8), "export const Mine = async () => ({});\n")
        XCTAssertNil((try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])?["mcp"].flatMap { ($0 as? [String: Any])?["akitty"] })
        try FileManager.default.removeItem(atPath: settings.pluginPath)
        // A server the person named "akitty" themselves is never replaced or removed.
        let own = #"{"mcp":{"akitty":{"type":"local","command":["/usr/local/bin/akitty-agent","mcp"]}}}"#
        try Data(own.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try settings.install())
        try settings.uninstall()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), own)
        XCTAssertEqual(try settings.state(), .conflict)
        // An "mcp" that is not an object is refused rather than overwritten.
        try Data(#"{"mcp":[1]}"#.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try settings.install())
        XCTAssertTrue(AXCodeMCPSettings.defaultPath.hasSuffix("/ax-code/ax-code.json"))
        // ax-code.json linked to the commented file, or to a missing file, is never written.
        let commented = root.appendingPathComponent("ax-code/ax-code.jsonc")
        try Data("{\n  // mine\n}\n".utf8).write(to: commented)
        let linked = root.appendingPathComponent("ax-code/linked.json").path
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: commented.path)
        XCTAssertThrowsError(try AXCodeMCPSettings(path: linked, executable: settings.executable).install())
        XCTAssertEqual(try String(contentsOf: commented, encoding: .utf8), "{\n  // mine\n}\n")
        let dangling = root.appendingPathComponent("ax-code/dangling.json").path
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: root.appendingPathComponent("missing.json").path)
        XCTAssertThrowsError(try AXCodeMCPSettings(path: dangling, executable: settings.executable).install())
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: dangling), "the link stays a link")
    }

    func testAXCodeUninstallKeepsThePluginWhenItsConfigCannotBeRead() throws {
        let root = try directory()
        let config = root.appendingPathComponent("ax-code.json")
        let settings = AXCodeMCPSettings(path: config.path, executable: "/Applications/Akitty.app/Contents/MacOS/akitty-agent")
        try settings.install()
        let plugin = URL(fileURLWithPath: settings.pluginPath)
        let installed = try Data(contentsOf: plugin)
        let invalid = Data("{\"mcp\": []}".utf8)
        try invalid.write(to: config)
        XCTAssertThrowsError(try settings.uninstall())
        XCTAssertEqual(try Data(contentsOf: config), invalid)
        XCTAssertEqual(try Data(contentsOf: plugin), installed)
    }

    func testAXCodePluginSequencesReportsAcrossDeletionExitAndReload() throws {
        guard let node = AgentCLI.locate("node", in: AgentCLI.searchPath()) else {
            throw XCTSkip("Node is needed to load the AX Code plugin")
        }
        let root = try directory()
        let settings = AXCodeMCPSettings(path: root.appendingPathComponent("ax-code/ax-code.json").path, executable: "/unused")
        let plugin = root.appendingPathComponent("akitty.js")
        let driver = root.appendingPathComponent("drive.mjs")
        try Data("""
        const { AkittyConversationReport } = await import(process.argv[2]);
        let dispose;
        const lifecycle = { onDispose(callback) { dispose = callback; return () => {}; } };
        const hooks = await AkittyConversationReport(["dispose", "owner"].includes(process.argv[3]) ? { lifecycle } : undefined);
        let send = (type, properties) => hooks.event({ event: { type, properties } });
        if (process.argv[3] === "blocked-child") {
          await send("session.created", { info: { id: "ses_parent" } });
          await send("session.status", { sessionID: "ses_parent", status: { type: "busy" } });
          await send("session.created", { info: { id: "ses_child", parentID: "ses_parent" } });
          const childBusy = send("session.status", { sessionID: "ses_child", status: { type: "busy" } });
          await send("session.status", { sessionID: "ses_parent", status: { type: "idle" } });
          await childBusy;
          await send("session.created", { info: { id: "ses_root" } });
          await send("session.deleted", { info: { id: "ses_root" } });
        } else {
        if (process.argv[3] === "fork") {
          await send("session.created", { info: { id: "ses_old", parentID: "ses_parent" } });
          await send("session.status", { sessionID: "ses_old", status: { type: "busy" } });
          await send("session.status", { sessionID: "ses_old", status: { type: "idle" } });
        } else await send("session.created", { info: { id: "ses_old" } });
        if (process.argv[3] === "restart") await new Promise((resolve) => setTimeout(resolve, 500));
        if (process.argv[3] === "reload" || process.argv[3] === "owner") {
          const replacement = await AkittyConversationReport();
          send = (type, properties) => replacement.event({ event: { type, properties } });
          if (process.argv[3] === "owner") {
            await send("session.created", { info: { id: "ses_old" } });
            dispose();
          } else await send("session.deleted", { info: { id: "ses_old" } });
        }
        await send("session.created", { info: { id: "ses_new" } });
        if (process.argv[3] === "fork") {
          await send("session.status", { sessionID: "ses_new", status: { type: "busy" } });
          await send("session.created", { info: { id: "ses_child", parentID: "ses_new" } });
          await send("session.status", { sessionID: "ses_child", status: { type: "busy" } });
        }
        if (process.argv[3] === "exit") process.exit(0);
        if (process.argv[3] === "dispose") dispose();
        await send("session.deleted", { info: { id: "ses_new" } });
        }
        await new Promise((resolve) => setTimeout(resolve, 1000));

        """.utf8).write(to: driver)
        for mode in ["delete", "exit", "reload", "fork", "dispose", "owner", "retry", "blocked-child", "restart"] {
            let log = root.appendingPathComponent("reports-\(mode)")
            let companion = try script("akitty-agent-\(mode)", in: root, body: """
            if [ "$1" = "ax-code-reporter" ]; then
              attempts=0
              if [ -f '\(root.appendingPathComponent("registration-count-\(mode)").path)' ]; then IFS= read -r attempts < '\(root.appendingPathComponent("registration-count-\(mode)").path)'; fi
              attempts=$((attempts + 1))
              printf '%s' "$attempts" > '\(root.appendingPathComponent("registration-count-\(mode)").path)'
              if { [ "\(mode)" = "retry" ] && [ "$attempts" -eq 1 ]; } || { [ "\(mode)" = "blocked-child" ] && [ "$attempts" -le 4 ]; }; then
                printf '{"version":1,"ok":false}\\n'; exit 0
              fi
              printf '{"version":1,"ok":true,"data":{"epoch":"1"}}\\n'; exit 0
            fi
            printf '%s %s %s %s %s\\n' "$2" "$3" "$4" "$5" "$6" >> '\(log.path)'
            if [ "$3" = "ses_old" ]; then sleep 0.3; fi
            if [ "\(mode)" = "restart" ] && [ "$3" = "ses_old" ]; then printf '{"version":1,"ok":false}\\n'; else printf '{"version":1,"ok":true}\\n'; fi
            """)
            let settings = AXCodeMCPSettings(path: settings.path, executable: companion)
            try Data(settings.pluginSource.utf8).write(to: plugin)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [driver.path, plugin.absoluteString, mode]
            try process.run()
            let exitDeadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { process.terminate(); XCTFail("AX Code plugin did not exit in mode \(mode)") }
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, mode)
            let expected: Set<String>
            if mode == "reload" { expected = ["start ses_old 1", "end ses_old 2", "start ses_new 3", "end ses_new 4"] }
            else if mode == "blocked-child" { expected = ["start ses_root 1", "end ses_root 2"] }
            else { expected = ["start ses_old 1", "start ses_new 2", "end ses_new 3"] }
            var reports: [String] = []
            let deadline = Date().addingTimeInterval(5)
            repeat {
                reports = (try? String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)) ?? []
                if reports.count == expected.count { break }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < deadline
            let fields = reports.map { $0.split(separator: " ").map(String.init) }
            guard fields.allSatisfy({ $0.count == 5 }) else { XCTFail("Malformed reports in mode \(mode): \(reports)"); return }
            XCTAssertEqual(Set(fields.map { [$0[0], $0[1], $0[3]].joined(separator: " ") }), expected, mode)
            XCTAssertEqual(fields.map { $0[3] }.sorted(), (1...expected.count).map(String.init), mode)
            let reporters = Set(fields.map { $0[2] })
            XCTAssertTrue(reporters.count == 1 && reporters.first.flatMap({ UUID(uuidString: $0) }) != nil, mode)
            let epochs = Set(fields.map { $0[4] })
            XCTAssertTrue(epochs.count == 1 && (epochs.first.flatMap { UInt64($0) } ?? 0) > 0, mode)
            if mode == "restart" {
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("registration-count-restart"), encoding: .utf8), "2")
            }
        }
    }

    @MainActor func testSequencedAgentReportsRejectLateStartsAndOldReporterEnds() throws {
        _ = NSApplication.shared
        let root = try directory()
        let panes = try (0..<2).map { _ in try TerminalView(headless: true, forceSoftware: true) }
        let service = AgentRequests(source: { panes }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: root.appendingPathComponent("s.sock").path)
        defer { service.stop(); panes.forEach { $0.shutdown() } }
        let old = UUID().uuidString, replacement = UUID().uuidString, missing = UUID().uuidString
        let pane = panes[0]
        XCTAssertEqual(try service.beginAXCodeReport(reporter: old, in: pane), "1")
        XCTAssertEqual(try service.beginAXCodeReport(reporter: replacement, in: pane), "2")
        XCTAssertEqual(try service.beginAXCodeReport(reporter: old, in: pane), "1", "registration retries return the same epoch")
        service.report(agent: "ax-code", event: "session_start", sessionID: "old", in: pane, reporter: (old, 1, 1))
        service.report(agent: "ax-code", event: "session_start", sessionID: "new", in: pane, reporter: (old, 3, 1))
        service.report(agent: "ax-code", event: "session_end", sessionID: "new", in: pane, reporter: (old, 4, 1))
        service.report(agent: "ax-code", event: "session_start", sessionID: "old", in: pane, reporter: (old, 2, 1))
        XCTAssertEqual(service.agentSessions[pane.session.id]?.sessionID, "new")
        XCTAssertEqual(service.agentSessions[pane.session.id]?.ended, true, "the delayed start must not reopen the old conversation")

        service.report(agent: "ax-code", event: "session_start", sessionID: "new", in: pane, reporter: (replacement, 1, 2))
        service.report(agent: "ax-code", event: "session_end", sessionID: "new", in: pane, reporter: (old, 5, 1))
        XCTAssertEqual(service.agentSessions[pane.session.id]?.ended, false, "an old process cannot end a conversation resumed by a new one")
        service.report(agent: "ax-code", event: "session_start", sessionID: "stale", in: pane, reporter: (old, 6, 1))
        XCTAssertEqual(service.agentSessions[pane.session.id]?.sessionID, "new", "a retired process cannot replace the new conversation")
        service.report(agent: "ax-code", event: "session_end", sessionID: "new", in: pane, reporter: (replacement, 3, 2))
        service.report(agent: "ax-code", event: "session_start", sessionID: "new", in: pane, reporter: (replacement, 2, 2))
        XCTAssertEqual(service.agentSessions[pane.session.id]?.ended, true, "a newer end wins even when an earlier start arrives later")

        for index in 0..<40 {
            service.report(agent: "ax-code", event: "session_start", sessionID: "p\(index)", in: pane, reporter: (UUID().uuidString, 1, UInt64(index + 3)))
        }
        service.report(agent: "ax-code", event: "session_start", sessionID: "evicted", in: pane, reporter: (old, 7, 1))
        service.report(agent: "ax-code", event: "session_start", sessionID: "unseen", in: pane, reporter: (UUID().uuidString, 1, 1))
        XCTAssertEqual(service.agentSessions[pane.session.id]?.sessionID, "p39", "epoch checks survive eviction and unseen old reporters")
        service.report(agent: "ax-code", event: "session_end", sessionID: "p39", in: pane)
        XCTAssertEqual(service.agentSessions[pane.session.id]?.ended, false, "a legacy end cannot close a sequenced reporter's conversation")

        let other = panes[1]
        service.report(agent: "ax-code", event: "session_start", sessionID: "previous", in: other, reporter: (old, 1, 1))
        service.report(agent: "ax-code", event: "session_end", sessionID: "previous", in: other, reporter: (old, 2, 1))
        service.offerResume(AgentConversation(agent: "ax-code", sessionID: "missing", reported: Date().timeIntervalSince1970), in: other)
        XCTAssertTrue(service.canResume(other))
        service.report(agent: "ax-code", event: "session_end", sessionID: "missing", in: other, reporter: (missing, 2, 2))
        service.report(agent: "ax-code", event: "session_start", sessionID: "missing", in: other, reporter: (missing, 1, 2))
        XCTAssertEqual(service.agentSessions[other.session.id]?.sessionID, "missing")
        XCTAssertEqual(service.agentSessions[other.session.id]?.ended, true, "a new reporter's final end wins over the previous reporter and its own lost start")
        XCTAssertFalse(service.canResume(other), "the authoritative end also confirms the resumed conversation")
        service.report(agent: "claude-code", event: "session_start", sessionID: "shared", in: other)
        service.report(agent: "ax-code", event: "session_end", sessionID: "previous", in: other, reporter: (old, 3, 1))
        XCTAssertEqual(service.agentSessions[other.session.id]?.sessionID, "shared", "a legacy start retains the epoch floor against delayed sequenced reports")
        service.report(agent: "ax-code", event: "session_end", sessionID: "shared", in: other)
        XCTAssertEqual(service.agentSessions[other.session.id]?.agent, "claude-code")
        XCTAssertEqual(service.agentSessions[other.session.id]?.ended, false, "a legacy end cannot change another agent's session")
        service.report(agent: "claude-code", event: "session_end", sessionID: "shared", in: other)
        XCTAssertEqual(service.agentSessions[other.session.id]?.ended, true)

        let unrelated = UUID().uuidString
        service.offerResume(AgentConversation(agent: "ax-code", sessionID: "chosen", reported: Date().timeIntervalSince1970), in: other)
        service.report(agent: "ax-code", event: "session_end", sessionID: "unrelated", in: other, reporter: (unrelated, 1, 3))
        XCTAssertTrue(service.canResume(other), "an unrelated end must not discard the pending resume offer")
        service.report(agent: "claude-code", event: "session_start", sessionID: "another", in: other)
        service.report(agent: "ax-code", event: "session_start", sessionID: "continued", in: other, reporter: (unrelated, 2, 3))
        XCTAssertEqual(service.agentSessions[other.session.id]?.sessionID, "continued", "the same reporter may continue after a legacy session with a newer sequence")
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
