import Foundation

/// An agent conversation a pane can resume after AkiTTY restarts: the agent's own session ID and when it was
/// reported. Commands, prompts, output and approvals are never stored, so nothing can be replayed.
struct AgentConversation: Codable, Equatable {
    var agent: String
    var sessionID: String
    /// Seconds since 1970 when the agent last reported this conversation.
    var reported: Double

    /// Agents whose CLI resumes a conversation by its ID. Each one starts a new process in the pane's shell.
    static let resumeCommands: [String: String] = ["claude-code": "claude --resume", "codex": "codex resume"]

    /// The exact command typed when the human chooses Resume. Nil for an agent AkiTTY cannot resume, or an ID that
    /// is not a plain token (it must start with a letter or digit, so it can never read as an option).
    var resumeCommand: String? {
        guard let base = Self.resumeCommands[agent], AgentRequests.isValidAgentSessionID(sessionID),
              let first = sessionID.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), first.isASCII else { return nil }
        return "\(base) \(sessionID)"
    }
    var isResumable: Bool { resumeCommand != nil && reported.isFinite }
}

/// The workspace AkiTTY saves for "Reopen Windows and Agent Conversations at Launch". It is a window layout without
/// scrollback, plus each pane's last reported agent conversation, kept in this Mac's user defaults.
enum WorkspaceStore {
    static let enabledKey = "restoreWorkspaceAtLaunch"
    static let workspaceKey = "savedWorkspace"
    static let maxBytes = 256 * 1024

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }
    static func setEnabled(_ value: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledKey)
        if !value { clear(defaults) }
    }
    static func load(_ defaults: UserDefaults = .standard) -> WindowLayout? {
        guard let data = defaults.data(forKey: workspaceKey), data.count <= maxBytes,
              let layout = try? JSONDecoder().decode(WindowLayout.self, from: data), !layout.windows.isEmpty else { return nil }
        return layout.clamped()
    }
    /// Saves `layout` with every pane's text removed. With no windows open (the last one closed while AkiTTY keeps
    /// running) or a layout over the size limit, the previous save is kept.
    static func save(_ layout: WindowLayout, _ defaults: UserDefaults = .standard) {
        var layout = layout
        for window in layout.windows.indices {
            for tab in layout.windows[window].tabs.indices {
                for pane in layout.windows[window].tabs[tab].panes.indices { layout.windows[window].tabs[tab].panes[pane].scrollback = nil }
            }
        }
        guard !layout.windows.isEmpty, let data = try? JSONEncoder().encode(layout.clamped()), data.count <= maxBytes else { return }
        defaults.set(data, forKey: workspaceKey)
    }
    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: workspaceKey) }

    /// The line shown in a restored pane before its fresh shell starts.
    static func notice(for conversation: AgentConversation) -> String {
        let name = AgentRequests.agentNames[conversation.agent] ?? conversation.agent
        return "AkiTTY: this pane had \(name) conversation \(conversation.sessionID). Choose Shell ▸ Resume Agent Conversation to continue it.\n"
    }
}
