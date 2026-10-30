import AppKit
import SwiftUI

struct TerminalPreferences: Codable, Equatable {
    var fontName = "System Monospaced"
    /// Empty means Automatic: the renderer follows the system language's preferred CJK face.
    var cjkFont = ""
    var fontSize = 14.0
    var shell = ""
    var directory = ""
    var scrollback = 5000
    var optionAsAlt = false
    /// Programs may update chrome only when this preference is enabled.
    var programChrome = true
    /// The system monospace face, then every installed fixed-pitch family, so CJK-optimised monospace fonts are selectable.
    @MainActor static func availableFonts() -> [String] {
        var families = Set<String>()
        for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            if let family = NSFont(name: name, size: 12)?.familyName { families.insert(family) }
        }
        for name in ["Menlo", "Monaco", "Courier"] where NSFont(name: name, size: 12) != nil { families.insert(name) }
        return ["System Monospaced"] + families.sorted()
    }
    /// CJK candidates for the picker; only the faces actually installed on this Mac.
    @MainActor static func availableCJKFonts() -> [String] {
        ["PingFang SC", "PingFang TC", "PingFang HK", "Hiragino Sans", "Apple SD Gothic Neo", "Songti SC", "STHeiti", "Sarasa Mono SC", "Noto Sans Mono CJK SC"].filter { NSFont(name: $0, size: 12) != nil }
    }
    private static func installed(_ name: String) -> Bool { name == "System Monospaced" || NSFont(name: name, size: 12) != nil }
    private static func validShell(_ path: String) -> Bool {
        if path.isEmpty { return true }
        var isDirectory: ObjCBool = false
        // Execute permission on a directory means traversal, not a runnable shell.
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
    func validated() throws -> Self {
        guard Self.installed(fontName), fontSize.isFinite, (9...36).contains(fontSize), (0...20000).contains(scrollback) else { throw AkittyError.core("Choose a supported font, size 9–36, and scrollback 0–20,000.") }
        guard cjkFont.isEmpty || NSFont(name: cjkFont, size: 12) != nil else { throw AkittyError.core("Choose an installed CJK font, or Automatic.") }
        guard Self.validShell(shell) else { throw AkittyError.core("Shell must be an absolute path to an executable, without arguments.") }
        if !directory.isEmpty {
            var isDirectory: ObjCBool = false
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw AkittyError.core("Choose an existing absolute starting directory.") }
        }
        return self
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "terminalPreferences"), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if let valid = try? value.validated() { return valid }
        // Recover each invalid field independently, preserving other saved settings.
        let fallback = Self()
        var isDirectory: ObjCBool = false
        if !Self.installed(value.fontName) { value.fontName = fallback.fontName }
        if !value.cjkFont.isEmpty, NSFont(name: value.cjkFont, size: 12) == nil { value.cjkFont = fallback.cjkFont }
        if !value.fontSize.isFinite || !(9...36).contains(value.fontSize) { value.fontSize = fallback.fontSize }
        if !(0...20000).contains(value.scrollback) { value.scrollback = fallback.scrollback }
        if !Self.validShell(value.shell) { value.shell = fallback.shell }
        if !value.directory.isEmpty, !(value.directory.hasPrefix("/") && FileManager.default.fileExists(atPath: value.directory, isDirectory: &isDirectory) && isDirectory.boolValue) { value.directory = fallback.directory }
        return (try? value.validated()) ?? fallback
    }
    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(validated()), forKey: "terminalPreferences")
        NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
    }
}
extension Notification.Name { static let terminalPreferencesChanged = Notification.Name("AkittyTerminalPreferencesChanged") }

