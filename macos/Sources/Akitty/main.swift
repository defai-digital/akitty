import AppKit
import AkittyKit
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AkittyApplication()
    application.delegate = delegate
    AkittyShortcuts.updateAppShortcutParameters()
    withExtendedLifetime(delegate) { application.run() }
}
