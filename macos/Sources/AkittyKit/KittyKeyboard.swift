import AppKit

/// Kitty keyboard protocol (https://sw.kovidgoyal.net/kitty/keyboard-protocol/).
/// The core tracks the flag stack per screen; this file only turns key events into bytes.
public struct KittyModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KittyModifiers(rawValue: 1)
    public static let alt = KittyModifiers(rawValue: 2)
    public static let ctrl = KittyModifiers(rawValue: 4)
    public static let `super` = KittyModifiers(rawValue: 8)
    public static let hyper = KittyModifiers(rawValue: 16)
    public static let meta = KittyModifiers(rawValue: 32)
    public static let capsLock = KittyModifiers(rawValue: 64)
    public static let numLock = KittyModifiers(rawValue: 128)
    static let locks: KittyModifiers = [.capsLock, .numLock]
}

public enum KittyEventType: Int, Sendable { case press = 1, `repeat` = 2, release = 3 }

public enum KittyKeyResult: Equatable, Sendable {
    /// Send these bytes instead of the legacy encoding.
    case bytes([UInt8])
    /// Not claimed: keep the existing (legacy) key handling.
    case legacy
    /// Nothing to send, and the legacy path must not send anything either.
    case none
}

public struct KittyKeyInput: Sendable, Equatable {
    /// macOS virtual key code; identifies functional, keypad and modifier keys.
    public var keyCode: UInt16
    /// Unshifted code point of a text key, in the active layout.
    public var key: UInt32?
    public var shiftedKey: UInt32?
    /// Code point the same physical key has on a US layout, when it differs from `key`.
    public var baseLayoutKey: UInt32?
    /// Printable text the key produces; empty for control and functional keys.
    public var text: [UInt32]
    public var modifiers: KittyModifiers
    public var event: KittyEventType
    public init(keyCode: UInt16, key: UInt32? = nil, shiftedKey: UInt32? = nil, baseLayoutKey: UInt32? = nil,
                text: [UInt32] = [], modifiers: KittyModifiers = [], event: KittyEventType = .press) {
        self.keyCode = keyCode; self.key = key; self.shiftedKey = shiftedKey; self.baseLayoutKey = baseLayoutKey
        self.text = text; self.modifiers = modifiers; self.event = event
    }
}

public enum KittyKeyEncoder {
    public static let disambiguate = 1, reportEvents = 2, reportAlternates = 4, reportAllKeys = 8, reportText = 16

    /// Keys encoded as `CSI 1;mods X` (letter) or `CSI n;mods ~`.
    private static let functional: [UInt16: (number: Int, final: Character)] = [
        126: (1, "A"), 125: (1, "B"), 124: (1, "C"), 123: (1, "D"), 115: (1, "H"), 119: (1, "F"),
        122: (1, "P"), 120: (1, "Q"), 99: (13, "~"), 118: (1, "S"),
        114: (2, "~"), 117: (3, "~"), 116: (5, "~"), 121: (6, "~"),
        96: (15, "~"), 97: (17, "~"), 98: (18, "~"), 100: (19, "~"), 101: (20, "~"), 109: (21, "~"), 103: (23, "~"), 111: (24, "~"),
    ]
    /// F13-F20 are always `CSI code u` (their letter and tilde forms are taken).
    private static let extraFunction: [UInt16: UInt32] = [105: 57376, 107: 57377, 113: 57378, 106: 57379, 64: 57380, 79: 57381, 80: 57382, 90: 57383]
    /// Escape, Enter, keypad Enter, Tab, Backspace.
    private static let editing: [UInt16: UInt32] = [53: 27, 36: 13, 76: 13, 48: 9, 51: 127]
    private static let keypad: [UInt16: UInt32] = [
        82: 57399, 83: 57400, 84: 57401, 85: 57402, 86: 57403, 87: 57404, 88: 57405, 89: 57406, 91: 57407, 92: 57408,
        65: 57409, 75: 57410, 67: 57411, 78: 57412, 69: 57413, 76: 57414, 81: 57415,
    ]
    /// Modifier keys: key code to (protocol code, modifier).
    public static func modifier(forKeyCode keyCode: UInt16) -> KittyModifiers? { modifierKeys[keyCode]?.modifier }
    private static let modifierKeys: [UInt16: (code: UInt32, modifier: KittyModifiers)] = [
        56: (57441, .shift), 60: (57447, .shift), 59: (57442, .ctrl), 62: (57448, .ctrl),
        58: (57443, .alt), 61: (57449, .alt), 55: (57444, .super), 54: (57450, .super),
    ]

