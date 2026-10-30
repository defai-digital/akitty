import AppKit
import SwiftUI

struct TerminalPreferences: Codable, Equatable {
    var fontName = "System Monospaced"
    var fontSize = 14.0
    var shell = ""
    var directory = ""
    var scrollback = 5000
    var optionAsAlt = false
    static let fonts = ["System Monospaced", "Menlo", "Monaco", "Courier"]
    func validated() throws -> Self {
        guard Self.fonts.contains(fontName), fontSize.isFinite, (9...36).contains(fontSize), (0...20000).contains(scrollback) else { throw AkittyError.core("Choose a supported font, size 9–36, and scrollback 0–20,000.") }
        guard shell.isEmpty || (shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell)) else { throw AkittyError.core("Shell must be an absolute path to an executable, without arguments.") }
        if !directory.isEmpty {
            var isDirectory: ObjCBool = false
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw AkittyError.core("Choose an existing absolute starting directory.") }
        }
        return self
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "terminalPreferences"), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if let valid = try? value.validated() { return valid }
        // A deleted shell or directory should reset only itself, not every saved setting.
        let fallback = Self()
        var isDirectory: ObjCBool = false
        if !value.shell.isEmpty, !(value.shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: value.shell)) { value.shell = fallback.shell }
        if !value.directory.isEmpty, !(value.directory.hasPrefix("/") && FileManager.default.fileExists(atPath: value.directory, isDirectory: &isDirectory) && isDirectory.boolValue) { value.directory = fallback.directory }
        return (try? value.validated()) ?? fallback
    }
    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(validated()), forKey: "terminalPreferences")
        NotificationCenter.default.post(name: .terminalPreferencesChanged, object: nil)
    }
}
extension Notification.Name { static let terminalPreferencesChanged = Notification.Name("AkittyTerminalPreferencesChanged") }

@MainActor private struct PreferencesView: View {
    @State private var draft = TerminalPreferences.load()
    @State private var automaticChecks: Bool
    @State private var error = ""
    let updater: UpdateController
    init(updater: UpdateController) {
        self.updater = updater
        _automaticChecks = State(initialValue: updater.automaticChecks)
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    Picker("Font", selection: $draft.fontName) { ForEach(TerminalPreferences.fonts, id: \.self) { Text($0) } }
                    Stepper("Font size: \(Int(draft.fontSize)) pt", value: $draft.fontSize, in: 9...36)
                    Text("Applies to open terminals. ⌘+ and ⌘− adjust an individual pane.").font(.caption).foregroundStyle(.secondary)
                }
                Section("New Terminals") {
                    TextField("Shell", text: $draft.shell, prompt: Text("Default login shell"))
                    HStack {
                        TextField("Starting directory", text: $draft.directory, prompt: Text("Home directory"))
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK { draft.directory = panel.url?.path ?? "" }
                        }
                    }
                    Stepper("Scrollback: \(draft.scrollback) lines", value: $draft.scrollback, in: 0...20000, step: 1000)
                    Text("Shell, directory and scrollback changes apply to new tabs and splits.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    Toggle("Use Option as Alt", isOn: $draft.optionAsAlt)
                    Text("Sends Escape-prefixed keys to terminal apps. Leave off to type accented characters using Option.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $automaticChecks)
                    Text("Available updates appear in the title bar. Downloads and restarts require your action.").font(.caption).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.checkForUpdates(nil) }
                }
            }.formStyle(.grouped)
            HStack {
                Text(error).foregroundStyle(.red).font(.caption).accessibilityIdentifier("settings-error")
                Spacer()
                Button("Apply") {
                    do { try draft.save(); updater.automaticChecks = automaticChecks; error = "" }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(width: 560, height: 610)
    }
}

@MainActor final class PreferencesWindow: NSWindowController {
    init(updater: UpdateController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PreferencesView(updater: updater))
        window.center(); super.init(window: window)
    }
    required init?(coder: NSCoder) { nil }
}
