// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let rustLibrary = ProcessInfo.processInfo.environment["AKITTY_RUST_LIB_DIR"] ?? root + "/target/debug"
let package = Package(
    name: "Akitty", platforms: [.macOS(.v14)],
    products: [.executable(name: "Akitty", targets: ["Akitty"])],
    targets: [
        .systemLibrary(name: "AkittyCore", path: "Bridge"),
        .target(name: "AkittyKit", dependencies: ["AkittyCore"], exclude: ["Resources"],
                linkerSettings: [.unsafeFlags(["-L", rustLibrary, "-lakitty_core"]),
                                 .linkedFramework("AppKit"), .linkedFramework("MetalKit"),
                                 .linkedFramework("CoreText"), .linkedFramework("JavaScriptCore")]),
        .executableTarget(name: "Akitty", dependencies: ["AkittyKit"]),
        .testTarget(name: "AkittyKitTests", dependencies: ["AkittyKit"])
    ], swiftLanguageModes: [.v5]
)
