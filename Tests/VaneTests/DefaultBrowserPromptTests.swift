import XCTest
@testable import vane

@MainActor final class DefaultBrowserPromptTests: XCTestCase {
    func testOnlyExplicitlyEnabledProductionBundlesCanPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-default-prompt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String?, Bool?, Bool)] = [
            (nil, true, false),
            ("io.github.notnaki.vane", nil, false),
            ("io.github.notnaki.vane", false, false),
            ("io.github.notnaki.vane.browsercheck.fixture", true, false),
            ("io.github.notnaki.vane", true, true),
        ]
        for (index, testCase) in cases.enumerated() {
            let (identifier, enabled, expected) = testCase
            let app = directory.appendingPathComponent("Fixture\(index).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundlePackageType": "APPL"]
            info["CFBundleIdentifier"] = identifier
            info["VaneDefaultBrowserPromptEnabled"] = enabled
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = try XCTUnwrap(Bundle(url: app))
            XCTAssertEqual(URLHandling.defaultBrowserPromptAllowed(in: bundle), expected,
                           "bundle id: \(identifier ?? "none"), opt-in: \(String(describing: enabled))")
        }
    }
}
