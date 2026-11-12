// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let rustLibrary = ProcessInfo.processInfo.environment["AKITTY_RUST_LIB_DIR"] ?? root + "/target/debug"
let package = Package(
    name: "Akitty", platforms: [.macOS("27.2")],
    products: [.executable(name: "Akitty", targets: ["Akitty"]), .executable(name: "akitty-agent", targets: ["AkittyAgent"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
                   .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
                   .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")],
    targets: [
        .systemLibrary(name: "AkittyCore", path: "Bridge"),
        .target(name: "AgentIPC"),
        .target(name: "AkittyMCP", dependencies: ["AgentIPC", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "AkittyAgent", dependencies: ["AgentIPC", "AkittyMCP"]),
        .target(name: "AkittyKit", dependencies: ["AkittyCore", "AgentIPC", .product(name: "Sparkle", package: "Sparkle")], exclude: ["Resources"],
                linkerSettings: [.unsafeFlags(["-L", rustLibrary, "-lakitty_core", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                                 .linkedFramework("AppKit"), .linkedFramework("MetalKit"),
                                 .linkedFramework("Carbon"), .linkedFramework("CoreText"), .linkedFramework("JavaScriptCore"), .linkedFramework("AppIntents")]),
        .executableTarget(name: "Akitty", dependencies: ["AkittyKit"]),
        .testTarget(name: "AkittyMCPTests", dependencies: ["AkittyMCP", "AgentIPC", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "AkittyKitTests", dependencies: ["AkittyKit", "AgentIPC", .product(name: "MCP", package: "swift-sdk")])
    ], swiftLanguageModes: [.v5]
)
