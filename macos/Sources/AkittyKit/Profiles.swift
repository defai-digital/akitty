import AppKit

/// A built-in colour theme. The core resolves cell colours from it; the host clears frames to its background
/// and draws the cursor in its cursor colour. `nil` colours keep the core's built-in defaults.
struct TerminalTheme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let foreground: UInt32?
    let background: UInt32?
    let cursor: UInt32?
    let selection: UInt32?
    let ansi: [UInt32]

    static let defaultID = "akitty-dark"
    static let all: [TerminalTheme] = [
        TerminalTheme(id: defaultID, name: "AkiTTY Dark", foreground: nil, background: nil, cursor: nil, selection: nil, ansi: []),
        TerminalTheme(id: "akitty-light", name: "AkiTTY Light", foreground: 0x1f2328, background: 0xfafafa, cursor: 0x0969da, selection: 0xb6d7ff,
                      ansi: [0x24292f, 0xcf222e, 0x116329, 0x7d4e00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                             0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f]),
        TerminalTheme(id: "solarized-dark", name: "Solarized Dark", foreground: 0x839496, background: 0x002b36, cursor: 0x93a1a1, selection: 0x174652,
                      ansi: [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                             0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3]),
        TerminalTheme(id: "high-contrast", name: "High Contrast", foreground: 0xffffff, background: 0x000000, cursor: 0xffff00, selection: 0x1f4fa8,
                      ansi: [0x000000, 0xff5555, 0x55ff55, 0xffff55, 0x6a8cff, 0xff55ff, 0x55ffff, 0xe5e5e5,
                             0x7f7f7f, 0xff8080, 0x80ff80, 0xffff80, 0x9db4ff, 0xff80ff, 0x80ffff, 0xffffff])
    ]
    /// An unknown identifier (a theme removed in a later version) falls back to the default theme.
    static func named(_ id: String) -> TerminalTheme { all.first { $0.id == id } ?? all[0] }

    /// The `theme` core request. The default theme sends no colours, which restores the built-in baseline.
    var request: [String: Any] {
        var fields: [String: Any] = [:]
        if let foreground { fields["foreground"] = foreground }
        if let background { fields["background"] = background }
        if let cursor { fields["cursor"] = cursor }
        if !ansi.isEmpty { fields["ansi"] = ansi }
        return fields
    }
    func appearance(cursorStyle: CursorStyle) -> RenderAppearance {
        var appearance = RenderAppearance.standard
        func bytes(_ rgb: UInt32) -> [UInt8] { [UInt8(rgb >> 16 & 0xff), UInt8(rgb >> 8 & 0xff), UInt8(rgb & 0xff)] }
        if let background { appearance.background = bytes(background) }
        if let cursor { appearance.cursor = bytes(cursor) }
        if let selection { appearance.selection = bytes(selection) }
        if let foreground { appearance.foreground = bytes(foreground) }
        appearance.cursorStyle = cursorStyle
        return appearance
    }
    var backgroundColor: NSColor {
        let rgb = background ?? 0x080a0d
        return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

/// A named set of appearance and session settings. A pane opened with a profile uses these values in place of the
/// Settings defaults; everything a profile does not name (CJK font, keyboard, alerts, integration) still follows
/// Settings. Without profiles AkiTTY behaves exactly as before.
struct TerminalProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var fontName: String
    var fontSize: Double
    var theme: String
    var cursorStyle: CursorStyle
    var shell: String
    var directory: String
    var scrollback: Int

    static let maximumCount = 32
    static let maximumNameLength = 40

    /// A new profile starts as a copy of the current defaults.
    init(name: String, from base: TerminalPreferences) {
        self.name = name
        fontName = base.fontName; fontSize = base.fontSize; theme = base.theme; cursorStyle = base.cursorStyle
        shell = base.shell; directory = base.directory; scrollback = base.scrollback
    }
    func applied(to base: TerminalPreferences) -> TerminalPreferences {
        var value = base
        value.fontName = fontName; value.fontSize = fontSize; value.theme = theme; value.cursorStyle = cursorStyle
        value.shell = shell; value.directory = directory; value.scrollback = scrollback
        return value
    }
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private enum CodingKeys: String, CodingKey { case id, name, fontName, fontSize, theme, cursorStyle, shell, directory, scrollback }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TerminalPreferences()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? fallback.fontName
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? fallback.fontSize
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? fallback.theme
        // An unknown cursor style from a newer version keeps the default rather than dropping the profile.
        cursorStyle = (try? container.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle)) ?? fallback.cursorStyle
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? fallback.shell
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? fallback.directory
        scrollback = try container.decodeIfPresent(Int.self, forKey: .scrollback) ?? fallback.scrollback
    }
}

extension TerminalPreferences {
    func profile(_ id: UUID?) -> TerminalProfile? { id.flatMap { id in profiles.first { $0.id == id } } }
    /// The settings a pane opened with `profile` uses. A profile deleted since falls back to the defaults.
    func effective(profile id: UUID?) -> TerminalPreferences { profile(id)?.applied(to: self) ?? self }
    /// A name not yet used by another profile: "Profile", "Profile 2", …
    /// The result always fits the name limit, so a copy of a long-named profile can still be applied.
    func unusedProfileName(_ base: String = "Profile") -> String {
        let taken = Set(profiles.map { $0.trimmedName.lowercased() })
        let limit = TerminalProfile.maximumNameLength
        let base = String(base.prefix(limit)).trimmingCharacters(in: .whitespaces)
        if !taken.contains(base.lowercased()) { return base }
        return (2...).lazy.map { number in
            let suffix = " \(number)"
            return String(base.prefix(limit - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
        }.first { !taken.contains($0.lowercased()) }!
    }
    func validateProfiles() throws {
        guard profiles.count <= TerminalProfile.maximumCount else { throw AkittyError.core("Keep at most \(TerminalProfile.maximumCount) profiles.") }
        var names = Set<String>()
        for profile in profiles {
            let name = profile.trimmedName
            guard !name.isEmpty, name.count <= TerminalProfile.maximumNameLength else { throw AkittyError.core("Profile names must be 1–\(TerminalProfile.maximumNameLength) characters.") }
            guard names.insert(name.lowercased()).inserted else { throw AkittyError.core("Profile names must be unique (\(name)).") }
            do { _ = try profile.applied(to: self).validatedFields() }
            catch { throw AkittyError.core("Profile \(name): \(error.localizedDescription)") }
        }
    }
}
