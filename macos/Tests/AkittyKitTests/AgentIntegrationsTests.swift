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
        XCTAssertNotNil(byID["ax-code"]?.unavailableReason, "AX Code's own approval prompts stay in AX Code")
        XCTAssertTrue(byID["codex"]?.capabilities.allSatisfy(\.available) == true)
        // AX Code connects through AkiTTY's MCP server and its plugin: command requests, reports and resume.
        XCTAssertEqual(byID["ax-code"]?.usesMCP, true)
        XCTAssertEqual(byID["ax-code"]?.capabilities.map(\.available), [true, true, true])
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
