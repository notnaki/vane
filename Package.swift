// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vane",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "vane",
            path: "Sources/Vane",
            resources: [.copy("EaselFonts"), .copy("WelcomeAssets")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("z"),
                // Downlevel Safari updates install an Apple-managed WebKit stack here.
                // Match Safari's embedded loader paths; absent staging uses the OS stack.
                .unsafeFlags(["-Xlinker", "-dyld_env", "-Xlinker",
                              "DYLD_FRAMEWORK_PATH=/System/Cryptexes/App/System/Library/StagedFrameworks/Safari",
                              "-Xlinker", "-dyld_env", "-Xlinker",
                              "DYLD_LIBRARY_PATH=/System/Cryptexes/App/System/Library/StagedFrameworks/Safari"]),
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
