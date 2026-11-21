import XCTest
@testable import AgentIPC
@testable import AkittyKit

final class AgentMCPSettingsTests: XCTestCase {
    private let companion = "/Applications/Akitty.app/Contents/MacOS/akitty-agent"

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/akitty-mcp-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func report(_ agent: SessionHookAgent, _ event: [String: Any]) throws -> [String: Any] {
        var sent: [String: Any] = [:]
        let output = SessionHook.respond(to: try JSONSerialization.data(withJSONObject: event), agent: agent) { data, _, timeout in
            XCTAssertLessThan(timeout, 2)
            sent = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return Data("{}".utf8)
        }
        XCTAssertNil(output)
        return sent
    }

    func testGrokInstallPreservesNativeConfigAndNeverReportsGrokAsClaude() throws {
        let root = try directory(), config = root.appendingPathComponent("config.toml"), hooks = root.appendingPathComponent("hooks/akitty.json")
        try write("# keep this comment\n[ui]\ntheme = \"dark\"\n", config)
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}"#, hooks)
        let settings = GrokMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        try settings.install(); try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        let configText = try text(config)
        XCTAssertTrue(configText.contains("# keep this comment")); XCTAssertTrue(configText.contains("theme = \"dark\""))
        XCTAssertEqual(configText.components(separatedBy: "[mcp_servers.akitty]").count - 1, 1)
        XCTAssertTrue(configText.contains("tool_timeout_sec = 150"))
        let hookObject = try object(hooks), hookEvents = try XCTUnwrap(hookObject["hooks"] as? [String: Any])
        XCTAssertNotNil(hookEvents["Stop"]); XCTAssertNotNil(hookEvents["SessionStart"]); XCTAssertNotNil(hookEvents["SessionEnd"])
        XCTAssertTrue(configText.contains("grok-hook") == false, "the MCP table and lifecycle hook stay in their own files")

        // Grok also discovers Claude-compatible settings. Its extra fields must prevent a Claude identity/resume mixup.
        var reported: [String: Any] = [:]
        let event: [String: Any] = ["hook_event_name": "SessionStart", "hookEventName": "session_start",
                                    "session_id": "grok-123", "sessionId": "grok-123", "workspaceRoot": "/repo"]
        _ = AgentHook.respond(to: try JSONSerialization.data(withJSONObject: event), agent: .claudeCode) { data, _, _ in
            reported = try JSONSerialization.jsonObject(with: data) as! [String: Any]; return Data("{}".utf8)
        }
        XCTAssertEqual(reported["agent"] as? String, "grok")
        XCTAssertEqual(AgentConversation(agent: "grok", sessionID: "grok-123", reported: 0).resumeCommand, "grok --resume grok-123")

