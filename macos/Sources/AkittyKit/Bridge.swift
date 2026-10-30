import Foundation
import AkittyCore

public enum AkittyError: Error, LocalizedError {
    case core(String)
    public var errorDescription: String? { if case let .core(message) = self { return message }; return nil }
}

public enum CoreBridge {
    public static func call(_ request: [String: Any]) throws -> Data {
        guard akitty_abi_version() == 1 else { throw AkittyError.core("Incompatible Akitty core ABI") }
        let bytes = try JSONSerialization.data(withJSONObject: request)
        guard bytes.count <= 1_048_576 else { throw AkittyError.core("Request too large") }
        let buffer = bytes.withUnsafeBytes { raw in
            akitty_request_v1(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        defer { akitty_buffer_free_v1(buffer) }
        guard let pointer = buffer.data, buffer.len > 0, buffer.len <= 8 * 1_048_576 else {
            throw AkittyError.core("Invalid core response")
        }
        let data = Data(bytes: pointer, count: buffer.len)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["version"] as? Int == 1, let ok = envelope["ok"] as? Bool else {
            throw AkittyError.core("Invalid core response schema")
        }
        guard ok else { throw AkittyError.core(envelope["error"] as? String ?? "Unknown core failure") }
        guard let payload = envelope["data"] else { throw AkittyError.core("Missing response data") }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

public struct Cell: Codable, Sendable {
    public let row: Int
    public let col: Int
    public let text: String
    public let fg: [UInt8]
    public let bg: [UInt8]
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let selected: Bool
    public let wide: Bool
    /// 1 single, 2 double, 3 curly, 4 dotted, 5 dashed; absent when the cell is not underlined.
    public let ustyle: UInt8?
    public let ucolor: [UInt8]?
    public let strike: Bool?
    /// Index into `Snapshot.links` for OSC 8 hyperlinks.
    public let link: Int?
}

/// OSC 8 targets come from untrusted terminal output; only inert schemes may be opened.
public enum LinkPolicy {
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]
    public static func url(for target: String) -> URL? {
        guard target.utf8.count <= 2048, !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: target), let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        if scheme != "mailto", url.host?.isEmpty != false { return nil }
        return url
    }
}
/// A Kitty graphics placement: pixels live in the core and are fetched by id and generation.
public struct ImagePlacement: Codable, Sendable, Equatable {
    public let id: UInt32
    public let gen: UInt64
    public let w: Int
    public let h: Int
    public let row: Int
    public let col: Int
    public let cols: Int
    public let rows: Int
    public let z: Int
}
public struct Cursor: Codable, Sendable { public let row: Int; public let col: Int; public let visible: Bool }
public struct Snapshot: Codable, Sendable {
    public let changed: Bool
    public let revision: UInt64
    public let cols: Int
    public let rows: Int
    public let title: String
    public let cells: [Cell]
    public let lines: [String]
    public let links: [String]?
    public let images: [ImagePlacement]?
    public let cursor: Cursor
    public let bracketed_paste: Bool
    public let app_cursor: Bool
    public let mouse_mode: Bool
    public let mouse_sgr: Bool
    public let mouse_drag: Bool
    public let mouse_motion: Bool
    public let focus_reporting: Bool
    public let alternate: Bool
    public let offset: Int
    public let history: Int
    public let clipboard: [String]
    public let error: String?
    public let exited: Bool
    public let exit_code: UInt32?
    public var text: String { lines.joined(separator: "\n") }
    /// The openable hyperlink under a cell, if any.
    public func hyperlink(row: Int, col: Int) -> URL? {
        guard let links, let cell = cells.first(where: { $0.row == row && $0.col == col }),
              let index = cell.link, links.indices.contains(index) else { return nil }
        return LinkPolicy.url(for: links[index])
    }
    public func textOffset(row: Int, col: Int) -> Int {
        let row = min(max(0, row), max(0, rows - 1))
        let before = lines.prefix(row).reduce(0) { $0 + $1.utf16.count + 1 }
        return before + cells.lazy.filter { $0.row == row && $0.col < col }.reduce(0) { $0 + $1.text.utf16.count }
    }
}

public final class TerminalSession: @unchecked Sendable {
    // The native API is internally serialized; this lock also protects close/call ordering.
    private let lock = NSLock()
    public let id: UInt64
    private var closed = false
    public init(cols: Int = 100, rows: Int = 30, headless: Bool = false, shell: String? = nil, directory: String? = nil, scrollback: Int = 5000) throws {
        var request: [String: Any] = ["op": "create", "cols": cols, "rows": rows, "headless": headless, "scrollback": scrollback]
        if let shell, !shell.isEmpty { request["shell"] = shell }
        if let directory, !directory.isEmpty { request["cwd"] = directory }
        let data = try CoreBridge.call(request)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = value?["id"] as? UInt64 else { throw AkittyError.core("No terminal handle") }
        self.id = id
    }
    deinit { try? close() }
    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        if closed { return }
        closed = true
        _ = try CoreBridge.call(["op": "close", "id": id])
    }
    public func call(_ op: String, _ values: [String: Any] = [:]) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw AkittyError.core("Session is closed") }
        var request = values; request["op"] = op; request["id"] = id
        return try CoreBridge.call(request)
    }
    public func snapshot(since: UInt64? = nil) throws -> Snapshot? {
        let data = try call("snapshot", since.map { ["since": $0] } ?? [:])
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["changed"] as? Bool == false { return nil }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }
    /// RGBA pixels of a stored graphics image, or nil if it changed size or was removed meanwhile.
    public func imagePixels(_ image: UInt32, width: Int, height: Int) -> Data? {
        let count = width * height * 4
        guard width > 0, height > 0, count <= 32 * 1_048_576 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        var data = Data(count: count)
        let copied = data.withUnsafeMutableBytes { raw in
            akitty_image_read_v1(id, image, raw.bindMemory(to: UInt8.self).baseAddress, count)
        }
        return copied == count ? data : nil
    }
    public func input(_ text: String, paste: Bool = false) throws { _ = try call("input", ["text": text, "paste": paste]) }
}
