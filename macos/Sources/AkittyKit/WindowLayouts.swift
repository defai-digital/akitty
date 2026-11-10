import AppKit

/// A saved arrangement of windows, tabs and splits. Only the shape and each pane's starting folder are stored;
/// live processes and scrollback are deliberately absent, because restoring those is a separate capability.
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
    private enum CodingKeys: String, CodingKey { case directory, profile }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? directory
        profile = try? container.decodeIfPresent(UUID.self, forKey: .profile)
    }
}

enum WindowLayoutError: LocalizedError, Equatable {
    case noWindows
    case invalidName
    case tooManyLayouts
    var errorDescription: String? {
        switch self {
        case .noWindows: return "Open at least one terminal window before saving a layout."
        case .invalidName: return "Layout names must be 1–64 characters."
        case .tooManyLayouts: return "Akitty saves at most 20 layouts."
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

    static func load(from defaults: UserDefaults = .standard) -> [WindowLayout] {
        guard let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([WindowLayout].self, from: data) else { return [] }
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
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }

    /// Replaces a layout with the same name case-insensitively, or appends a new one. A name that trims to
    /// empty (or exceeds the limit) is ignored, so callers that need an error validate first.
    /// Adding a 21st layout drops the oldest, so saving never grows the store past its cap.
    static func upsert(_ layout: WindowLayout, in defaults: UserDefaults = .standard) {
        guard let name = validatedName(layout.name) else { return }
        var stored = load(from: defaults)
        var value = layout.clamped()
        value.name = name
        if let index = stored.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            stored[index] = value
        } else {
            if stored.count >= maxLayouts { stored.removeFirst() }
            stored.append(value)
        }
        try? save(stored, to: defaults)
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
        return value
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
        let total = shares.reduce(0, +)
        value.fractions = total > 0 ? shares.map { $0 / total } : Array(repeating: 1 / Double(count), count: count)
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
