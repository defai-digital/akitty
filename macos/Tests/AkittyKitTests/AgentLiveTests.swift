import AppKit
import XCTest
@testable import AgentIPC
@testable import AkittyKit

/// Claude Code, Codex and AX Code running at the same time in real AkiTTY panes, each answered through AkiTTY.
/// Opt-in, because it runs the installed agents against their real models:
///
///     AKITTY_LIVE_AGENTS=1 AKITTY_LIVE_AXCODE_MODEL=<provider/model> swift test --filter AgentLiveTests
///
/// Nothing global is changed. Claude Code reads AkiTTY's hooks from `--settings <temp file>`; Codex gets them as
/// `-c hooks.*` overrides with `--dangerously-bypass-hook-trust` for this run only; AX Code reads the MCP server and
/// plugin from `AX_CODE_CONFIG_DIR`. Codex runs read-only in this repository (which must already be trusted in
/// Codex), so its write elsewhere needs an escalation that AkiTTY answers.
final class AgentLiveTests: XCTestCase {
    @MainActor func testThreeRealAgentsAreAnsweredThroughAkiTTYAtOnce() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AKITTY_LIVE_AGENTS"] == "1", let model = environment["AKITTY_LIVE_AXCODE_MODEL"] else {
            throw XCTSkip("Set AKITTY_LIVE_AGENTS=1 and AKITTY_LIVE_AXCODE_MODEL to run the installed agents")
        }
        let path = AgentCLI.searchPath()
        guard let claude = AgentCLI.locate("claude", in: path), let codex = AgentCLI.locate("codex", in: path),
              let axCode = AgentCLI.locate("ax-code", in: path) else { throw XCTSkip("claude, codex and ax-code must be installed") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/akitty-live-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let integration = repository.appendingPathComponent("macos/Sources/AkittyKit/Resources/shell-integration/akitty.zsh").path

        var preferences = TerminalPreferences(); preferences.shell = "/bin/zsh"; preferences.directory = root.path; preferences.shellIntegration = false
        let panes = try (0..<4).map { _ in try TerminalView(headless: false, forceSoftware: true, forceShaderFailure: false, initial: preferences) }
        let windows = panes.map { pane -> NSWindow in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = pane; window.orderFront(nil)
            return window
        }
        let socket = root.appendingPathComponent("s.sock").path
        let service = AgentRequests(source: { panes }, store: AgentEventStore(directory: root.appendingPathComponent("events")), path: socket)
        service.cooldownInterval = 0; try service.setEnabled(true)
        defer { service.stop(); panes.forEach { $0.shutdown() }; windows.forEach { $0.close() } }
        let (claudePane, codexPane, axPane, targetPane) = (panes[0], panes[1], panes[2], panes[3])

        // The companion, pinned to this test's socket.
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("akitty-agent").path
        let wrapper = root.appendingPathComponent("akitty-agent")
        try Data("#!/bin/sh\nexec \(AgentHookSettings.shellQuoted(cli)) --socket \(AgentHookSettings.shellQuoted(socket)) \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)

        // Each agent's integration, written by AkiTTY's own installers into temporary files.
        let claudeSettings = root.appendingPathComponent("claude-settings.json").path
        try AgentHookSettings(agent: .claudeCode, path: claudeSettings, executable: wrapper.path).install()
        let codexHooks = root.appendingPathComponent("codex-hooks.json").path
        try AgentHookSettings(agent: .codex, path: codexHooks, executable: wrapper.path).install()
        let axConfig = root.appendingPathComponent("axcfg")
        try AXCodeMCPSettings(path: axConfig.appendingPathComponent("ax-code.json").path, executable: wrapper.path).install()

        let markers = ["claude", "codex", "ax"].map { root.appendingPathComponent("\($0)-marker").path }
        let exportPath = "export PATH=\(AgentHookSettings.shellQuoted(path.joined(separator: ":")))"
        let q = AgentHookSettings.shellQuoted
        func launcher(_ name: String, _ body: String) throws -> String {
            let file = root.appendingPathComponent(name)
            try Data("#!/bin/zsh\n\(exportPath)\n\(body)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return q(file.path) + "\r"
        }
        let codexOverrides = try Self.tomlOverrides(hooksFile: codexHooks).map { "-c " + q($0) }.joined(separator: " ")

        // The target pane is an integrated idle shell that AX Code's request runs in.
        try targetPane.session.input("AKITTY_FOLDER_HISTORY=0; source \(q(integration))\r", paste: false)
        try await waitUntil(60) { try targetPane.session.snapshot()?.shell?.ready == true && (try panes.allSatisfy { try $0.session.shellState().tty_device != nil }) }
        let list = try await Task.detached { try LocalSocket.request(Data("{\"version\":1,\"op\":\"list\"}".utf8), path: socket) }.value
        let listed = ((try JSONSerialization.jsonObject(with: list) as! [String: Any])["data"] as! [String: Any])["panes"] as! [[String: Any]]
        let targetID = try XCTUnwrap(listed.compactMap { $0["pane"] as? String }.first { $0.hasSuffix("/\(targetPane.session.id)") })

        try claudePane.session.input(try launcher("claude.sh", "exec \(q(claude)) -p --settings \(q(claudeSettings)) \(q("Run this exact shell command with the Bash tool, nothing else: touch \(markers[0])")) </dev/null"), paste: false)
        try codexPane.session.input(try launcher("codex.sh", "cd \(q(repository.path)) && exec \(q(codex)) --dangerously-bypass-hook-trust -s read-only -a on-request \(codexOverrides) \(q("Run this exact shell command, nothing else: touch \(markers[1]) . The read-only sandbox blocks it, so request escalated permissions for that command."))"), paste: false)
        try axPane.session.input(try launcher("ax.sh", "AX_CODE_CONFIG_DIR=\(q(axConfig.path)) exec \(q(axCode)) run --model \(q(model)) -- \(q("Call the akitty MCP tool request_command once with pane \"\(targetID)\" and command \"touch \(markers[2])\". Do not run it any other way. Then reply done."))"), paste: false)

        // Answer every sheet as it appears, in whichever window, until all three commands have run.
        var answered: [String] = []
        try await waitUntil(420) {
            for window in windows {
                guard let sheet = window.attachedSheet else { continue }
                answered.append(Self.text(of: sheet))
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            }
            return markers.allSatisfy(FileManager.default.fileExists(atPath:))
        }
        let summary = answered.joined(separator: "\n---\n")
        XCTAssertTrue(answered.contains { $0.contains("Claude Code") }, summary)
        XCTAssertTrue(answered.contains { $0.contains("Codex") }, summary)
        XCTAssertTrue(answered.contains { $0.contains("Terminal \(axPane.session.id)") && $0.contains("Terminal \(targetPane.session.id)") }, summary)
        try await waitUntil(60) { ["claude-code", "codex", "ax-code"].allSatisfy { service.lastReport(agent: $0) != nil } }
        XCTAssertEqual(service.agentSessions[claudePane.session.id]?.agent, "claude-code")
        XCTAssertEqual(service.agentSessions[codexPane.session.id]?.agent, "codex")
        XCTAssertEqual(service.agentSessions[axPane.session.id]?.agent, "ax-code")
        print("AKITTY_LIVE_SHEETS \(answered.count)")

        // Leaving Codex reports the end of its conversation (its SessionEnd hook).
        try codexPane.session.input("\u{3}", paste: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        try codexPane.session.input("\u{3}", paste: false)
        try await waitUntil(30) { service.agentSessions[codexPane.session.id]?.ended == true }
        try targetPane.session.reclaimControl()
    }

    /// `-c hooks.<Event>=[…]` overrides for Codex, rendered from the hooks file AkiTTY's installer wrote.
    static func tomlOverrides(hooksFile: String) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: hooksFile))) as! [String: Any]
        let hooks = object["hooks"] as! [String: [[String: Any]]]
        func string(_ value: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return hooks.keys.sorted().map { event in
            let groups = hooks[event]!.map { group -> String in
                var fields: [String] = []
                if let matcher = group["matcher"] as? String { fields.append("matcher=\(string(matcher))") }
                let handlers = (group["hooks"] as! [[String: Any]]).map {
                    "{type=\(string($0["type"] as! String)),command=\(string($0["command"] as! String)),timeout=\($0["timeout"] as! Int)}"
                }
                fields.append("hooks=[\(handlers.joined(separator: ","))]")
                return "{\(fields.joined(separator: ","))}"
            }
            return "hooks.\(event)=[\(groups.joined(separator: ","))]"
        }
    }
    static func text(of window: NSWindow) -> String {
        func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
        return window.contentView.map(texts)?.joined(separator: "\n") ?? ""
    }
    @MainActor private func waitUntil(_ seconds: TimeInterval, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("condition did not become true within \(Int(seconds)) s")
    }
}
