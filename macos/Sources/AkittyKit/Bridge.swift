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
    public func textOffset(row: Int, col: Int) -> Int {
        let row = min(max(0, row), rows - 1)
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
    public func input(_ text: String, paste: Bool = false) throws { _ = try call("input", ["text": text, "paste": paste]) }
}
