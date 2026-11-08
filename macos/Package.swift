// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let rustLibrary = ProcessInfo.processInfo.environment["AKITTY_RUST_LIB_DIR"] ?? root + "/target/debug"
// The custom Siri tools API is a macOS 27.3 developer preview. Production
// builds retain macOS 14 App Shortcuts; preview builds require the newer SDK.
let siriPreview = ProcessInfo.processInfo.environment["AKITTY_SIRI_AI_PREVIEW"] == "1"
let package = Package(
    name: "Akitty", platforms: [.macOS(siriPreview ? "27.3" : "14.0")],
    products: [.executable(name: "Akitty", targets: ["Akitty"]), .executable(name: "akitty-agent", targets: ["AkittyAgent"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .systemLibrary(name: "AkittyCore", path: "Bridge"),
        .target(name: "AgentIPC"),
        .executableTarget(name: "AkittyAgent", dependencies: ["AgentIPC"]),
        .target(name: "AkittyKit", dependencies: ["AkittyCore", "AgentIPC", .product(name: "Sparkle", package: "Sparkle")], exclude: ["Resources"],
                swiftSettings: siriPreview ? [.define("AKITTY_SIRI_AI_PREVIEW")] : [],
                linkerSettings: [.unsafeFlags(["-L", rustLibrary, "-lakitty_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                                 .linkedFramework("AppKit"), .linkedFramework("MetalKit"),
                                 .linkedFramework("Carbon"), .linkedFramework("CoreText"), .linkedFramework("JavaScriptCore"), .linkedFramework("AppIntents")]),
        .executableTarget(name: "Akitty", dependencies: ["AkittyKit"]),
        .testTarget(name: "AkittyKitTests", dependencies: ["AkittyKit", "AgentIPC"])
    ], swiftLanguageModes: [.v5]
)
