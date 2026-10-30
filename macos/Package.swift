// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let rustLibrary = ProcessInfo.processInfo.environment["AKITTY_RUST_LIB_DIR"] ?? root + "/target/debug"
let package = Package(
    name: "Akitty", platforms: [.macOS(.v14)],
    products: [.executable(name: "Akitty", targets: ["Akitty"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .systemLibrary(name: "AkittyCore", path: "Bridge"),
        .target(name: "AkittyKit", dependencies: ["AkittyCore", .product(name: "Sparkle", package: "Sparkle")], exclude: ["Resources"],
                linkerSettings: [.unsafeFlags(["-L", rustLibrary, "-lakitty_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                                 .linkedFramework("AppKit"), .linkedFramework("MetalKit"),
                                 .linkedFramework("CoreText"), .linkedFramework("JavaScriptCore")]),
        .executableTarget(name: "Akitty", dependencies: ["AkittyKit"]),
        .testTarget(name: "AkittyKitTests", dependencies: ["AkittyKit"])
    ], swiftLanguageModes: [.v5]
)
