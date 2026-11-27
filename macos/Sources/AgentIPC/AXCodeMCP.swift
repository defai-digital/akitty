import Foundation

/// Adds or removes AkiTTY's AX Code integration in AX Code's global config folder:
/// - the MCP server in `ax-code.json`. AX Code merges that file with the commented `ax-code.jsonc` people edit by
///   hand, so AkiTTY writes only the plain-JSON file and never touches the commented one. AX Code then asks AkiTTY
///   to run a command through the `request_command` tool, which waits for approval.
/// - a small plugin, `plugin/akitty.js`, that reports which conversation runs in the pane (AX Code's plugin `event`
///   hook), so AkiTTY can show it and offer `ax-code --session <id>` after a restart.
public struct AXCodeMCPSettings: AgentMCPSettings {
    public static let serverName = "akitty"
    public let path: String
    public let executable: String

    /// `$XDG_CONFIG_HOME/ax-code/ax-code.json` when that is an absolute path, else `~/.config/ax-code/ax-code.json`.
    public static var defaultPath: String {
        let environment = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        let base = environment ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
        return URL(fileURLWithPath: base).appendingPathComponent("ax-code/ax-code.json").path
    }
    /// Explains that a Finder-launched app does not see an `XDG_CONFIG_HOME` set in the person's shell.
    public static var configHomeWarning: String {
        "If you set XDG_CONFIG_HOME in your shell, run `akitty-agent ax-code-mcp install` from that shell instead: apps opened from the Finder do not see it."
    }
    public init(path: String? = nil, executable: String) {
        self.path = path ?? Self.defaultPath
        self.executable = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    /// The reporting plugin next to the config file.
    public var pluginPath: String {
        URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("plugin/akitty.js").path
    }
    static let pluginMarker = "// Added by AkiTTY (akitty-agent ax-code-report)."
    /// The plugin source. It starts the companion with a sequenced conversation report; the companion finds the pane
    /// from its terminal, so the plugin carries no pane or socket details. Errors are ignored so AX Code is never affected.
    public var pluginSource: String {
        let quoted = String(decoding: (try? JSONSerialization.data(withJSONObject: [executable], options: [.withoutEscapingSlashes])) ?? Data("[]".utf8), as: UTF8.self)
        return """
        \(Self.pluginMarker)
        // Reports which AX Code conversation runs in this AkiTTY pane, so AkiTTY can offer to resume it after a
        // restart. Remove it in AkiTTY's Settings → Agents → AX Code, or with `akitty-agent ax-code-mcp uninstall`.
        import { spawn, spawnSync } from "node:child_process";
        import { randomUUID } from "node:crypto";
        const [companion] = \(quoted);
        const valid = (id) => typeof id === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id);
        const reporter = randomUUID();
        const register = () => new Promise((resolve) => {
          let output = "";
          try {
            const child = spawn(companion, ["ax-code-reporter", reporter], { stdio: ["ignore", "pipe", "ignore"], timeout: 5000 });
            child.stdout.on("data", (chunk) => { if (output.length < 4096) output += chunk; });
            child.on("error", () => resolve(null));
            child.on("close", () => {
              try {
                const epoch = JSON.parse(output)?.data?.epoch;
                resolve(typeof epoch === "string" && /^[1-9][0-9]*$/.test(epoch) ? epoch : null);
              } catch { resolve(null); }
            });
          } catch { resolve(null); }
        });
        let sequence = 0, current = null, currentOwner = null, started = null, registration = null, generation = 0;
        const ready = () => {
          if (started) return Promise.resolve(true);
          if (!registration) registration = register().then((epoch) => {
            started = epoch; registration = null;
            if (epoch !== null) generation += 1;
            return epoch !== null;
          });
          return registration;
        };
        const report = (event, id) => {
          sequence += 1;
          const version = generation, invalidate = () => { if (generation === version) { started = null; current = null; currentOwner = null; } };
          // Companions may finish in any order. AkiTTY orders each reporter's events and rejects older epochs.
          try {
            const child = spawn(companion, ["ax-code-report", event, id, reporter, String(sequence), started], { stdio: ["ignore", "pipe", "ignore"] });
            let output = "";
            child.stdout.on("data", (chunk) => { if (output.length < 4096) output += chunk; });
            child.on("error", invalidate);
            child.on("close", () => { try { if (JSON.parse(output)?.ok !== true) invalidate(); } catch { invalidate(); } });
            child.unref(); child.stdout.unref();
          } catch { invalidate(); }
        };
        const finish = (synchronous = false) => {
          if (!current) return;
          const id = current; current = null; currentOwner = null;
          if (!synchronous) { report("end", id); return; }
          try { spawnSync(companion, ["ax-code-report", "end", id, reporter, String(++sequence), started], { stdio: "ignore", timeout: 2000 }); } catch {}
        };
        process.once("exit", () => finish(true));
        export const AkittyConversationReport = async (input) => {
          await ready();
          const owner = {};
          input?.lifecycle?.onDispose?.(() => { if (currentOwner === owner) finish(); });
          // AX Code marks both sub-agent sessions and forks with parentID. A sub-agent runs while its parent is
          // busy; a fork is continued on its own. Only conversations the person works in are reported.
          const parents = new Map();
          const busy = new Set();
          const start = (id) => {
            if (!valid(id)) return;
            if (id === current) { currentOwner = owner; return; }
            current = id; currentOwner = owner; report("start", id);
          };
          return {
            event: async ({ event }) => {
              const properties = event?.properties ?? {};
              const info = properties.info ?? {};
              if (valid(info.id) && info.parentID && parents.size < 1000) parents.set(info.id, info.parentID);
              if (event.type === "session.status") {
                if (properties.status?.type !== "busy") { busy.delete(properties.sessionID); return; }
                if (busy.size < 1000) busy.add(properties.sessionID);
                const parent = parents.get(properties.sessionID);
                if (parent && busy.has(parent)) return;
              } else if (event.type === "session.idle") { busy.delete(properties.sessionID); return; }
              if (!await ready()) return;
              if (event.type === "session.created" && !info.parentID) start(info.id);
              else if (event.type === "session.status") start(properties.sessionID);
              else if (event.type === "session.deleted" && info.id === current) { report("end", current); current = null; currentOwner = null; }
            },
          };
        };

        """
    }
    /// The server entry AkiTTY writes: AX Code starts `akitty-agent mcp` itself, inside the pane it runs in.
    public var entry: [String: Any] { ["type": "local", "command": [executable, "mcp"]] }
    /// AkiTTY's entry: this copy's exact entry, or the companion inside another AkiTTY app bundle running `mcp`.
    /// A person's own tool, even one named akitty-agent elsewhere, is never treated as AkiTTY's.
    func isManaged(_ value: Any?) -> Bool {
        guard let server = value as? [String: Any], server["type"] as? String == "local",
              let command = server["command"] as? [String], command.count == 2, command[1] == "mcp" else { return false }
        return command[0] == executable || (command[0].hasPrefix("/") && command[0].hasSuffix(".app/Contents/MacOS/akitty-agent"))
    }
    func load() throws -> [String: Any] {
        // ax-code.json linked to the commented ax-code.jsonc would rewrite the file AkiTTY promises to leave alone.
        if try SettingsFile.resolved(path).pathExtension.lowercased() == "jsonc" {
            throw AgentIPCError.failure("\(path) links to a commented .jsonc file, which AkiTTY does not rewrite; it was left unchanged.")
        }
        let object = try SettingsFile.load(path)
        if let servers = object["mcp"], !(servers is [String: Any]) {
            throw AgentIPCError.failure("\(path): \"mcp\" is not an object; it was left unchanged.")
        }
        return object
    }
    /// The plugin file's state: AkiTTY's (current or not), missing, or a file AkiTTY did not write.
    func pluginState() -> AgentHookSettings.State {
        guard FileManager.default.fileExists(atPath: pluginPath) || (try? FileManager.default.destinationOfSymbolicLink(atPath: pluginPath)) != nil else { return .notInstalled }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: pluginPath)) == nil,
              let text = try? String(contentsOfFile: pluginPath, encoding: .utf8), text.hasPrefix(Self.pluginMarker) else { return .conflict }
        return text == pluginSource ? .installed : .partial
    }
    public func state() throws -> AgentHookSettings.State {
        let current = (try load()["mcp"] as? [String: Any])?[Self.serverName]
        let server: AgentHookSettings.State
        if isManaged(current) {
            server = NSDictionary(dictionary: current as? [String: Any] ?? [:]) == NSDictionary(dictionary: entry) ? .installed : .partial
        } else { server = current == nil ? .notInstalled : .conflict }
        let plugin = pluginState()
        if server == .conflict || plugin == .conflict { return .conflict }
        if server == plugin { return server }
        return .partial
    }
    public func install() throws {
        if pluginState() == .conflict {
            throw AgentIPCError.failure("\(pluginPath) exists and AkiTTY did not write it; it was left unchanged.")
        }
        var settings = try load()
        var servers = settings["mcp"] as? [String: Any] ?? [:]
        // Never replace a server of the same name that the person set up themselves.
        if let existing = servers[Self.serverName], !isManaged(existing) {
            throw AgentIPCError.failure("\(path) already has an MCP server named \"\(Self.serverName)\" that AkiTTY did not add; it was left unchanged.")
        }
        // The plugin first: if it cannot be written, AX Code's config is still unchanged.
        let folder = URL(fileURLWithPath: pluginPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(pluginSource.utf8).write(to: URL(fileURLWithPath: pluginPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pluginPath)
        servers[Self.serverName] = entry
        settings["mcp"] = servers
        try SettingsFile.save(settings, to: path)
    }
    public func uninstall() throws {
        var settings = try load()
        if var servers = settings["mcp"] as? [String: Any], isManaged(servers[Self.serverName]) {
            servers.removeValue(forKey: Self.serverName)
            settings["mcp"] = servers.isEmpty ? nil : servers
            try SettingsFile.save(settings, to: path)
        }
        let plugin = pluginState()
        if plugin == .installed || plugin == .partial { try FileManager.default.removeItem(atPath: pluginPath) }
    }
}
