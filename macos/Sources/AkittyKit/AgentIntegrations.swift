import AgentIPC
import AppKit
import SwiftUI

/// A coding-agent CLI AkiTTY can integrate with: where it is installed, its version, and what AkiTTY offers for it.
struct AgentCLI: Identifiable, Equatable {
    let id: String
    let name: String
    let executable: String
    let installURL: URL
    /// The hook integration, or nil when this agent has none in this version.
    let hooks: HookAgent?
    /// Whether AkiTTY's MCP server is the integration (AX Code), instead of hooks.
    var usesMCP: Bool { id == "ax-code" }
    /// What this version cannot do for an agent, and why.
    let unavailableReason: String?

    static let all: [AgentCLI] = [
        AgentCLI(id: "claude-code", name: "Claude Code", executable: "claude",
                 installURL: URL(string: "https://code.claude.com/docs/en/setup")!, hooks: .claudeCode, unavailableReason: nil),
        AgentCLI(id: "codex", name: "Codex", executable: "codex",
                 installURL: URL(string: "https://developers.openai.com/codex/cli")!, hooks: .codex, unavailableReason: nil),
        AgentCLI(id: "ax-code", name: "AX Code", executable: "ax-code",
                 installURL: URL(string: "https://github.com/defai-digital/ax-code")!, hooks: nil,
                 unavailableReason: "AX Code does not report its conversation to AkiTTY yet, so its status and resume by ID wait for an AX Code release that does."),
    ]

    /// What AkiTTY offers once the integration is installed and Local Agent Requests are on.
    var capabilities: [(name: String, available: Bool)] {
        if usesMCP {
            return [("Command requests with approval (MCP)", true), ("Status and conversation reports", false),
                    ("Resume a conversation by ID", false)]
        }
        let integrated = hooks != nil
        return [("Status and conversation reports", integrated), ("Bash command approval", integrated),
                ("Resume a conversation by ID", AgentConversation.resumeCommands[id] != nil)]
    }