    public static func encode(_ input: KittyKeyInput, flags: Int) -> KittyKeyResult {
        guard flags & 0x1f != 0 else { return .legacy }
        let events = flags & reportEvents != 0, allKeys = flags & reportAllKeys != 0
        let claimsKeys = allKeys || flags & disambiguate != 0
        // Repeats look like presses unless the app asked for event types; releases need that flag.
        if input.event == .release, !events { return .none }
        let significant = input.modifiers.subtracting(.locks)
        // Lock state is only worth reporting when the app asked for every key.
        let modifierValue = 1 + ((allKeys ? input.modifiers : significant).rawValue & 0xff)
        let unclaimed: KittyKeyResult = input.event == .release ? .none : .legacy

        if let function = functional[input.keyCode] {
            if significant.isEmpty, input.event == .press || !events { return .legacy }
            let suffix = events && input.event != .press ? ":\(input.event.rawValue)" : ""
            let mods = significant.isEmpty ? 1 : modifierValue
            let number = function.final == "~" ? "\(function.number)" : "1"
            return .bytes(Array("\u{1b}[\(number);\(mods)\(suffix)\(function.final)".utf8))
        }
        if let code = extraFunction[input.keyCode] {
            guard claimsKeys else { return unclaimed }
            return .bytes(csiU(code: code, shifted: nil, base: nil, input: input, mods: modifierValue, flags: flags, text: []))
        }
        if let base = editing[input.keyCode] {
            let code = allKeys && input.keyCode == 76 ? 57414 : base
            let claimed = (allKeys || (claimsKeys && (base == 27 || !significant.isEmpty)))
            guard claimed else { return unclaimed }
            // Enter, Tab and Backspace report repeats and releases only with "all keys".
            if base != 27, !allKeys, input.event != .press {
                return input.event == .release ? .none : .bytes(csiU(code: code, shifted: nil, base: nil,
                    input: KittyKeyInput(keyCode: input.keyCode, modifiers: input.modifiers), mods: modifierValue, flags: flags, text: []))
            }
            return .bytes(csiU(code: code, shifted: nil, base: nil, input: input, mods: modifierValue, flags: flags, text: []))
        }
        if allKeys, let code = keypad[input.keyCode] {
            return .bytes(csiU(code: code, shifted: nil, base: nil, input: input, mods: modifierValue, flags: flags, text: input.text))
        }
        guard let key = input.key else { return unclaimed }
        // Shift alone produces ordinary text; any other modifier needs the unambiguous form.
        let claimed = allKeys || (claimsKeys && !input.modifiers.subtracting([.locks, .shift]).isEmpty)
        guard claimed else { return unclaimed }
        let shifted = input.modifiers.contains(.shift) ? input.shiftedKey.flatMap { $0 == key ? nil : $0 } : nil
        let base = input.baseLayoutKey.flatMap { $0 == key ? nil : $0 }
        return .bytes(csiU(code: key, shifted: shifted, base: base, input: input, mods: modifierValue, flags: flags, text: input.text))
    }

    /// Press or release of a modifier key on its own; only reported with "all keys as escape codes".
    public static func encodeModifier(keyCode: UInt16, modifiers: KittyModifiers, pressed: Bool, flags: Int) -> KittyKeyResult {
        guard flags & reportAllKeys != 0, let key = modifierKeys[keyCode] else { return .none }
        let events = flags & reportEvents != 0
        if !pressed, !events { return .none }
        let suffix = pressed ? "" : ":3"
        return .bytes(Array("\u{1b}[\(key.code);\(1 + (modifiers.rawValue & 0xff))\(suffix)u".utf8))
    }

