import Foundation
import JavaScriptCore

public enum NativeCommand: String, CaseIterable, Codable {
    case newWindow = "new-window", newTab = "new-tab", split, closePane = "close-pane"
    case copy, paste, find, fontIncrease = "font-increase", fontDecrease = "font-decrease", fontReset = "font-reset"
    public var title: String {
        switch self {
        case .newWindow: return "New Window"
        case .newTab: return "New Tab"
        case .split: return "Split Pane"
        case .closePane: return "Close Pane"
        case .copy: return "Copy Selection"
        case .paste: return "Paste Text"
        case .find: return "Find in Scrollback"
        case .fontIncrease: return "Increase Font Size"
        case .fontDecrease: return "Decrease Font Size"
        case .fontReset: return "Reset Font Size"
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

/// Only trusted, bounded code from the app bundle executes. No native objects are exported.
/// All calls occur on the main actor; this is command UI, never the render path.
@MainActor public final class FeatureHost {
    private var context: JSContext?
    public private(set) var warning: String?
    public init(source: String? = nil) {
        do {
            let script: String
            if let source { script = source }
            else {
                guard let url = Bundle.main.url(forResource: "features", withExtension: "js") else { throw AkittyError.core("Palette bundle missing") }
                script = try String(contentsOf: url, encoding: .utf8)
            }
            guard script.utf8.count <= 262144, let context = JSContext() else { throw AkittyError.core("Palette initialization failed") }
            context.evaluateScript(script)
            guard context.exception == nil else { throw AkittyError.core("Palette script failed") }
            self.context = context
        } catch { warning = "TypeScript palette unavailable; using native commands." }
    }
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
        let query = String(query.prefix(128))
        if let context {
            context.exception = nil
            let value = context.objectForKeyedSubscript("AkittyFeatures")?.objectForKeyedSubscript("listCommands")?.call(withArguments: [query])
            if context.exception == nil, let string = value?.toString(), let data = string.data(using: .utf8), let entries = try? Self.decode(data) { return entries }
            self.context = nil
            warning = "TypeScript palette failed; using native commands."
        }
        return NativeCommand.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.map {
            CommandDescriptor(id: $0, title: $0.title, shortcut: "", keywords: [])
        }
    }
}

public enum ClipboardPolicy {
    public static let maximumBytes = 65536
    public static func acceptsText(_ text: String) -> Bool { text.utf8.count <= maximumBytes && !text.contains("\0") }
    public static func needsPasteConfirmation(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r") || text.contains("\u{1b}") || text.contains("\u{7f}")
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
