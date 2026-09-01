// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vane",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "vane",
            path: "Sources/Vane",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
