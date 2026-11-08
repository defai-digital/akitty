import AppIntents
import AkittyKit

// Keep the statically linked library's intent metadata discoverable from the app.
struct AkittyAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [AkittyIntents.self] }
}
