import AppKit

/// A saved arrangement of windows, tabs and splits with each pane's starting folder.
/// Live processes are never restored. Optional bounded text is shown before a fresh shell starts.
struct WindowLayout: Codable, Equatable {
    struct Window: Codable, Equatable {
        /// x, y, width and height in the screen coordinates NSWindow uses.
        var frame: [Double] = []
        var selectedTab: Int = 0
        var tabs: [Tab] = []
    }
    struct Tab: Codable, Equatable {
        var panes: [Pane] = []
        /// Each pane's share of the split width. Restoring normalises the shares to sum to 1.
        var fractions: [Double] = []
    }
    struct Pane: Codable, Equatable {
        var directory: String = ""
        /// The profile the pane was opened with; nil is the Settings defaults. A profile deleted since restores as defaults.
        var profile: UUID?
        var scrollback: String?
    }
    var name: String = ""
    var windows: [Window] = []
}

/// Decoding is tolerant so a layout saved by an older build (or a hand-edited file) never breaks Settings.
/// Keeping the custom initialisers in extensions preserves the memberwise initialisers that tests and callers use.
extension WindowLayout {
    private enum CodingKeys: String, CodingKey { case name, windows }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? name
        windows = try container.decodeIfPresent([Window].self, forKey: .windows) ?? windows
    }
}
extension WindowLayout.Window {
    private enum CodingKeys: String, CodingKey { case frame, selectedTab, tabs }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frame = try container.decodeIfPresent([Double].self, forKey: .frame) ?? frame
        selectedTab = try container.decodeIfPresent(Int.self, forKey: .selectedTab) ?? selectedTab
        tabs = try container.decodeIfPresent([WindowLayout.Tab].self, forKey: .tabs) ?? tabs
    }
}
extension WindowLayout.Tab {
    private enum CodingKeys: String, CodingKey { case panes, fractions }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panes = try container.decodeIfPresent([WindowLayout.Pane].self, forKey: .panes) ?? panes
        fractions = try container.decodeIfPresent([Double].self, forKey: .fractions) ?? fractions
    }
}
extension WindowLayout.Pane {
    private enum CodingKeys: String, CodingKey { case directory, profile, scrollback }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? directory
        profile = try? container.decodeIfPresent(UUID.self, forKey: .profile)
        scrollback = try? container.decodeIfPresent(String.self, forKey: .scrollback)
    }
}

enum WindowLayoutError: LocalizedError, Equatable {
    case noWindows
    case invalidName
    case tooManyLayouts
    case tooLarge
    var errorDescription: String? {
        switch self {
        case .noWindows: return "Open at least one terminal window before saving a layout."
        case .invalidName: return "Layout names must be 1–64 characters."
        case .tooManyLayouts: return "Akitty saves at most 20 layouts."
        case .tooLarge: return "The saved layouts exceed the local storage limit. Remove stored scrollback or a layout and try again."
        }
    }
}

/// Persists named layouts in UserDefaults beside the other settings. Every read is bounded and tolerant:
/// damaged data loads as no layouts rather than crashing launch or Settings.
enum WindowLayoutStore {
    static let key = "windowLayouts"
    static let maxLayouts = 20
    static let maxWindows = 8
    static let maxTabs = 16
    static let maxPanes = 8
    static let maxNameLength = 64
    static let maxStoreBytes = 4 * 1024 * 1024

    static func load(from defaults: UserDefaults = .standard) -> [WindowLayout] {
        guard let data = defaults.data(forKey: key), data.count <= maxStoreBytes,
              let decoded = try? JSONDecoder().decode([WindowLayout].self, from: data) else { return [] }
        return decoded.prefix(maxLayouts).compactMap { layout in
            // A layout without a usable name cannot be selected from the menu, so drop it on load.
            guard let name = validatedName(layout.name) else { return nil }
            var value = layout.clamped()
            value.name = name
            return value
        }
    }

    static func save(_ layouts: [WindowLayout], to defaults: UserDefaults = .standard) throws {
        guard layouts.count <= maxLayouts else { throw WindowLayoutError.tooManyLayouts }
        let values = try layouts.map { layout -> WindowLayout in
            guard let name = validatedName(layout.name) else { throw WindowLayoutError.invalidName }
            var value = layout.clamped()
            value.name = name
            return value
        }
        let data = try JSONEncoder().encode(values)
        guard data.count <= maxStoreBytes else { throw WindowLayoutError.tooLarge }
        defaults.set(data, forKey: key)
    }

