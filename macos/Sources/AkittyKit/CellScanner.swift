import Foundation

/// Reads a snapshot reply's `data.cells` array by hand. On a full 200x50 screen JSONDecoder spends most of its time
/// creating a container per cell; this reads the same positional cells (see `Cell.init(from:)`) in one pass.
/// Anything it does not expect makes it return nil, and the caller decodes everything with JSONDecoder instead.
enum CellScanner {
    /// The reply with `data.cells` replaced by `[]`, and the cells it held; nil when there is no cell array or it
    /// could not be read.
    static func split(_ data: Data) -> (rest: Data, cells: [Cell])? {
        data.withUnsafeBytes { raw -> (Data, [Cell])? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var reader = Reader(p: base, end: raw.count)
            guard let (range, cells) = reader.findCells() else { return nil }
            var rest = Data(capacity: data.count - range.count + 2)
            rest.append(base, count: range.lowerBound)
            rest.append(contentsOf: [UInt8(ascii: "["), UInt8(ascii: "]")])
            rest.append(base + range.upperBound, count: raw.count - range.upperBound)
            return (rest, cells)
        }
    }

    private struct Reader {
        let p: UnsafePointer<UInt8>
        let end: Int
        var i = 0
        /// Neighbouring cells mostly share colours, so each colour's array is built once and shared.
        var colors: [UInt32: [UInt8]] = [:]

        mutating func findCells() -> (Range<Int>, [Cell])? {
            guard eat(UInt8(ascii: "{")) else { return nil }
            while let key = string(), eat(UInt8(ascii: ":")) {
                if key == "data" {
                    ws()
                    guard i < end, p[i] == UInt8(ascii: "{") else { return nil }
                    i += 1
                    while let inner = string(), eat(UInt8(ascii: ":")) {
                        if inner == "cells" {
                            ws()
                            let start = i
                            guard let cells = cells() else { return nil }
                            return (start..<i, cells)
                        }
                        guard skip(), eat(UInt8(ascii: ",")) else { return nil }
                    }
                    return nil
                }
                guard skip(), eat(UInt8(ascii: ",")) else { return nil }
            }
            return nil
        }

        mutating func cells() -> [Cell]? {
            guard eat(UInt8(ascii: "[")) else { return nil }
            var cells: [Cell] = []
            if eat(UInt8(ascii: "]")) { return cells }
            // Every cell is at least `[0,0,"",0,0,0]`, 14 bytes; reserving from that avoids regrowing.
            cells.reserveCapacity((end - i) / 16)
            repeat {
                guard let cell = cell() else { return nil }
                cells.append(cell)
            } while eat(UInt8(ascii: ","))
            return eat(UInt8(ascii: "]")) ? cells : nil
        }

        mutating func cell() -> Cell? {
            let comma = UInt8(ascii: ",")
            guard eat(UInt8(ascii: "[")), let row = int(), eat(comma), let col = int(), eat(comma), let text = string(), eat(comma),
                  let fg = color(), eat(comma), let bg = color(), eat(comma), let attrs = int(), let attrs = UInt16(exactly: attrs) else { return nil }
            var ucolor: [UInt8]?, link: Int?
            if eat(comma) {
                if literal("null") { ucolor = nil } else { guard let value = color() else { return nil }; ucolor = value }
                if eat(comma) { guard let value = int() else { return nil }; link = value }
            }
            guard eat(UInt8(ascii: "]")) else { return nil }
            return Cell(row: row, col: col, text: text, fg: fg, bg: bg, attrs: attrs, ucolor: ucolor, link: link)
        }

        mutating func color() -> [UInt8]? {
            guard let value = int(), let packed = UInt32(exactly: value) else { return nil }
            if let known = colors[packed] { return known }
            let rgb = Cell.rgb(packed)
            if colors.count < 4096 { colors[packed] = rgb }
            return rgb
        }

        mutating func ws() {
            while i < end, p[i] == 0x20 || p[i] == 0x0a || p[i] == 0x0d || p[i] == 0x09 { i += 1 }
        }

        mutating func eat(_ byte: UInt8) -> Bool {
            ws()
            guard i < end, p[i] == byte else { return false }
            i += 1
            return true
        }

        mutating func literal(_ word: StaticString) -> Bool {
            ws()
            let count = word.utf8CodeUnitCount
            guard end - i >= count, memcmp(p + i, word.utf8Start, count) == 0 else { return false }
            i += count
            return true
        }

