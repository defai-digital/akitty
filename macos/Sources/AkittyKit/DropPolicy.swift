import AppKit

/// Finder files take precedence over a textual representation. Paths are inserted, never executed.
@MainActor enum DropPolicy {
    static func text(from pasteboard: NSPasteboard) throws -> String? {
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= 64 else { throw AkittyError.core("Drop at most 64 files or text items.") }
        let fileItems = items.filter { $0.types.contains(.fileURL) }
        if !fileItems.isEmpty {
            guard fileItems.count == items.count else { throw AkittyError.core("Drop files separately from text.") }
            var paths: [String] = []
            var size = 0
            for item in fileItems {
                guard let raw = item.string(forType: .fileURL), raw.utf8.count <= 8192,
                      let url = URL(string: raw), url.isFileURL, (url.host == nil || url.host == "" || url.host == "localhost"),
                      url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw AkittyError.core("Drop requires local file URLs.") }
                let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                size += quoted.utf8.count + 1
                guard size <= ClipboardPolicy.maximumBytes else { throw AkittyError.core("Dropped paths exceed 64 KiB.") }
                paths.append(quoted)
            }
            return paths.joined(separator: " ") + " "
        }
        guard items.count <= 1 else { throw AkittyError.core("Drop one text item at a time.") }
        guard let text = pasteboard.string(forType: .string) else { return nil }
        guard ClipboardPolicy.acceptsText(text) else { throw AkittyError.core("Drop requires plain text up to 64 KiB.") }
        return text
    }
}
