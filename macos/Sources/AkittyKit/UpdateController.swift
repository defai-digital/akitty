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

/// Title-bar sprite for the chrome mark. Separate from the update reminder, which stays on the right.
@MainActor final class ChromeMarkAccessory: NSTitlebarAccessoryViewController {
    /// RGBA8 of the frame that was copied into the bitmap. Tests read this, not the displayed image.
    let chromePixels: Data
    /// Bytes read back from the bitmap immediately after the copy.
    let bitmapPixels: Data
    init(pixels: Data, width: Int, height: Int) {
        chromePixels = pixels
        let copied = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)
        if let copied, let destination = copied.bitmapData, pixels.count == width * height * 4 {
            pixels.withUnsafeBytes { raw in
                if let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    destination.update(from: source, count: pixels.count)
                }
            }
            bitmapPixels = Data(bytes: destination, count: pixels.count)
        } else {
            bitmapPixels = Data()
        }
        super.init(nibName: nil, bundle: nil)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        if let copied { image.addRepresentation(copied) }
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.identifier = NSUserInterfaceItemIdentifier("chrome-sprite")
        imageView.setAccessibilityIdentifier("chrome-sprite")
        view = imageView
        layoutAttribute = .left
    }
    required init?(coder: NSCoder) { nil }
}
