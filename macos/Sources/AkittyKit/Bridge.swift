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
    /// A visible literal find hit. `activeSearch` is the hit next/previous last landed on.
    public let search: Bool
    public let activeSearch: Bool
    public let wide: Bool
    /// 1 single, 2 double, 3 curly, 4 dotted, 5 dashed; absent when the cell is not underlined.
    public let ustyle: UInt8?
    public let ucolor: [UInt8]?
    public let strike: Bool?
    /// Index into `Snapshot.links` for OSC 8 hyperlinks.
    public let link: Int?
    /// A copy without the selection attribute. The core ABI has no deselect operation, so the
    /// host, which is the only caller of `select`, clears the cached mark when it drops a selection.
    func clearingSelection() -> Cell {
        guard selected else { return self }
        let attrs: UInt16 = (bold ? 1 : 0) | (italic ? 2 : 0) | (underline ? 4 : 0) | (wide ? 16 : 0)
            | (strike == true ? 32 : 0) | (search ? 64 : 0) | (activeSearch ? 128 : 0) | UInt16(ustyle ?? 0) << 8
        return Cell(row: row, col: col, text: text, fg: fg, bg: bg, attrs: attrs, ucolor: ucolor, link: link)
    }
    /// The core sends a cell as `[row, col, text, fg, bg, attrs]`, then `ucolor` (or null) and `link` when set.
    /// Colours are packed 0xRRGGBB; `attrs` bits are 1 bold, 2 italic, 4 underline, 8 selected, 16 wide,
    /// 32 strike, 64 search, 128 active search, with the underline style in bits 8-10.
    /// Positional cells decode several times faster than keyed ones.
    private enum CodingKeys: String, CodingKey { case row, col, text, fg, bg, bold, italic, underline, selected, wide, strike, search, active_search, ustyle, ucolor, link }
    public init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            var attrs: UInt16 = 0
            for (key, flag): (CodingKeys, UInt16) in [(.bold, 1), (.italic, 2), (.underline, 4), (.selected, 8), (.wide, 16)] {
                if try c.decode(Bool.self, forKey: key) { attrs |= flag }
            }
            for (key, flag): (CodingKeys, UInt16) in [(.strike, 32), (.search, 64), (.active_search, 128)] {
                if try c.decodeIfPresent(Bool.self, forKey: key) == true { attrs |= flag }
            }
            attrs |= UInt16(try c.decodeIfPresent(UInt8.self, forKey: .ustyle) ?? 0) << 8
            self.init(row: try c.decode(Int.self, forKey: .row), col: try c.decode(Int.self, forKey: .col),
                      text: try c.decode(String.self, forKey: .text), fg: try c.decode([UInt8].self, forKey: .fg),
                      bg: try c.decode([UInt8].self, forKey: .bg), attrs: attrs,
                      ucolor: try c.decodeIfPresent([UInt8].self, forKey: .ucolor), link: try c.decodeIfPresent(Int.self, forKey: .link))
            return
        }
        var c = try decoder.unkeyedContainer()
        let row = try c.decode(Int.self), col = try c.decode(Int.self), text = try c.decode(String.self)
        let fg = Self.rgb(try c.decode(UInt32.self)), bg = Self.rgb(try c.decode(UInt32.self)), attrs = try c.decode(UInt16.self)
        let ucolor = c.isAtEnd ? nil : try c.decodeNil() ? nil : Self.rgb(try c.decode(UInt32.self))
        self.init(row: row, col: col, text: text, fg: fg, bg: bg, attrs: attrs, ucolor: ucolor, link: c.isAtEnd ? nil : try c.decode(Int.self))
    }
    /// A cell from its wire fields. The positional decoder and a hand-written reader share this mapping.
    init(row: Int, col: Int, text: String, fg: [UInt8], bg: [UInt8], attrs: UInt16, ucolor: [UInt8]?, link: Int?) {
        self.row = row; self.col = col; self.text = text; self.fg = fg; self.bg = bg; self.ucolor = ucolor; self.link = link
        bold = attrs & 1 != 0
        italic = attrs & 2 != 0
        underline = attrs & 4 != 0
        selected = attrs & 8 != 0
        search = attrs & 64 != 0
        activeSearch = attrs & 128 != 0
        wide = attrs & 16 != 0
        strike = attrs & 32 != 0 ? true : nil
        let style = UInt8(attrs >> 8 & 7)
        ustyle = style == 0 ? nil : style
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(row); try c.encode(col); try c.encode(text); try c.encode(Self.packed(fg)); try c.encode(Self.packed(bg))
        let attrs: UInt16 = (bold ? 1 : 0) | (italic ? 2 : 0) | (underline ? 4 : 0) | (selected ? 8 : 0) | (wide ? 16 : 0)
            | (strike == true ? 32 : 0) | (search ? 64 : 0) | (activeSearch ? 128 : 0) | UInt16(ustyle ?? 0) << 8
        try c.encode(attrs)
        if ucolor != nil || link != nil { if let ucolor { try c.encode(Self.packed(ucolor)) } else { try c.encodeNil() } }
        if let link { try c.encode(link) }
    }
    static func rgb(_ value: UInt32) -> [UInt8] { [UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)] }
    private static func packed(_ rgb: [UInt8]) -> UInt32 { rgb.prefix(3).reduce(0) { $0 << 8 | UInt32($1) } }
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
    /// Destination size inside the placed cells, in device pixels; absent (or non-positive) means the cell rectangle.
    public let dw: Int?
    public let dh: Int?
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

