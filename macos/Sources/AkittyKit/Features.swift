import Foundation

public enum NativeCommand: String, CaseIterable, Codable {
    case newWindow = "new-window", newTab = "new-tab", split, closePane = "close-pane"
    case copy, paste, find, findNext = "find-next", findPrevious = "find-previous", findAll = "find-all"
    case fontIncrease = "font-increase", fontDecrease = "font-decrease", fontReset = "font-reset"
    case agentOverview = "agent-overview"
    case nextTab = "next-tab", previousTab = "previous-tab", nextPane = "next-pane", previousPane = "previous-pane"
    case restartTerminal = "restart-terminal", quickTerminal = "quick-terminal", settings, saveLayout = "save-layout"
    case reclaimControl = "reclaim-control", resumeAgent = "resume-agent", agentIntegrations = "agent-integrations"
    case agentTimeline = "agent-timeline", checkUpdates = "check-updates", toggleFullScreen = "toggle-full-screen"
    public var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .split: return "Split Pane"
        case .closePane: return "Close Pane"
        case .copy: return "Copy Selection"
        case .paste: return "Paste Text"
        case .find: return "Find in Scrollback"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .findAll: return "Find in All Terminals"
        case .fontIncrease: return "Increase Font Size"
        case .fontDecrease: return "Decrease Font Size"
        case .fontReset: return "Reset Font Size"
        case .agentOverview: return "Agent Overview"
        case .nextTab: return "Show Next Tab"
        case .previousTab: return "Show Previous Tab"
        case .nextPane: return "Focus Next Pane"
        case .previousPane: return "Focus Previous Pane"
        case .restartTerminal: return "Restart Terminal"
        case .quickTerminal: return "Toggle Quick Terminal"
        case .settings: return "Settings…"
        case .saveLayout: return "Save Windows as Layout…"
        case .reclaimControl: return "Reclaim Terminal Control"
        case .resumeAgent: return "Resume Agent Conversation"
        case .agentIntegrations: return "Agent Integrations…"
        case .agentTimeline: return "Agent Event Timeline…"
        case .checkUpdates: return "Check for Updates…"
        case .toggleFullScreen: return "Toggle Full Screen"
        }
    }
    /// The SF Symbol the command palette shows beside the command.
    var symbolName: String {
        switch self {
        case .newWindow: return "macwindow.badge.plus"
        case .newTab: return "plus.square.on.square"
        case .split: return "rectangle.split.2x1"
        case .closePane: return "xmark.square"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .find, .findNext, .findPrevious: return "magnifyingglass"
        case .findAll: return "text.magnifyingglass"
        case .fontIncrease: return "textformat.size.larger"
        case .fontDecrease: return "textformat.size.smaller"
        case .fontReset: return "textformat.size"
        case .agentOverview: return "person.2.badge.gearshape"
        case .nextTab: return "chevron.right.square"
        case .previousTab: return "chevron.left.square"
        case .nextPane: return "arrow.right.square"
        case .previousPane: return "arrow.left.square"
        case .restartTerminal: return "arrow.clockwise"
        case .quickTerminal: return "rectangle.topthird.inset.filled"
        case .settings: return "gearshape"
        case .saveLayout: return "square.and.arrow.down.on.square"
        case .reclaimControl: return "hand.raised"
        case .resumeAgent: return "arrow.uturn.forward"
        case .agentIntegrations: return "puzzlepiece.extension"
        case .agentTimeline: return "list.bullet.rectangle"
        case .checkUpdates: return "arrow.down.circle"
        case .toggleFullScreen: return "arrow.up.left.and.arrow.down.right"
        }
    }
}
public struct CommandDescriptor: Codable {
    public let id: NativeCommand
    public let title: String
    public let shortcut: String
    public let keywords: [String]
}
private struct CommandEnvelope: Codable { let version: Int; let commands: [CommandDescriptor] }