        /// A JSON integer; a fraction, exponent or more than 18 digits is left to JSONDecoder.
        mutating func int() -> Int? {
            ws()
            let negative = i < end && p[i] == UInt8(ascii: "-")
            if negative { i += 1 }
            let start = i
            var value = 0
            while i < end, p[i] >= 0x30, p[i] <= 0x39 { value = value &* 10 &+ Int(p[i] - 0x30); i += 1 }
            guard i > start, i - start <= 18, i - start == 1 || p[start] != 0x30 else { return nil }
            if i < end, p[i] == UInt8(ascii: ".") || p[i] == UInt8(ascii: "e") || p[i] == UInt8(ascii: "E") { return nil }
            return negative ? -value : value
        }

        mutating func string() -> String? {
            guard eat(UInt8(ascii: "\"")) else { return nil }
            let start = i
            while i < end {
                switch p[i] {
                case UInt8(ascii: "\""):
                    defer { i += 1 }
                    return String(bytes: UnsafeBufferPointer(start: p + start, count: i - start), encoding: .utf8)
                case UInt8(ascii: "\\"):
                    i = start
                    return escapedString()
                case 0..<0x20:
                    return nil
                default:
                    i += 1
                }
            }
            return nil
        }

        /// The slow path for a string with escapes, from just after its opening quote.
        mutating func escapedString() -> String? {
            var bytes: [UInt8] = []
            while i < end {
                let byte = p[i]; i += 1
                switch byte {
                case UInt8(ascii: "\""): return String(bytes: bytes, encoding: .utf8)
                case 0..<0x20: return nil
                case UInt8(ascii: "\\"):
                    guard i < end else { return nil }
                    let escape = p[i]; i += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): bytes.append(escape)
                    case UInt8(ascii: "b"): bytes.append(0x08)
                    case UInt8(ascii: "f"): bytes.append(0x0c)
                    case UInt8(ascii: "n"): bytes.append(0x0a)
                    case UInt8(ascii: "r"): bytes.append(0x0d)
                    case UInt8(ascii: "t"): bytes.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var unit = hex4() else { return nil }
                        var scalar: Unicode.Scalar?
                        if (0xd800..<0xdc00).contains(unit) {
                            // A high surrogate must be followed by an escaped low one.
                            guard end - i >= 6, p[i] == UInt8(ascii: "\\"), p[i + 1] == UInt8(ascii: "u") else { return nil }
                            i += 2
                            guard let low = hex4(), (0xdc00..<0xe000).contains(low) else { return nil }
                            unit = 0x10000 + ((unit - 0xd800) << 10) + (low - 0xdc00)
                        }
                        scalar = Unicode.Scalar(unit)
                        guard let scalar else { return nil }
                        bytes.append(contentsOf: Array(String(scalar).utf8))
                    default: return nil
                    }
                default: bytes.append(byte)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard end - i >= 4 else { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = p[i]; i += 1
                let digit: UInt8
                switch byte {
                case 0x30...0x39: digit = byte - 0x30
                case 0x61...0x66: digit = byte - 0x61 + 10
                case 0x41...0x46: digit = byte - 0x41 + 10
                default: return nil
                }
                value = value << 4 | UInt32(digit)
            }
            return value
        }

        /// Skips one value of any type.
        mutating func skip(depth: Int = 0) -> Bool {
            guard depth < 128 else { return false }
            ws()
            guard i < end else { return false }
            switch p[i] {
            case UInt8(ascii: "\""): return string() != nil
            case UInt8(ascii: "{"):
                i += 1
                if eat(UInt8(ascii: "}")) { return true }
                repeat { guard string() != nil, eat(UInt8(ascii: ":")), skip(depth: depth + 1) else { return false } } while eat(UInt8(ascii: ","))
                return eat(UInt8(ascii: "}"))
            case UInt8(ascii: "["):
                i += 1
                if eat(UInt8(ascii: "]")) { return true }
                repeat { guard skip(depth: depth + 1) else { return false } } while eat(UInt8(ascii: ","))
                return eat(UInt8(ascii: "]"))
            default:
                // A number, true, false or null; JSONDecoder validates it when it reads the rest.
                let start = i
                while i < end, !(p[i] == UInt8(ascii: ",") || p[i] == UInt8(ascii: "]") || p[i] == UInt8(ascii: "}") || p[i] <= 0x20) { i += 1 }
                return i > start
            }
        }
    }
}
