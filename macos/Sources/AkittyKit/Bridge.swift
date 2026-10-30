import Foundation
import CoreGraphics
import AkittyCore

public enum AkittyError: Error, LocalizedError {
    case core(String)
    public var errorDescription: String? { if case let .core(message) = self { return message }; return nil }
}

public enum CoreBridge {
    /// The core's response envelope, after size and ABI checks, without any JSON parsing.
    static func raw(_ request: [String: Any]) throws -> Data {
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
        return Data(bytes: pointer, count: buffer.len)
    }
    public static func call(_ request: [String: Any]) throws -> Data {
        let data = try raw(request)
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
    /// Source rectangle in image pixels; absent (or a zero width/height) means "to the image edge".
    public let sx: Int?
    public let sy: Int?
    public let sw: Int?
    public let sh: Int?
    /// Offset of the image inside its first cell, in device pixels.
    public let ox: Int?
    public let oy: Int?
    /// The source rectangle clamped to the image, defaulting to the whole image.
    public var sourceRect: CGRect {
        let x = min(max(0, sx ?? 0), w), y = min(max(0, sy ?? 0), h)
        let maxW = w - x, maxH = h - y
        let requestedW = sw ?? maxW, requestedH = sh ?? maxH
        return CGRect(x: x, y: y, width: requestedW <= 0 ? maxW : min(requestedW, maxW), height: requestedH <= 0 ? maxH : min(requestedH, maxH))
    }
}
private struct SnapshotReply: Decodable {
    let version: Int
    let ok: Bool
    let error: String?
    let data: Payload?
    enum Payload: Decodable {
        case unchanged, full(Snapshot)
        private enum Key: String, CodingKey { case changed }
        init(from decoder: Decoder) throws {
            let unchanged = try decoder.container(keyedBy: Key.self).decode(Bool.self, forKey: .changed) == false
            self = unchanged ? .unchanged : .full(try Snapshot(from: decoder))
        }
    }
}
public struct Cursor: Codable, Sendable { public let row: Int; public let col: Int; public let visible: Bool }
public struct Snapshot: Codable, Sendable {
    public let changed: Bool
    public let revision: UInt64
    public let cols: Int
    public let rows: Int
    public let title: String
    /// For a partial snapshot, only the cells of the `dirty` rows; `TerminalSession.snapshot` merges them.
    public internal(set) var cells: [Cell]
    /// For a partial snapshot, the text of the `dirty` rows in order.
    public internal(set) var lines: [String]
    public let partial: Bool?
    public let dirty: [Int]?
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
    /// Active Kitty keyboard flags (1 disambiguate, 2 events, 4 alternates, 8 all keys, 16 text).
    public let kitty_flags: UInt8?
    public let offset: Int
    public let history: Int
    public let clipboard: [String]
    public let error: String?
    public let exited: Bool
    public let exit_code: UInt32?
    public var text: String { lines.joined(separator: "\n") }
    /// This snapshot with a partial one applied: dirty rows replaced, everything else kept.
    func applying(_ partial: Snapshot) -> Snapshot? {
        guard let dirty = partial.dirty, partial.cols == cols, partial.rows == rows, lines.count == rows,
              partial.lines.count == dirty.count, dirty.allSatisfy({ (0..<rows).contains($0) }) else { return nil }
        var result = partial
        var newLines = lines
        for (slot, row) in dirty.enumerated() { newLines[row] = partial.lines[slot] }
        let changed = Set(dirty)
        // Both sides are ordered by row, so merging keeps the order without a sort.
        var merged: [Cell] = []
        merged.reserveCapacity(cells.count + partial.cells.count)
        var kept = cells.lazy.filter { !changed.contains($0.row) }.makeIterator(), incoming = partial.cells.makeIterator()
        var nextKept = kept.next(), nextIncoming = incoming.next()
        while nextKept != nil || nextIncoming != nil {
            if let k = nextKept, nextIncoming == nil || k.row < nextIncoming!.row { merged.append(k); nextKept = kept.next() }
            else if let i = nextIncoming { merged.append(i); nextIncoming = incoming.next() }
        }
        result.cells = merged
        result.lines = newLines
        return result
    }
    /// The openable hyperlink under a cell, if any.
    public func hyperlink(row: Int, col: Int) -> URL? {
        guard let links else { return nil }
        func linked(_ column: Int) -> Cell? { cells.first { $0.row == row && $0.col == column && $0.link != nil } }
        // The spacer half of a wide character belongs to the link of the leading half.
        guard let cell = linked(col) ?? (col > 0 ? linked(col - 1).flatMap { $0.wide ? $0 : nil } : nil),
              let index = cell.link, links.indices.contains(index) else { return nil }
        return LinkPolicy.url(for: links[index])
    }
    public func textOffset(row: Int, col: Int) -> Int {
        let row = min(max(0, row), max(0, rows - 1)), col = min(max(0, col), cols)
        let before = lines.prefix(row).reduce(0) { $0 + $1.utf16.count + 1 }
        // The core omits blank default cells; each one is a single space, so count the gaps as one unit each.
        var present = 0, units = 0
        for cell in cells where cell.row == row && cell.col < col { present += 1; units += cell.text.utf16.count }
        return before + units + (col - present)
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
    /// Snapshots are megabytes on a busy screen, so the envelope is decoded once, directly into `Snapshot`.
    /// Pass the snapshot you hold as `base` (and its revision as `since`) to receive only the rows that changed;
    /// the result is always a complete snapshot.
    public func snapshot(since: UInt64? = nil, base: Snapshot? = nil) throws -> Snapshot? {
        let data: Data = try {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { throw AkittyError.core("Session is closed") }
            var request: [String: Any] = ["op": "snapshot", "id": id]
            if let since { request["since"] = since }
            return try CoreBridge.raw(request)
        }()
        let reply = try JSONDecoder().decode(SnapshotReply.self, from: data)
        guard reply.version == 1 else { throw AkittyError.core("Invalid core response schema") }
        guard reply.ok else { throw AkittyError.core(reply.error ?? "Unknown core failure") }
        switch reply.data {
        case .full(let snapshot):
            guard snapshot.partial == true else { return snapshot }
            // A partial snapshot only makes sense on top of the exact snapshot it was computed against.
            guard let base, base.revision == since, let merged = base.applying(snapshot) else { return try self.snapshot() }
            return merged
        case .unchanged: return nil
        case nil: throw AkittyError.core("Missing response data")
        }
    }
    /// RGBA pixels of a stored graphics image, or nil if it changed size or was removed meanwhile.
    public func imagePixels(_ image: UInt32, width: Int, height: Int) -> Data? {
        // Check the pixel cap before multiplication so even Int.max input fails safely.
        guard width > 0, height > 0, width <= (8 * 1_048_576) / height else { return nil }
        let count = width * height * 4
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