extension TerminalPreferences {
    private enum CodingKeys: String, CodingKey {
        case fontName, cjkFont, fontSize, shell, directory, scrollback, optionAsAlt, programChrome
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        cjkFont = try container.decodeIfPresent(String.self, forKey: .cjkFont) ?? cjkFont
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? shell
        directory = try container.decodeIfPresent(String.self, forKey: .directory) ?? directory
        scrollback = try container.decodeIfPresent(Int.self, forKey: .scrollback) ?? scrollback
        optionAsAlt = try container.decodeIfPresent(Bool.self, forKey: .optionAsAlt) ?? optionAsAlt
        // Missing on preferences saved before this switch existed. Default on so current sessions keep program chrome.
        programChrome = try container.decodeIfPresent(Bool.self, forKey: .programChrome) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fontName, forKey: .fontName)
        try container.encode(cjkFont, forKey: .cjkFont)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(shell, forKey: .shell)
        try container.encode(directory, forKey: .directory)
        try container.encode(scrollback, forKey: .scrollback)
        try container.encode(optionAsAlt, forKey: .optionAsAlt)
        try container.encode(programChrome, forKey: .programChrome)
    }
}

@MainActor private struct PreferencesView: View {
    @State private var draft = TerminalPreferences.load()
    @State private var automaticChecks: Bool
    @State private var error = ""
    let updater: UpdateController
    init(updater: UpdateController) {
        self.updater = updater
        _automaticChecks = State(initialValue: updater.automaticChecks)
    }
    /// Keep a saved face selectable even when it is not installed any more, so the picker round-trips it.
    private var fontChoices: [String] {
        let fonts = TerminalPreferences.availableFonts()
        return fonts.contains(draft.fontName) ? fonts : fonts + [draft.fontName]
    }
    private var cjkChoices: [String] {
        let fonts = TerminalPreferences.availableCJKFonts()
        return draft.cjkFont.isEmpty || fonts.contains(draft.cjkFont) ? fonts : fonts + [draft.cjkFont]
    }
    var body: some View {
        VStack(spacing: 0) {
            TabView {
                Form {
                    Section("Appearance") {
                        Picker("Font", selection: $draft.fontName) { ForEach(fontChoices, id: \.self) { Text($0) } }
                        Picker("CJK font", selection: $draft.cjkFont) {
                            Text("Automatic").tag("")
                            ForEach(cjkChoices, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Chinese, Japanese and Korean text. Automatic follows your system language.").font(.caption).foregroundStyle(.secondary)
                        Stepper("Font size: \(Int(draft.fontSize)) pt", value: $draft.fontSize, in: 9...36)
                        Text("Applies to open terminals. ⌘+ and ⌘− adjust an individual pane.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Appearance") }
                Form {
                    Section("New Terminals") {
                        TextField("Shell", text: $draft.shell, prompt: Text("Default login shell"))
                        HStack {
                            TextField("Starting directory", text: $draft.directory, prompt: Text("Home directory"))
                                .accessibilityIdentifier("starting-directory")
                            Button("Clear") { draft.directory = "" }
                                .disabled(draft.directory.isEmpty)
                                .help("Use your home directory for new terminals")
                                .accessibilityIdentifier("clear-starting-directory")
                            Button("Choose…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK { draft.directory = panel.url?.path ?? "" }
                            }
                        }
                        Stepper("Scrollback: \(draft.scrollback) lines", value: $draft.scrollback, in: 0...20000, step: 1000)
                        Text("Shell, directory and scrollback changes apply to new tabs and splits.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Sessions") }
                Form {
                    Section("Keyboard") {
                        Toggle("Use Option as Alt", isOn: $draft.optionAsAlt)
                        Text("Sends Escape-prefixed keys to terminal apps. Leave off to type accented characters using Option.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Allow programs to set the status bar", isOn: $draft.programChrome)
                        Text("Programs can show a status line, progress, and a small mark on their tab while they work. Turning this off ignores their updates.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Keyboard") }
                Form {
                    Section("Updates") {
                        Toggle("Check for updates automatically", isOn: $automaticChecks)
                        Text("Available updates appear in the title bar. Downloads and restarts require your action.").font(.caption).foregroundStyle(.secondary)
                        Button("Check for Updates…") { updater.checkForUpdates(nil) }
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Updates") }
            }.padding([.top, .horizontal])
            HStack {
                Text(error).foregroundStyle(.red).font(.caption).accessibilityIdentifier("settings-error")
                Spacer()
                Button("Apply") {
                    do { try draft.save(); updater.automaticChecks = automaticChecks; error = "" }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(width: 560, height: 430)
    }
}

@MainActor final class PreferencesWindow: NSWindowController {
    init(updater: UpdateController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PreferencesView(updater: updater))
        window.center(); super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
}