    /// Folders searched for agent CLIs. Apps opened from the Finder get a minimal PATH, so the usual install
    /// locations are added after the inherited PATH.
    static func searchPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var seen = Set<String>()
        return (inherited + usual).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
    /// The first executable named `executable` in `path`, symlinks kept as found. Nil when it is not installed.
    static func locate(_ executable: String, in path: [String] = searchPath()) -> String? {
        for directory in path {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
    /// The first line `<cli> --version` prints, or nil if it fails or takes longer than `timeout`.
    /// Output is read while the CLI runs (at most 4 KiB), so a large or never-closed output cannot hang the probe,
    /// and a CLI still running at the deadline is stopped (SIGTERM, then SIGKILL) rather than left behind.
    static func version(of executable: String, timeout: TimeInterval = 5) async -> String? {
        await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["--version"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            // A minimal environment: enough for a script-based CLI to find its interpreter, nothing else from AkiTTY.
            let inherited = ProcessInfo.processInfo.environment
            var environment = ["PATH": searchPath().joined(separator: ":")]
            for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { if let value = inherited[key] { environment[key] = value } }
            process.environment = environment
            let reader = output.fileHandleForReading
            defer { try? reader.close() }
            guard (try? process.run()) != nil else { return nil }
            try? output.fileHandleForWriting.close()
            let fd = reader.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            let deadline = Date().addingTimeInterval(timeout)
            var finished = false
            while Date() < deadline && data.count < 4096 {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer[0..<count]); continue }
                if count == 0 { finished = !process.isRunning; if finished { break } }      // EOF
                else if errno != EAGAIN && errno != EINTR { break }
                // Exited: what it wrote is already in the pipe, even if a child it left keeps the pipe open.
                if !process.isRunning { finished = true; if read(fd, &buffer, buffer.count) <= 0 { break } else { continue } }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if process.isRunning {
                // Still writing past 4 KiB, or past the deadline: a complete first line is enough; otherwise give up.
                process.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                guard data.contains(10) else { return nil }
            } else {
                guard process.terminationStatus == 0 else { return nil }
            }
            // Drop ANSI escape sequences before the remaining control characters are filtered.
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
            return line.map { String(ProgramStatusRecord.displayText($0).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
        }.value
    }
}

extension Notification.Name {
    /// Posted when Local Agent Requests are turned on or off.
    static let agentRequestsChanged = Notification.Name("AkittyAgentRequestsChanged")
}

/// Whether AkiTTY turns Local Agent Requests on when it starts. Off by default: requests stay an explicit choice.
enum AgentRequestsLaunchSetting {
    static let key = "enableAgentRequestsAtLaunch"
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
}

/// Settings → Agents: each agent CLI's install state, version, capabilities and hooks, with one-click install and
/// removal. Changes apply at once; they do not wait for Settings' Apply button.
@MainActor struct AgentIntegrationsView: View {
    struct Row: Equatable {
        var path: String?
        var version: String?
        var hooks: AgentHookSettings.State?
        var hooksPath: String?
        var lastReport: String?
    }
    let defaults: UserDefaults
    @State private var rows: [String: Row] = [:]
    @State private var message = ""
    @State private var requestsAtLaunch = false
    @State private var requestsOn = false
    /// CLIs whose version is being read, so reopening the tab never starts a second probe of the same path.
    @State private var probing: Set<String> = []

    private var app: AkittyApplication? { NSApp.delegate as? AkittyApplication }
    private var companion: String? {
        let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("akitty-agent").path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    var body: some View {
        Form {
            Section("Local Agent Requests") {
                Toggle("Turn on when AkiTTY starts", isOn: $requestsAtLaunch)
                    .onChange(of: requestsAtLaunch) { _, value in defaults.set(value, forKey: AgentRequestsLaunchSetting.key) }
                HStack {
                    Text(requestsOn ? "On now." : "Off now.").foregroundStyle(.secondary)
                    Button(requestsOn ? "Turn Off" : "Turn On") {
                        do { try app?.setAgentRequests(!requestsOn) } catch { message = error.localizedDescription }
                        refresh()
                    }
                }
                Text("Integrations answer an agent's prompts and record its conversation only while requests are on. Every command still needs your approval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if companion == nil {
                Text("Install is unavailable: the akitty-agent companion was not found next to AkiTTY. Reinstall AkiTTY, or use `akitty-agent claude-hooks|codex-hooks install` from a copy that has it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(AgentCLI.all) { cli in section(for: cli) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red).accessibilityIdentifier("agents-message") }
        }.formStyle(.grouped)
            .onAppear { requestsAtLaunch = AgentRequestsLaunchSetting.isOn(defaults); refresh() }
            // The Akitty menu can turn requests on or off while this tab is open.
            .onReceive(NotificationCenter.default.publisher(for: .agentRequestsChanged)) { _ in refresh() }
    }

    @ViewBuilder private func section(for cli: AgentCLI) -> some View {
        let row = rows[cli.id] ?? Row()
        Section(cli.name) {
            if let path = row.path {
                LabeledContent("Installed", value: row.version.map { "\($0) · \(path)" } ?? path)
            } else {
                HStack {
                    Text("Not found in PATH or the usual install folders.").foregroundStyle(.secondary)
                    Button("Install Instructions…") { NSWorkspace.shared.open(cli.installURL) }
                }
            }
            ForEach(cli.capabilities, id: \.name) { capability in
                LabeledContent(capability.name, value: capability.available ? "Available" : "Not available")
            }
            if let hooks = cli.hooks {
                LabeledContent("Hooks", value: describe(row.hooks))
                if let file = row.hooksPath { Text(file).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button(row.hooks == .installed ? "Reinstall" : "Install") { change(hooks) { try $0.install() } }
                        .disabled(companion == nil)
                    if row.hooks != nil && row.hooks != .notInstalled {
                        Button("Remove") { change(hooks) { try $0.uninstall() } }
                    }
                }
                Text(row.lastReport.map { "Connected: \($0)" }
                     ?? "Not connected yet. Start \(cli.name) in an AkiTTY pane with requests on; its conversation appears here.")
                    .font(.caption).foregroundStyle(.secondary)
                if hooks == .codex {
                    Text("After installing, run /hooks in Codex and trust the new hooks. \(hooks.codexHomeWarning ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Restart running Claude Code sessions to load a change.").font(.caption).foregroundStyle(.secondary)
                }
            } else if cli.usesMCP {
                LabeledContent("MCP server", value: describe(row.hooks))
                if let file = row.hooksPath { Text(file).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button(row.hooks == .installed ? "Reinstall" : "Install") { changeMCP { try $0.install() } }
                        .disabled(companion == nil || row.hooks == .conflict)
                    if row.hooks == .installed || row.hooks == .partial { Button("Remove") { changeMCP { try $0.uninstall() } } }
                }
                Text("AX Code asks AkiTTY to run a shell command in a pane through the akitty request_command tool; every command waits for your approval. AkiTTY writes only ax-code.json, never your commented ax-code.jsonc. Restart AX Code to load a change.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(AXCodeMCPSettings.configHomeWarning).font(.caption).foregroundStyle(.secondary)
                if let reason = cli.unavailableReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func describe(_ state: AgentHookSettings.State?) -> String {
        switch state {
        case .installed?: return "Installed"
        case .partial?: return "Partly installed; Reinstall repairs it"
        case .notInstalled?: return "Not installed"
        case .conflict?: return "A server named akitty that AkiTTY did not add is there; AkiTTY leaves it alone"
        case nil: return companion == nil ? "Unknown (companion missing)" : "Unreadable settings file"
        }
    }
    private func change(_ agent: HookAgent, _ action: (AgentHookSettings) throws -> Void) {
        guard let companion else { message = "The bundled akitty-agent companion was not found next to AkiTTY."; return }
        do { try action(AgentHookSettings(agent: agent, executable: companion)); message = "" }
        catch { message = error.localizedDescription }
        refresh()
    }
    private func changeMCP(_ action: (AXCodeMCPSettings) throws -> Void) {
        guard let companion else { message = "The bundled akitty-agent companion was not found next to AkiTTY."; return }
        do { try action(AXCodeMCPSettings(executable: companion)); message = "" }
        catch { message = error.localizedDescription }
        refresh()
    }
    private func refresh() {
        requestsOn = app?.agentRequests.enabled == true
        for cli in AgentCLI.all {
            var row = rows[cli.id] ?? Row()
            row.path = AgentCLI.locate(cli.executable)
            if let hooks = cli.hooks {
                // Without the companion there is no command to recognize as this copy's, so no state is claimed.
                row.hooksPath = hooks.defaultSettingsPath
                row.hooks = companion.flatMap { try? AgentHookSettings(agent: hooks, executable: $0).state() }
            } else if cli.usesMCP {
                row.hooksPath = AXCodeMCPSettings.defaultPath
                row.hooks = companion.flatMap { try? AXCodeMCPSettings(executable: $0).state() }
            }
            row.lastReport = app?.agentRequests.lastReport(agent: cli.id)
            rows[cli.id] = row
            if let path = row.path, row.version == nil, !probing.contains(path) {
                probing.insert(path)
                Task { let version = await AgentCLI.version(of: path); rows[cli.id]?.version = version }
            }
        }
    }
}