        try settings.uninstall()
        let cleaned = try text(config)
        XCTAssertTrue(cleaned.contains("# keep this comment")); XCTAssertFalse(cleaned.contains("mcp_servers.akitty"))
        let remaining = try XCTUnwrap(try object(hooks)["hooks"] as? [String: Any])
        XCTAssertEqual(remaining.keys.sorted(), ["Stop"])
    }

    func testGrokRefusesAUserOwnedServerWithoutChangingIt() throws {
        let root = try directory(), config = root.appendingPathComponent("config.toml"), hooks = root.appendingPathComponent("hooks/akitty.json")
        let original = "[mcp_servers.\"akitty\"]\ncommand = \"/mine\"\n"
        try write(original, config)
        let settings = GrokMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        XCTAssertEqual(try settings.state(), .conflict)
        XCTAssertThrowsError(try settings.install())
        XCTAssertEqual(try text(config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path))
    }

    func testGrokReinstallRefusesAnAdditionalUserServerTable() throws {
        let root = try directory(), config = root.appendingPathComponent("config.toml"), hooks = root.appendingPathComponent("hooks/akitty.json")
        let settings = GrokMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        try settings.install()
        let installed = try text(config)
        try write(installed + "\n[mcp_servers.'akitty']\ncommand = \"/mine\"\n", config)
        XCTAssertEqual(try settings.state(), .conflict)
        XCTAssertThrowsError(try settings.install())
        XCTAssertTrue(try text(config).contains("command = \"/mine\""))
    }

    func testMuseInstallUsesCanonicalMCPAndLifecycleSettings() throws {
        let root = try directory(), config = root.appendingPathComponent("settings.json")
        try write(#"{"schema_version":1,"model":"mine","mcpServers":{"other":{"command":"/other"}},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}"#, config)
        let settings = MuseMCPSettings(path: config.path, executable: companion)
        try settings.install(); try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        let written = try object(config), servers = try XCTUnwrap(written["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["akitty"] as? [String: Any])
        XCTAssertEqual(server["type"] as? String, "stdio"); XCTAssertEqual(server["framing"] as? String, "line_delimited_json")
        XCTAssertEqual(server["tool_timeout_sec"] as? Int, 150); XCTAssertEqual(server["required"] as? Bool, false)
        XCTAssertNotNil(servers["other"]); XCTAssertEqual(written["model"] as? String, "mine")
        let hooks = try XCTUnwrap(written["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"]); XCTAssertNotNil(hooks["SessionStart"]); XCTAssertNotNil(hooks["SessionEnd"])
        let sent = try report(.muse, ["hook_event_name": "SessionStart", "session_id": "muse-123"])
        XCTAssertEqual(sent["agent"] as? String, "muse"); XCTAssertEqual(sent["event"] as? String, "session_start")
        XCTAssertEqual(AgentConversation(agent: "muse", sessionID: "muse-123", reported: 0).resumeCommand, "muse resume muse-123")

        try settings.uninstall()
        let cleaned = try object(config), remainingServers = try XCTUnwrap(cleaned["mcpServers"] as? [String: Any])
        XCTAssertNil(remainingServers["akitty"]); XCTAssertNotNil(remainingServers["other"])
        let remainingHooks = try XCTUnwrap(cleaned["hooks"] as? [String: Any])
        XCTAssertEqual(remainingHooks.keys.sorted(), ["Stop"]); XCTAssertEqual(cleaned["schema_version"] as? Int, 1)
    }

    func testMuseRefusesSettingsWithoutItsRequiredSchemaVersion() throws {
        let root = try directory(), config = root.appendingPathComponent("settings.json")
        try write(#"{"model":"mine"}"#, config)
        let settings = MuseMCPSettings(path: config.path, executable: companion)
        XCTAssertThrowsError(try settings.install())
        XCTAssertEqual(try text(config), #"{"model":"mine"}"#)
    }

    func testKimiInstallPreservesJSONAndTOMLAndSetsApprovalTimeout() throws {
        let root = try directory(), config = root.appendingPathComponent("mcp.json"), hooks = root.appendingPathComponent("config.toml")
        try write(#"{"other":true,"mcpServers":{"mine":{"command":"/mine"}}}"#, config)
        try write("# keep comments\n[workspace]\nrequire_trust = true\n", hooks)
        let settings = KimiMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        try settings.install(); try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        let written = try object(config), servers = try XCTUnwrap(written["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["akitty"] as? [String: Any])
        XCTAssertEqual(server["toolTimeoutMs"] as? Int, 150_000); XCTAssertNotNil(servers["mine"])
        let hookText = try text(hooks)
        XCTAssertTrue(hookText.contains("# keep comments")); XCTAssertTrue(hookText.contains("require_trust = true"))
        XCTAssertEqual(hookText.components(separatedBy: "event = \"SessionStart\"").count - 1, 1)
        XCTAssertEqual(hookText.components(separatedBy: "event = \"SessionEnd\"").count - 1, 1)
        XCTAssertTrue(hookText.contains("kimi-hook"))
        let sent = try report(.kimi, ["hook_event_name": "SessionEnd", "session_id": "kimi-123"])
        XCTAssertEqual(sent["agent"] as? String, "kimi"); XCTAssertEqual(sent["event"] as? String, "session_end")
        XCTAssertEqual(AgentConversation(agent: "kimi", sessionID: "kimi-123", reported: 0).resumeCommand, "kimi --session kimi-123")

        try settings.uninstall()
        XCTAssertNil((try object(config)["mcpServers"] as? [String: Any])?["akitty"])
        let cleaned = try text(hooks)
        XCTAssertTrue(cleaned.contains("# keep comments")); XCTAssertFalse(cleaned.contains("AkiTTY")); XCTAssertFalse(cleaned.contains("kimi-hook"))
    }

    func testKimiRefusesAUserOwnedServer() throws {
        let root = try directory(), config = root.appendingPathComponent("mcp.json"), hooks = root.appendingPathComponent("config.toml")
        let original = #"{"mcpServers":{"akitty":{"command":"/mine","args":["mcp"]}}}"#
        try write(original, config)
        let settings = KimiMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        XCTAssertEqual(try settings.state(), .conflict)
        XCTAssertThrowsError(try settings.install()); XCTAssertEqual(try text(config), original)
    }

    func testAGYInstallMapsConversationIDWithoutInventingSessionEnd() throws {
        let root = try directory(), config = root.appendingPathComponent("mcp_config.json"), hooks = root.appendingPathComponent("hooks.json")
        try write(#"{"mcpServers":{"mine":{"command":"/mine"}}}"#, config)
        try write(#"{"mine":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}"#, hooks)
        let settings = AGYMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        try settings.install(); try settings.install()
        XCTAssertEqual(try settings.state(), .installed)
        let written = try object(config), servers = try XCTUnwrap(written["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["akitty"] as? [String: Any])?["disabled"] as? Bool, false); XCTAssertNotNil(servers["mine"])
        let hookObject = try object(hooks), agy = try XCTUnwrap(hookObject["akitty"] as? [String: Any])
        XCTAssertNotNil(agy["SessionStart"]); XCTAssertNil(agy["SessionEnd"]); XCTAssertNotNil(hookObject["mine"])
        let sent = try report(.agy, ["conversationId": "agy-123", "workspacePaths": ["/repo"]])
        XCTAssertEqual(sent["agent"] as? String, "agy"); XCTAssertEqual(sent["event"] as? String, "session_start")
        XCTAssertEqual(AgentConversation(agent: "agy", sessionID: "agy-123", reported: 0).resumeCommand, "agy --conversation agy-123")
        let stop = try report(.agy, ["conversationId": "agy-123", "terminationReason": "model_stop", "fullyIdle": true])
        XCTAssertTrue(stop.isEmpty, "AGY Stop is a turn boundary, not SessionEnd")
        let invocation = try report(.agy, ["conversationId": "agy-123", "invocationNum": 1])
        XCTAssertTrue(invocation.isEmpty, "AGY model invocation is not SessionStart")

        try settings.uninstall()
        XCTAssertNil((try object(config)["mcpServers"] as? [String: Any])?["akitty"])
        let remaining = try object(hooks); XCTAssertNil(remaining["akitty"]); XCTAssertNotNil(remaining["mine"])
    }

    func testNativeGrokReportsAndCompatibilityPermissionStaysWithGrok() throws {
        let start = try report(.grok, ["hook_event_name": "SessionStart", "hookEventName": "session_start",
                                      "session_id": "grok-native", "sessionId": "grok-native", "workspaceRoot": "/repo"])
        XCTAssertEqual(start["agent"] as? String, "grok"); XCTAssertEqual(start["event"] as? String, "session_start")
        let end = try report(.grok, ["hook_event_name": "SessionEnd", "sessionId": "grok-native", "workspaceRoot": "/repo"])
        XCTAssertEqual(end["event"] as? String, "session_end", "Grok's camelCase session ID is also accepted")
        let prompt = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "hookEventName": "permission_request",
            "session_id": "grok-native", "sessionId": "grok-native", "workspaceRoot": "/repo",
            "tool_name": "Bash", "tool_input": ["command": "echo must-stay-in-grok"]])
        XCTAssertNil(AgentHook.respond(to: prompt, agent: .claudeCode) { _, _, _ in XCTFail("Grok must keep its own prompt"); return Data() })
        var claude: [String: Any] = [:]
        let claudeEvent = try JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart", "session_id": "claude-native"])
        _ = AgentHook.respond(to: claudeEvent, agent: .claudeCode) { data, _, _ in
            claude = try JSONSerialization.jsonObject(with: data) as! [String: Any]; return Data("{}".utf8)
        }
        XCTAssertEqual(claude["agent"] as? String, "claude-code")
        XCTAssertTrue(AgentHook.isGrokPayload(["hookEventName": "session_start", "session_id": "one", "sessionId": "two", "workspaceRoot": "/repo"]))
        let mismatched = try JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart", "hookEventName": "session_start",
                                                                     "session_id": "one", "sessionId": "two", "workspaceRoot": "/repo"])
        XCTAssertNil(AgentHook.respond(to: mismatched, agent: .claudeCode) { _, _, _ in XCTFail("ambiguous IDs must not be reported"); return Data() })
    }

    func testGrokConflictVariantsAreRefusedWithoutModification() throws {
        let variants = [
            "[mcp_servers.akitty] # mine\n",
            "mcp_servers.akitty.command = \"/mine\"\n",
            "[mcp_servers]\nakitty = { command = \"/mine\" }\n",
            "[mcp_servers.akitty.env]\nTOKEN = \"x\"\n",
            "\t[mcp_servers.\"akitty\"]\t# mine\n",
            "[mcp_servers.akitty]\r\ncommand = \"/mine\"\r\n",
        ]
        for (index, original) in variants.enumerated() {
            let root = try directory().appendingPathComponent("case\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appendingPathComponent("config.toml"), hooks = root.appendingPathComponent("hooks.json")
            try write(original, config)
            let settings = GrokMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
            XCTAssertEqual(try settings.state(), .conflict, original)
            XCTAssertThrowsError(try settings.install(), original)
            XCTAssertEqual(try text(config), original, original)
        }
    }

    func testMusePartialUninstallConflictAndStrictSchemaValidation() throws {
        let root = try directory(), config = root.appendingPathComponent("settings.json")
        let settings = MuseMCPSettings(path: config.path, executable: companion)
        try settings.install()
        var partial = try object(config); partial["hooks"] = nil
        try write(String(decoding: JSONSerialization.data(withJSONObject: partial), as: UTF8.self), config)
        try settings.uninstall()
        XCTAssertNil((try object(config)["mcpServers"] as? [String: Any])?["akitty"], "partial installs must remove the server even with no hooks")

        let fresh = root.appendingPathComponent("fresh.json")
        let freshSettings = MuseMCPSettings(path: fresh.path, executable: companion)
        try freshSettings.install()
        XCTAssertEqual(try freshSettings.state(), .installed)
        XCTAssertEqual(try object(fresh)["schema_version"] as? Int, 1)

        let invalid = root.appendingPathComponent("invalid.json")
        try write(#"{"schema_version":true}"#, invalid)
        XCTAssertThrowsError(try MuseMCPSettings(path: invalid.path, executable: companion).install())
        XCTAssertEqual(try text(invalid), #"{"schema_version":true}"#)
        try write(#"{"schema_version":1.5}"#, invalid)
        XCTAssertThrowsError(try MuseMCPSettings(path: invalid.path, executable: companion).install())
        XCTAssertEqual(try text(invalid), #"{"schema_version":1.5}"#)

        let conflict = root.appendingPathComponent("conflict.json")
        let original = #"{"schema_version":1,"mcpServers":{"akitty":{"command":"/mine","args":["mcp"]}}}"#
        try write(original, conflict)
        XCTAssertThrowsError(try MuseMCPSettings(path: conflict.path, executable: companion).install())
        XCTAssertEqual(try text(conflict), original)
        let end = try report(.muse, ["hook_event_name": "SessionEnd", "session_id": "muse-end"])
        XCTAssertEqual(end["event"] as? String, "session_end")
    }

    func testKimiMalformedHooksCannotPartiallyWriteAndPermissionIsIgnored() throws {
        let root = try directory(), config = root.appendingPathComponent("mcp.json"), hooks = root.appendingPathComponent("config.toml")
        let original = #"{"mcpServers":{"mine":{"command":"/mine"}}}"#
        try write(original, config)
        try write(ManagedTextBlock(name: "kimi").begin + "\n[[hooks]]\n", hooks)
        let settings = KimiMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        XCTAssertThrowsError(try settings.install())
        XCTAssertEqual(try text(config), original, "a malformed hook file must not leave a newly written MCP server")
        let permission = try report(.kimi, ["hook_event_name": "PermissionRequest", "session_id": "kimi-no-decision",
                                           "tool_name": "Bash", "tool_input": ["command": "echo no"]])
        XCTAssertTrue(permission.isEmpty, "Kimi PermissionRequest is observation-only")
        let start = try report(.kimi, ["hook_event_name": "SessionStart", "session_id": "kimi-start"])
        XCTAssertEqual(start["event"] as? String, "session_start")
    }

    func testAGYConflictAndToolPayloadsAreSafe() throws {
        let root = try directory(), config = root.appendingPathComponent("mcp_config.json"), hooks = root.appendingPathComponent("hooks.json")
        let originalServer = #"{"mcpServers":{"akitty":{"command":"/mine","args":["mcp"]}}}"#
        try write(originalServer, config)
        try write("{}", hooks)
        let settings = AGYMCPSettings(path: config.path, hooksPath: hooks.path, executable: companion)
        XCTAssertEqual(try settings.state(), .conflict)
        XCTAssertThrowsError(try settings.install())
        XCTAssertEqual(try text(config), originalServer); XCTAssertEqual(try text(hooks), "{}")

        try write("{}", config)
        let originalHook = #"{"akitty":{"SessionStart":[]}}"#
        try write(originalHook, hooks)
        XCTAssertEqual(try settings.state(), .conflict)
        XCTAssertThrowsError(try settings.install())
        XCTAssertEqual(try text(config), "{}"); XCTAssertEqual(try text(hooks), originalHook)

        let tool = try report(.agy, ["conversationId": "agy-tool", "toolCall": ["name": "run_command"]])
        XCTAssertTrue(tool.isEmpty)
        let nullable = try report(.agy, ["conversationId": "agy-start", "toolCall": NSNull(), "terminationReason": NSNull()])
        XCTAssertEqual(nullable["event"] as? String, "session_start", "JSON null has no event discriminator")
    }

    func testManagedTextBlockRejectsMalformedMarkersAndPreservesOtherFormatting() throws {
        let marker = ManagedTextBlock(name: "test")
        let original = "# first\n\n\n[value]\nx = 1"
        let installed = try marker.installing("a = 2", into: original)
        XCTAssertTrue(installed.contains("# first\n\n\n[value]"))
        let replaced = try marker.installing("a = 3", into: installed)
        XCTAssertTrue(replaced.contains("a = 3")); XCTAssertFalse(replaced.contains("a = 2"))
        let removed = try marker.removing(from: replaced)
        XCTAssertFalse(removed.contains("AkiTTY")); XCTAssertTrue(removed.contains("# first\n\n\n[value]"))
        XCTAssertThrowsError(try marker.body(in: marker.begin + "\na = 1\n"))
        XCTAssertThrowsError(try marker.installing("x = 1", into: marker.begin + "\n" + marker.begin + "\n" + marker.end + "\n" + marker.end))
    }
}