public struct ChromeStatus: Codable, Equatable, Sendable {
    public let text: String
    public let tone: String
}

/// A tab activity mark. A frame index selects a sprite frame; named marks use frame 0.
public enum ChromeMark: Equatable, Sendable {
    case idle, busy, error, frame(Int)
}

extension ChromeMark: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            switch name {
            case "idle": self = .idle
            case "busy": self = .busy
            case "error": self = .error
            default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "chrome mark must be idle, busy, error, or a frame")
            }
            return
        }
        let frame = try container.decode(Int.self)
        guard (0...3).contains(frame) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "chrome mark frame must be 0..3")
        }
        self = .frame(frame)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .idle: try container.encode("idle")
        case .busy: try container.encode("busy")
        case .error: try container.encode("error")
        case .frame(let index): try container.encode(index)
        }
    }
}

public enum ChromeProgress: Equatable, Sendable {
    case fraction(Double)
    case indeterminate
    var label: String {
        switch self {
        case .fraction(let value): return "\(Int((value * 100).rounded()))%"
        case .indeterminate: return "…"
        }
    }
}

extension ChromeProgress: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            guard value.isFinite, (0...1).contains(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "chrome progress out of range")
            }
            self = .fraction(value)
            return
        }
        guard try container.decode(String.self) == "indeterminate" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "chrome progress must be a fraction or indeterminate")
        }
        self = .indeterminate
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .fraction(let value): try container.encode(value)
        case .indeterminate: try container.encode("indeterminate")
        }
    }
}

public struct ChromeSprite: Equatable, Sendable {
    public let w: Int
    public let h: Int
    public let frames: [Data]
}

extension ChromeSprite: Codable {
    enum CodingKeys: String, CodingKey { case w, h, frames }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let w = try container.decode(Int.self, forKey: .w)
        let h = try container.decode(Int.self, forKey: .h)
        let encoded = try container.decode([String].self, forKey: .frames)
        // ABI schema 1: 1 through 32 pixels on each edge and 1 through 4 frames.
        // Validate before multiplying so a hostile size cannot overflow Int and trap.
        guard (1...32).contains(w), (1...32).contains(h) else {
            throw DecodingError.dataCorruptedError(forKey: .w, in: container, debugDescription: "chrome sprite size must be 1..32 by 1..32")
        }
        guard (1...4).contains(encoded.count) else {
            throw DecodingError.dataCorruptedError(forKey: .frames, in: container, debugDescription: "chrome sprite must have 1..4 frames")
        }
        let expected = w * h * 4
        self.w = w
        self.h = h
        frames = try encoded.map { text in
            guard let data = Data(base64Encoded: text), data.count == expected else {
                throw DecodingError.dataCorruptedError(forKey: .frames, in: container, debugDescription: "chrome sprite frame is not inline RGBA8")
            }
            return data
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(w, forKey: .w)
        try container.encode(h, forKey: .h)
        try container.encode(frames.map { $0.base64EncodedString() }, forKey: .frames)
    }
}