    /// Replaces a layout with the same name case-insensitively, or appends a new one. A name that trims to
    /// empty (or exceeds the limit) is ignored, so callers that need an error validate first.
    /// Adding a 21st layout drops the oldest, so saving never grows the store past its cap.
    @discardableResult static func upsert(_ layout: WindowLayout, in defaults: UserDefaults = .standard) -> Bool {
        guard let name = validatedName(layout.name) else { return false }
        var stored = load(from: defaults)
        var value = layout.clamped()
        value.name = name
        if let index = stored.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            stored[index] = value
        } else {
            if stored.count >= maxLayouts { stored.removeFirst() }
            stored.append(value)
        }
        do { try save(stored, to: defaults); return true } catch { return false }
    }

    static func removeScrollback(named name: String, from defaults: UserDefaults = .standard) throws {
        var stored = load(from: defaults)
        for index in stored.indices where stored[index].name.caseInsensitiveCompare(name) == .orderedSame {
            for window in stored[index].windows.indices {
                for tab in stored[index].windows[window].tabs.indices {
                    for pane in stored[index].windows[window].tabs[tab].panes.indices {
                        stored[index].windows[window].tabs[tab].panes[pane].scrollback = nil
                    }
                }
            }
        }
        try save(stored, to: defaults)
    }

    static func delete(named name: String, from defaults: UserDefaults = .standard) {
        var stored = load(from: defaults)
        stored.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        try? save(stored, to: defaults)
    }

    /// The trimmed name, or nil when it is empty or longer than the limit.
    static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { return nil }
        return trimmed
    }
}

extension WindowLayout {
    /// Truncates every collection to its limit and leaves at least one tab and pane, so a decoded layout can
    /// always be opened even when a hand-edited file omitted them.
    func clamped() -> Self {
        var value = self
        value.windows = Array(windows.prefix(WindowLayoutStore.maxWindows)).map { $0.clamped() }
        // Share the layout budget so a large arrangement keeps a recent tail for every pane.
        let count = value.windows.reduce(0) { $0 + $1.tabs.reduce(0) { $0 + $1.panes.count } }
        let perPane = min(16384, 128 * 1024 / max(1, count))
        for window in value.windows.indices {
            for tab in value.windows[window].tabs.indices {
                for pane in value.windows[window].tabs[tab].panes.indices {
                    let text = SavedLayoutText.bounded(value.windows[window].tabs[tab].panes[pane].scrollback ?? "", maxBytes: perPane)
                    value.windows[window].tabs[tab].panes[pane].scrollback = text.isEmpty ? nil : text
                }
            }
        }
        return value
    }
}

enum SavedLayoutText {
    static func bounded(_ text: String, maxBytes: Int = 16384) -> String {
        guard maxBytes > 0 else { return "" }
        let plain = String(text.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) })
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).joined(separator: "\n")
        var bytes = 0
        let suffix = lines.unicodeScalars.reversed().prefix { scalar in
            bytes += scalar.utf8.count
            return bytes <= maxBytes
        }
        return String(String.UnicodeScalarView(suffix.reversed()))
    }
}

extension WindowLayout.Window {
    func clamped() -> Self {
        var value = self
        value.frame = Array(frame.prefix(4))
        value.tabs = Array(tabs.prefix(WindowLayoutStore.maxTabs)).map { $0.clamped() }
        if value.tabs.isEmpty { value.tabs = [WindowLayout.Tab()] }
        value.selectedTab = min(max(0, selectedTab), value.tabs.count - 1)
        return value
    }
}

extension WindowLayout.Tab {
    func clamped() -> Self {
        var value = self
        value.panes = Array(panes.prefix(WindowLayoutStore.maxPanes))
        if value.panes.isEmpty { value.panes = [WindowLayout.Pane()] }
        let count = value.panes.count
        // A saved share list that no longer matches the panes (or holds only zeroes) becomes equal shares.
        let shares = fractions.count == count ? fractions.map { $0.isFinite && $0 > 0 ? $0 : 0 } : []
        // Scale before summing so even finite saved weights cannot overflow their total.
        let largest = shares.max() ?? 0
        let scaled = largest > 0 ? shares.map { $0 / largest } : []
        let total = scaled.reduce(0, +)
        value.fractions = total > 0 ? scaled.map { $0 / total } : Array(repeating: 1 / Double(count), count: count)
        return value
    }
}

/// Restoring geometry keeps the reachable-window guarantees the window itself enforces: never smaller than the
/// window's minimum size, and never positioned entirely off every display.
@MainActor enum WindowLayoutGeometry {
    static let minimumSize = NSSize(width: 400, height: 250)

    static func restoredFrame(_ values: [Double]) -> NSRect {
        func component(_ index: Int, _ fallback: CGFloat) -> CGFloat {
            guard values.indices.contains(index), values[index].isFinite else { return fallback }
            return CGFloat(values[index])
        }
        var frame = NSRect(x: component(0, 0), y: component(1, 0),
                           width: max(minimumSize.width, component(2, 1000)),
                           height: max(minimumSize.height, component(3, 650)))
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.contains(where: { $0.intersects(frame) }) else { return frame }
        // Headless test hosts can have no screens; then the clamped frame is the best available answer.
        if let main = NSScreen.main?.visibleFrame ?? screens.first {
            frame.origin = NSPoint(x: main.midX - frame.width / 2, y: main.midY - frame.height / 2)
        }
        return frame
    }
}
