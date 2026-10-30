import AppKit
import Sparkle
import os

/// Native Sparkle updates with a quiet, persistent titlebar reminder.
/// Ghostty informed the interaction; installation and signature validation remain Sparkle's responsibility.
@MainActor final class UpdateController: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!
    private(set) var availableVersion: String?
    var onReminderChanged: ((String?) -> Void)?
    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    }
    func start() { controller.startUpdater() }
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // With no terminal window, retain Sparkle's visible fallback.
        !NSApp.windows.contains { $0.windowController is TerminalWindow && $0.isVisible }
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        setReminder(handleShowingUpdate ? nil : update.displayVersionString)
    }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { setReminder(nil) }
    func standardUserDriverWillFinishUpdateSession() { setReminder(nil) }
    func setReminder(_ version: String?) {
        // Treat feed display text as untrusted even though the feed is signed.
        availableVersion = version.map { String($0.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(32)) }
        onReminderChanged?(availableVersion)
    }
}

@MainActor final class UpdateReminder: NSTitlebarAccessoryViewController {
    init(version: String, updater: UpdateController) {
        super.init(nibName: nil, bundle: nil)
        let button = NSButton(title: "Update Available: \(version)", target: updater, action: #selector(UpdateController.checkForUpdates(_:)))
        button.bezelStyle = .rounded; button.bezelColor = .controlAccentColor; button.contentTintColor = .white
        button.image = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil); button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.toolTip = "Review the update and choose when to install"
        button.setAccessibilityIdentifier("update-reminder")
        button.sizeToFit(); button.frame.size.height = 24
        view = button; layoutAttribute = .right
    }
    required init?(coder: NSCoder) { nil }
}
