// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vane",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "vane",
            path: "Sources/Vane",
            resources: [.copy("EaselFonts"), .copy("WelcomeAssets"), .copy("SpaceEmoji")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
            ]
        ),
        // Only the XCTest bundle links this early, process-local AppKit setup.
        .target(
            name: "NativeTestHostBootstrap",
            path: "Tests/NativeTestHostBootstrap",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "VaneTests", dependencies: ["vane", "NativeTestHostBootstrap"])
    ]
)
