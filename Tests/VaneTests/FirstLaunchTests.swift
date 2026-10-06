import XCTest
@testable import vane

@MainActor final class FirstLaunchTests: XCTestCase {
    private func fixture() throws -> (UserDefaults, URL) {
        let name = "vane-welcome-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults.dropScratchSuite(name)
            try? FileManager.default.removeItem(at: directory)
        }
        return (defaults, directory)
    }

    func testActualLogoAndScreenshotsAreBundledAndReadable() {
        for image in [WelcomeArtwork.logo, WelcomeArtwork.search, WelcomeArtwork.spaces] {
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertTrue(image.isValid)
        }
    }

    func testFreshInstallationResumesUntilFinishedThenNeverRepeats() throws {
        let (defaults, directory) = try fixture()
        let first = FirstLaunchState(defaults: defaults)
        XCTAssertTrue(first.prepare(directory: directory))
        // Normal browser startup writes these while the welcome is still on screen.
        try Data("[]".utf8).write(to: directory.appendingPathComponent("profiles.json"))
        XCTAssertTrue(FirstLaunchState(defaults: defaults).prepare(directory: directory))
        first.complete()
        XCTAssertFalse(FirstLaunchState(defaults: defaults).prepare(directory: directory))
    }

    func testExistingInstallationSkipsWelcomeWithoutChangingBrowsingData() throws {
        for filename in ["profiles.json", "vane.db", "session.json", "spaces.json"] {
            let (defaults, directory) = try fixture()
            let data = Data("existing browsing data".utf8)
            let file = directory.appendingPathComponent(filename)
            try data.write(to: file)
            XCTAssertFalse(FirstLaunchState(defaults: defaults).prepare(directory: directory), filename)
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testLegacyInstallationSkipsWelcomeAndIsolatedInstallationIgnoresIt() throws {
        let (defaults, directory) = try fixture()
        let legacy = directory.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data().write(to: legacy.appendingPathComponent("vane.db"))
        XCTAssertFalse(FirstLaunchState(defaults: defaults).prepare(directory: directory, legacy: legacy))
        let (isolatedDefaults, isolated) = try fixture()
        XCTAssertTrue(FirstLaunchState(defaults: isolatedDefaults).prepare(directory: isolated))
    }

    func testMissingDirectoryIsFreshButUnreadableStorageIsNot() throws {
        let (defaults, directory) = try fixture()
        XCTAssertTrue(FirstLaunchState(defaults: defaults).prepare(directory: directory.appendingPathComponent("new")))
        let (otherDefaults, other) = try fixture()
        let file = other.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        XCTAssertFalse(FirstLaunchState(defaults: otherDefaults).prepare(directory: file))
    }
}
