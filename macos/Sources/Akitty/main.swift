import AppKit
import AkittyKit
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AkittyApplication()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
