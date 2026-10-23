import Foundation
import XCTest
@testable import vane

final class AppResourcesTests: XCTestCase {
    func testPackagedFlatResourceBundleWorksWithoutSwiftPMInfoPlistOrBuildDirectory() throws {
        try withApp { app, resources, _ in
            XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent("Info.plist").path))
            var fallbackCalls = 0
            let result = AppResources.resolve(appBundle: app) {
                fallbackCalls += 1
                return .main
            }
            XCTAssertEqual(fallbackCalls, 0, "The generated SwiftPM accessor may trap in a packaged release")
            let artwork = try XCTUnwrap(result.url(forResource: "welcome", withExtension: "txt", subdirectory: "WelcomeAssets"))
            let font = try XCTUnwrap(result.url(forResource: "fixture", withExtension: "ttf", subdirectory: "EaselFonts"))
            XCTAssertEqual(try Data(contentsOf: artwork), Data("welcome-fixture".utf8))
            XCTAssertEqual(try Data(contentsOf: font), Data("font-fixture".utf8))
            XCTAssertEqual(result.bundleURL.standardizedFileURL, resources.standardizedFileURL)
        }
    }

    func testRelocatedAppUsesInstalledResourcesAfterBuildDirectoryIsRemoved() throws {
        try withApp { app, _, root in
            let build = root.appendingPathComponent("deleted-build-directory")
            let installation = root.appendingPathComponent("Applications")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
            let executable = build.appendingPathComponent("vane")
            try Data("executable-fixture".utf8).write(to: executable)
            try FileManager.default.moveItem(at: executable,
                to: app.bundleURL.appendingPathComponent("Contents/MacOS/vane"))
            let installed = installation.appendingPathComponent("Vane.app")
            try FileManager.default.moveItem(at: app.bundleURL, to: installed)
            try FileManager.default.removeItem(at: build)
            let relocated = try XCTUnwrap(Bundle(url: installed))
            let result = AppResources.resolve(appBundle: relocated) {
                XCTFail("An installed executable must resolve packaged resources before the old build path")
                return .main
            }
            let font = try XCTUnwrap(result.url(forResource: "fixture", withExtension: "ttf", subdirectory: "EaselFonts"))
            XCTAssertEqual(try Data(contentsOf: font), Data("font-fixture".utf8))
            XCTAssertEqual(result.bundleURL.standardizedFileURL,
                installed.appendingPathComponent("Contents/Resources/Vane_vane.bundle").standardizedFileURL)
            let installedExecutable = try XCTUnwrap(relocated.executableURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: installedExecutable.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: build.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.bundleURL.path))
        }
    }

    func testCommandLineLayoutCallsFallbackOnceAndReturnsItsBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try XCTUnwrap(Bundle(url: root))
        var fallbackCalls = 0
        let result = AppResources.resolve(appBundle: app) { fallbackCalls += 1; return .main }
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertEqual(result.bundleURL, Bundle.main.bundleURL)
    }

    private func withApp(_ body: (Bundle, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-resource-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("Vane.app")
        let resources = appURL.appendingPathComponent("Contents/Resources/Vane_vane.bundle")
        for path in [resources.appendingPathComponent("WelcomeAssets"), resources.appendingPathComponent("EaselFonts"),
                     appURL.appendingPathComponent("Contents/MacOS")] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        // SwiftPM's copied resource bundle is flat and has no Info.plist.
        try Data("welcome-fixture".utf8).write(to: resources.appendingPathComponent("WelcomeAssets/welcome.txt"))
        try Data("font-fixture".utf8).write(to: resources.appendingPathComponent("EaselFonts/fixture.ttf"))
        let info: [String: Any] = ["CFBundleIdentifier": "test.vane.resources.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "vane"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try body(XCTUnwrap(Bundle(url: appURL)), resources, root)
    }
}