/// Swift validates the closed command catalog returned by Rust before dispatching native actions.
@MainActor public final class CommandProvider {
    private let request: ([String: Any]) throws -> Data
    public private(set) var warning: String?
    public init() { request = CoreBridge.call }
    init(request: @escaping ([String: Any]) throws -> Data) { self.request = request }
    public static func decode(_ data: Data) throws -> [CommandDescriptor] {
        guard data.count <= 65536 else { throw AkittyError.core("Palette response too large") }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: data)
        guard envelope.version == 1, envelope.commands.count <= 64,
              Set(envelope.commands.map(\.id)).count == envelope.commands.count else { throw AkittyError.core("Invalid palette schema") }
        for entry in envelope.commands {
            guard !entry.title.isEmpty, entry.title.count <= 80, entry.shortcut.count <= 32,
                  entry.keywords.count <= 16, entry.keywords.allSatisfy({ $0.count <= 64 }),
                  ([entry.title, entry.shortcut] + entry.keywords).allSatisfy({ $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }) else {
                throw AkittyError.core("Invalid palette descriptor")
            }
        }
        return envelope.commands
    }
    public func search(_ query: String) -> [CommandDescriptor] {
        let utf8 = query.trimmingCharacters(in: .whitespacesAndNewlines).utf8
        var end = utf8.index(utf8.startIndex, offsetBy: 512, limitedBy: utf8.endIndex) ?? utf8.endIndex
        // If the ABI byte limit cuts a scalar, leave that scalar out. Rust bounds the normalized query.
        while end != utf8.endIndex && utf8[end] & 0xc0 == 0x80 { utf8.formIndex(before: &end) }
        let query = String(decoding: utf8[..<end], as: UTF8.self)
        do {
            let entries = try Self.decode(try request(["op": "command_palette", "query": query]))
            warning = nil
            return entries
        } catch {
            warning = "Rust command ranking unavailable; using native commands."
            return NativeCommand.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.map {
                CommandDescriptor(id: $0, title: $0.title, shortcut: "", keywords: [])
            }
        }
    }
}

public enum ClipboardPolicy {
    public static let maximumBytes = 65536
    /// One short line for a clipboard-write prompt: whitespace runs and control characters collapse to a space.
    public static func writePreview(_ text: String, limit: Int = 120) -> String {
        var preview = "", pendingSpace = false, count = 0
        for character in text {
            if character.isWhitespace || character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                pendingSpace = !preview.isEmpty; continue
            }
            if count >= limit { return preview + "…" }
            if pendingSpace { preview.append(" "); count += 1; pendingSpace = false }
            preview.append(character); count += 1
        }
        return preview
    }
    public static func acceptsText(_ text: String) -> Bool { text.utf8.count <= maximumBytes && !text.contains("\0") }
    public static func needsPasteConfirmation(_ text: String) -> Bool {
        // Any control scalar (C0 incl. ESC/CR/LF, DEL, C1) except ordinary tab is dangerous in a paste.
        text.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x09 || $0.value == 0x7f || ($0.value >= 0x80 && $0.value <= 0x9f) }
    }
}
public struct Composition {
    public private(set) var text = ""
    public mutating func mark(_ text: String) { self.text = String(text.prefix(4096)) }
    public mutating func commit(_ text: String) -> String { self.text = ""; return text }
    public mutating func cancel() { text = "" }
}

public enum MouseEncoding {
    public static func encode(button: Int, row: Int, col: Int, release: Bool, sgr: Bool, modifiers: Int = 0) -> [UInt8]? {
        guard row >= 0, col >= 0, row < 256, col < 512 else { return nil }
        if sgr { return Array("\u{1b}[<\(button + modifiers);\(col + 1);\(row + 1)\(release ? "m" : "M")".utf8) }
        guard row < 223, col < 223 else { return nil }
        let code = release ? 3 + modifiers : button + modifiers
        guard code >= 0, code + 32 < 256 else { return nil }
        return [27, 91, 77, UInt8(code + 32), UInt8(col + 33), UInt8(row + 33)]
    }
}