/// The current chrome document from a snapshot. Absent fields were omitted by the core.
public struct ChromeDocument: Codable, Equatable, Sendable {
    public let status: ChromeStatus?
    public let mark: ChromeMark?
    public let progress: ChromeProgress?
    public let sprite: ChromeSprite?
    /// Status text and progress, joined for the pane status line. Nil when neither is current.
    var presentation: String? {
        var parts: [String] = []
        if let text = status?.text, !text.isEmpty { parts.append(text) }
        if let progress { parts.append(progress.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    /// True while the program reports work in progress: any progress, or the busy mark.
    var isWorking: Bool { progress != nil || mark == .busy }
    /// Sprite frame to draw. Reduce motion always uses frame 0; a named mark does too.
    func shownPixels(reduceMotion: Bool) -> Data? {
        guard let sprite, let first = sprite.frames.first else { return nil }
        if reduceMotion { return first }
        if case .frame(let index) = mark, sprite.frames.indices.contains(index) { return sprite.frames[index] }
        return first
    }
}

public struct ShellSummary: Codable, Sendable {
    public let cwd: String?
    public let ready: Bool
    public let last_command_id: UInt64
    public let rejected: UInt64
    public let untrusted: Bool
}

public struct Snapshot: Codable, Sendable {
    public let changed: Bool
    public let revision: UInt64
    public let cols: Int
    public let rows: Int
    public let title: String
    public let shell: ShellSummary?
    public let control: ControlSummary?
    /// For a partial snapshot, only the cells of the `dirty` rows; `TerminalSession.snapshot` merges them.
    public internal(set) var cells: [Cell]
    /// For a partial snapshot, the text of the `dirty` rows in order.
    public internal(set) var lines: [String]
    public let partial: Bool?
    public let dirty: [Int]?
    public let links: [String]?
    public let images: [ImagePlacement]?
    /// True while a Kitty graphics animation still needs frames; absent on snapshots from older cores.
    public internal(set) var animating: Bool?
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
    /// A BEL arrived since the previous snapshot.
    public let bell: Bool?
    public let error: String?
    public let exited: Bool
    public let exit_code: UInt32?
    /// Present when a mark, sprite, status, or progress is still current. Omitted by the core otherwise.
    public let chrome: ChromeDocument?
    public var text: String { lines.joined(separator: "\n") }
    /// Drops `selected` marks from this cached snapshot. Used when the host has no selection but
    /// the core still holds one, because schema 1 has no deselect request.
    mutating func clearSelectionMarks() {
        guard cells.contains(where: \.selected) else { return }
        cells = cells.map { $0.clearingSelection() }
    }
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
        // A partial snapshot may not repeat the animation flag, but the animation is still running.
        if result.animating == nil { result.animating = animating }
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
    public init(cols: Int = 100, rows: Int = 30, headless: Bool = false, shell: String? = nil, directory: String? = nil, scrollback: Int = 5000, shellIntegrationDirectory: String? = nil) throws {
        var request: [String: Any] = ["op": "create", "cols": cols, "rows": rows, "headless": headless, "scrollback": scrollback]
        if let shell, !shell.isEmpty { request["shell"] = shell }
        if let directory, !directory.isEmpty { request["cwd"] = directory }
        if let shellIntegrationDirectory { request["shell_integration_dir"] = shellIntegrationDirectory }
        let data = try CoreBridge.call(request)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = value?["id"] as? UInt64 else { throw AkittyError.core("No terminal handle") }
        self.id = id
    }
    deinit { try? close() }
    public func close() throws {
        try close { id in _ = try CoreBridge.call(["op": "close", "id": id]) }
    }
    private func markClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        closed = true; return true
    }
    func close(using request: (UInt64) throws -> Void) throws {
        guard markClosed() else { return }
        try request(id)
    }
    /// Revoke Swift access synchronously, then transfer the bounded core cleanup
    /// to a worker. Removing a pane must not leave a usable session until that worker runs.
    func prepareClose() -> (@Sendable () throws -> Void)? {
        guard markClosed() else { return nil }
        let handle = id
        return { _ = try CoreBridge.call(["op": "close", "id": handle]) }
    }
    public func call(_ op: String, _ values: [String: Any] = [:]) throws -> Data {
        lock.lock()
        guard !closed else { lock.unlock(); throw AkittyError.core("Session is closed") }
        if op == "close" {
            // Mark closed before the call reaches Rust, like `close()`, so late app events
            // see the state immediately. Do not route through `close()`: NSLock is not
            // recursive and it would deadlock. The reply still follows the call contract.
            closed = true
            lock.unlock()
            return try CoreBridge.call(["op": "close", "id": id])
        }
        defer { lock.unlock() }
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
            var request: [String: Any] = ["op": "snapshot", "id": id, "compact": true]
            if let since { request["since"] = since }
            return try CoreBridge.raw(request)
        }()
        // The cells are most of a busy snapshot; they are read by hand and the rest by JSONDecoder.
        let scanned = CellScanner.split(data)
        let reply = try JSONDecoder().decode(SnapshotReply.self, from: scanned?.rest ?? data)
        guard reply.version == 1 else { throw AkittyError.core("Invalid core response schema") }
        guard reply.ok else { throw AkittyError.core(reply.error ?? "Unknown core failure") }
        switch reply.data {
        case .full(var snapshot):
            if let scanned { snapshot.cells = scanned.cells }
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
    public func commandHistory(after: UInt64 = 0) throws -> Data { try call("command_history", ["after": after]) }
    public func commandOutput(_ commandID: UInt64) throws -> Data { try call("command_output", ["command_id": commandID]) }
    public func input(_ text: String, paste: Bool = false) throws { _ = try call("input", ["text": text, "paste": paste]) }
}