    private static func csiU(code: UInt32, shifted: UInt32?, base: UInt32?, input: KittyKeyInput, mods: Int, flags: Int, text: [UInt32]) -> [UInt8] {
        var out = "\u{1b}[\(code)"
        if flags & reportAlternates != 0, shifted != nil || base != nil {
            out += ":" + (shifted.map(String.init) ?? "")
            if let base { out += ":\(base)" }
        }
        let suffix = flags & reportEvents != 0 && input.event != .press ? ":\(input.event.rawValue)" : ""
        let carried = flags & reportText != 0 && flags & reportAllKeys != 0 && input.event != .release ? text : []
        if !carried.isEmpty {
            out += ";" + (mods == 1 && suffix.isEmpty ? "" : "\(mods)\(suffix)") + ";" + carried.map(String.init).joined(separator: ":")
        } else if mods != 1 || !suffix.isEmpty {
            out += ";\(mods)\(suffix)"
        }
        return Array((out + "u").utf8)
    }
}

extension KittyKeyInput {
    /// US-layout unshifted/shifted characters by macOS key code; identifies text keys and base layout keys.
    private static let ansi: [UInt16: (Character, Character)] = [
        0: ("a", "A"), 11: ("b", "B"), 8: ("c", "C"), 2: ("d", "D"), 14: ("e", "E"), 3: ("f", "F"), 5: ("g", "G"), 4: ("h", "H"),
        34: ("i", "I"), 38: ("j", "J"), 40: ("k", "K"), 37: ("l", "L"), 46: ("m", "M"), 45: ("n", "N"), 31: ("o", "O"), 35: ("p", "P"),
        12: ("q", "Q"), 15: ("r", "R"), 1: ("s", "S"), 17: ("t", "T"), 32: ("u", "U"), 9: ("v", "V"), 13: ("w", "W"), 7: ("x", "X"),
        16: ("y", "Y"), 6: ("z", "Z"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 23: ("5", "%"), 22: ("6", "^"),
        26: ("7", "&"), 28: ("8", "*"), 25: ("9", "("), 29: ("0", ")"), 27: ("-", "_"), 24: ("=", "+"), 33: ("[", "{"), 30: ("]", "}"),
        42: ("\\", "|"), 41: (";", ":"), 39: ("'", "\""), 43: (",", "<"), 47: (".", ">"), 44: ("/", "?"), 50: ("`", "~"), 49: (" ", " "),
    ]

    /// Builds the protocol input for a key event. Option counts as Alt only with Option-as-Alt on;
    /// otherwise it composes text (å, π) and the key is left to the legacy path.
    init?(event: NSEvent, optionAsAlt: Bool, type: KittyEventType) {
        var mods: KittyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        if flags.contains(.command) { mods.insert(.super) }
        if flags.contains(.option) {
            if optionAsAlt { mods.insert(.alt) }
            else if Self.ansi[event.keyCode] != nil { return nil }
            else { mods.insert(.alt) }
        }
        let shift = flags.contains(.shift)
        let ignoring = event.charactersIgnoringModifiers?.unicodeScalars.first
        let usable = ignoring.flatMap { $0.value >= 0x20 && $0.value != 0x7f && !(0xF700...0xF8FF).contains($0.value) ? $0 : nil }
        let us = Self.ansi[event.keyCode]
        var key: UInt32?
        if let usable, usable.properties.isAlphabetic {
            key = String(usable).lowercased().unicodeScalars.first?.value
        } else if let usable, !shift {
            key = usable.value
        } else if let us {
            key = us.0.unicodeScalars.first?.value
        }
        let typed = (event.characters ?? "").unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f && !(0xF700...0xF8FF).contains($0.value) }
        let produced = type == .release || flags.contains(.control) || flags.contains(.command) ? [] : typed.map(\.value)
        self.init(keyCode: event.keyCode, key: key,
                  shiftedKey: shift ? (typed.first?.value ?? us?.1.unicodeScalars.first?.value) : nil,
                  baseLayoutKey: us?.0.unicodeScalars.first?.value, text: produced, modifiers: mods, event: type)
    }

    /// Modifier state after a `flagsChanged` event, for modifier-only keys.
    static func modifiers(of flags: NSEvent.ModifierFlags, optionAsAlt: Bool) -> KittyModifiers {
        var mods: KittyModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option), optionAsAlt { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.super) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }
        return mods
    }
}
