import AppKit
import Darwin
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
    var confirmPaste = true
    /// Ask before a program replaces the clipboard with OSC 52; Always Allow in that prompt turns it off.
    var confirmClipboardWrite = true
    /// Mute terminal bells and explicit error sounds while retaining visual notifications.
    var silentMode = false
    /// Programs may update chrome only when this preference is enabled.
    var programChrome = true
    /// On by default; terminals whose shell is not bash or zsh start as ordinary login shells.
    var shellIntegration = true
    /// zsh integration also saves commands per folder for Tab and Up/Down; off starts it with AKITTY_FOLDER_HISTORY=0.
    var folderHistory = true
    var quickTerminal = false
    var quickShortcut = 0
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
    /// The file the zsh integration keeps; it defaults to the same place under the home directory.
    static var folderHistoryFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Akitty/folder-history")
    }
    static func clearFolderHistory(file supplied: URL? = nil) throws {
        let file: URL
        if let supplied { file = supplied }
        else if let configured = ProcessInfo.processInfo.environment["AKITTY_FOLDER_HISTORY_FILE"], !configured.isEmpty {
            guard configured.hasPrefix("/"), configured.utf8.count <= 4096 else { throw AkittyError.core("Command history must use a bounded absolute path.") }
            file = URL(fileURLWithPath: configured)
        } else { file = folderHistoryFile }
        let directory = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT { return }
        guard directory >= 0 else { throw AkittyError.core("Cannot safely open the command history directory.") }
        defer { Darwin.close(directory) }
        var parent = stat(), existing = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o022 == 0 else {
            throw AkittyError.core("Command history directory must be owned by you and not writable by others.")
        }
        let name = file.lastPathComponent
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) < 0 {
            if errno == ENOENT { return }
            throw AkittyError.core("Cannot inspect command history.")
        }
        func safe(_ info: stat) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
                && info.st_mode & 0o777 == 0o600 && info.st_nlink == 1
        }
        guard safe(existing) else { throw AkittyError.core("Command history must be a private regular file without links.") }
        let lock = openat(directory, name + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw AkittyError.core("Cannot safely open the command history lock.") }
        defer { Darwin.close(lock) }
        var info = stat(), range = Darwin.flock()
        guard fstat(lock, &info) == 0, safe(info) else { throw AkittyError.core("Command history lock must be a private regular file without links.") }
        // zsystem flock uses POSIX fcntl locks, not BSD flock. Never block the Settings UI.
        range.l_type = Int16(F_WRLCK); range.l_whence = Int16(SEEK_SET)
        guard fcntl(lock, F_SETLK, &range) == 0 else { throw AkittyError.core("Command history is busy. Try clearing it again.") }
        let descriptor = openat(directory, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AkittyError.core("Cannot safely open command history.") }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &info) == 0, safe(info),
              fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0,
              existing.st_dev == info.st_dev, existing.st_ino == info.st_ino else { throw AkittyError.core("Command history changed while clearing it.") }
        // Open after locking so a shell's compaction cannot leave us truncating an old inode.
        guard ftruncate(descriptor, 0) == 0 else { throw AkittyError.core("Cannot clear command history.") }
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
        guard (0...2).contains(quickShortcut) else { throw AkittyError.core("Choose a valid quick terminal shortcut.") }
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
        if !(0...2).contains(value.quickShortcut) { value.quickShortcut = fallback.quickShortcut }
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
        case fontName, cjkFont, fontSize, shell, directory, scrollback, optionAsAlt, confirmPaste, confirmClipboardWrite, silentMode, programChrome, shellIntegration, folderHistory, quickTerminal, quickShortcut
        /// Present once shell integration defaulted on; earlier saves stored the old default (off), not a user choice.
        case shellIntegrationDefaultOn
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
        confirmPaste = try container.decodeIfPresent(Bool.self, forKey: .confirmPaste) ?? true
        confirmClipboardWrite = try container.decodeIfPresent(Bool.self, forKey: .confirmClipboardWrite) ?? true
        silentMode = try container.decodeIfPresent(Bool.self, forKey: .silentMode) ?? false
        // Missing on preferences saved before this switch existed. Default on so current sessions keep program chrome.
        quickTerminal = try container.decodeIfPresent(Bool.self, forKey: .quickTerminal) ?? false
        quickShortcut = try container.decodeIfPresent(Int.self, forKey: .quickShortcut) ?? 0
        if try container.decodeIfPresent(Bool.self, forKey: .shellIntegrationDefaultOn) == true {
            shellIntegration = try container.decodeIfPresent(Bool.self, forKey: .shellIntegration) ?? shellIntegration
        }
        programChrome = try container.decodeIfPresent(Bool.self, forKey: .programChrome) ?? true
        folderHistory = try container.decodeIfPresent(Bool.self, forKey: .folderHistory) ?? true
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
        try container.encode(confirmPaste, forKey: .confirmPaste)
        try container.encode(confirmClipboardWrite, forKey: .confirmClipboardWrite)
        try container.encode(silentMode, forKey: .silentMode)
        try container.encode(programChrome, forKey: .programChrome)
        try container.encode(shellIntegration, forKey: .shellIntegration)
        try container.encode(folderHistory, forKey: .folderHistory)
        try container.encode(true, forKey: .shellIntegrationDefaultOn)
        try container.encode(quickTerminal, forKey: .quickTerminal)
        try container.encode(quickShortcut, forKey: .quickShortcut)
    }
}

struct PreferencesDraft {
    private(set) var saved: TerminalPreferences
    var draft: TerminalPreferences
    private(set) var savedAutomaticChecks: Bool
    var automaticChecks: Bool
    init(preferences: TerminalPreferences, automaticChecks: Bool) {
        saved = preferences; draft = preferences
        savedAutomaticChecks = automaticChecks; self.automaticChecks = automaticChecks
    }
    var hasChanges: Bool { draft != saved || automaticChecks != savedAutomaticChecks }
    mutating func markSaved() { saved = draft; savedAutomaticChecks = automaticChecks }
    mutating func mergePasteConfirmation(_ enabled: Bool) {
        // A choice made in a terminal updates an open Settings window without discarding other draft edits.
        if draft.confirmPaste == saved.confirmPaste { draft.confirmPaste = enabled }
        saved.confirmPaste = enabled
    }
    mutating func mergeClipboardWriteConfirmation(_ enabled: Bool) {
        if draft.confirmClipboardWrite == saved.confirmClipboardWrite { draft.confirmClipboardWrite = enabled }
        saved.confirmClipboardWrite = enabled
    }
}

@MainActor private struct PreferencesView: View {
    @State private var state: PreferencesDraft
    @State private var error = ""
    let updater: UpdateController
    let defaults: UserDefaults
    init(updater: UpdateController, defaults: UserDefaults = .standard) {
        self.updater = updater; self.defaults = defaults
        _state = State(initialValue: PreferencesDraft(preferences: .load(from: defaults), automaticChecks: updater.automaticChecks))
    }
    private var draft: TerminalPreferences {
        get { state.draft }
        nonmutating set { state.draft = newValue }
    }
    private var automaticChecks: Bool {
        get { state.automaticChecks }
        nonmutating set { state.automaticChecks = newValue }
    }
    private var hasChanges: Bool { state.hasChanges }
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
                        Picker("Font", selection: $state.draft.fontName) { ForEach(fontChoices, id: \.self) { Text($0) } }
                        Picker("CJK font", selection: $state.draft.cjkFont) {
                            Text("Automatic").tag("")
                            ForEach(cjkChoices, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Chinese, Japanese and Korean text. Automatic follows your system language.").font(.caption).foregroundStyle(.secondary)
                        Stepper("Font size: \(Int(draft.fontSize)) pt", value: $state.draft.fontSize, in: 9...36)
                        Text("Applies to open terminals. ⌘+ and ⌘− adjust an individual pane.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Appearance") }
                Form {
                    Section("Alerts") {
                        Toggle("Silent mode", isOn: $state.draft.silentMode)
                            .accessibilityIdentifier("silent-mode")
                        Text("Mute terminal bells and error sounds. Visual alerts and messages remain. Applies to open terminals.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Clipboard") {
                        Toggle("Confirm multiline and control-character pastes", isOn: $state.draft.confirmPaste)
                            .accessibilityIdentifier("confirm-paste")
                        Text("Applies to open terminals. Turn this on to restore confirmation after choosing Don't ask again.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Ask before programs copy to the clipboard", isOn: $state.draft.confirmClipboardWrite)
                            .accessibilityIdentifier("confirm-clipboard-write")
                        Text("Programs copy with OSC 52. When off, copies happen silently and the status bar notes them. Programs can never read the clipboard.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("New Terminals") {
                        Toggle("Shell integration (bash and zsh)", isOn: $state.draft.shellIntegration)
                        Text("Records command boundaries, exit status and working directories in new terminals. Does not modify startup files. Other shells start normally.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Command history on Tab and Up/Down (zsh)", isOn: $state.draft.folderHistory)
                            .disabled(!draft.shellIntegration)
                        HStack {
                            Text("Type the start of a command, then Tab lists the five most recent matches, this folder's first. Commands starting with a space are not saved.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear History") {
                                do { try TerminalPreferences.clearFolderHistory(); error = "" }
                                catch { self.error = error.localizedDescription }
                            }
                                .help("Delete the saved command history")
                                .accessibilityIdentifier("clear-folder-history")
                        }
                        TextField("Shell", text: $state.draft.shell, prompt: Text("Default login shell"))
                        HStack {
                            TextField("Starting directory", text: $state.draft.directory, prompt: Text("Home directory"))
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
                        Stepper("Scrollback: \(draft.scrollback) lines", value: $state.draft.scrollback, in: 0...20000, step: 1000)
                        Text("Shell, directory and scrollback changes apply to new tabs and splits.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Sessions") }
                Form {
                    Section("Quick Terminal") {
                        Toggle("Enable global quick terminal", isOn: $state.draft.quickTerminal)
                        Picker("Shortcut", selection: $state.draft.quickShortcut) {
                            ForEach(0..<GlobalShortcut.names.count, id: \.self) { Text(GlobalShortcut.names[$0]).tag($0) }
                        }.disabled(!draft.quickTerminal)
                        Text("Toggle a persistent terminal on the pointer’s display. Hiding keeps its processes running.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Keyboard") {
                        Toggle("Use Option as Alt", isOn: $state.draft.optionAsAlt)
                        Text("Sends Escape-prefixed keys to terminal apps. Leave off to type accented characters using Option.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Allow programs to set the status bar", isOn: $state.draft.programChrome)
                        Text("Programs can show a status line, progress, and a small mark on their tab while they work. Turning this off ignores their updates.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                    .tabItem { Text("Keyboard") }
                Form {
                    Section("Updates") {
                        Toggle("Check for updates automatically", isOn: $state.automaticChecks)
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
                    do {
                        _ = try draft.validated()
                        try (NSApp.delegate as? AkittyApplication)?.configureQuickTerminal(draft)
                        try draft.save(to: defaults); updater.automaticChecks = automaticChecks
                        state.markSaved(); error = ""
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
                    .accessibilityIdentifier("apply-preferences")
            }.padding()
        }.frame(width: 560, height: 430)
            .onReceive(NotificationCenter.default.publisher(for: .terminalPreferencesChanged)) { _ in
                let current = TerminalPreferences.load(from: defaults)
                state.mergePasteConfirmation(current.confirmPaste)
                state.mergeClipboardWriteConfirmation(current.confirmClipboardWrite)
            }
    }
}

@MainActor final class PreferencesWindow: NSWindowController {
    init(updater: UpdateController, defaults: UserDefaults = .standard) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PreferencesView(updater: updater, defaults: defaults))
        window.center(); super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
}
