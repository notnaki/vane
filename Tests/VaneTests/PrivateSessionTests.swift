import XCTest
@testable import vane

@MainActor final class PrivateSessionTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare() }

    func testPrivateOverridesStayInMemoryAndExpireAtSessionEnd() {
        let id = Profile.incognito.id
        let url = URL(string: "https://private-session.example/secret")!
        defer { PrivateBrowsing.endSession() }
        TidyTitles.rename(url, in: id, to: "Private name")
        DeveloperMode.set(true, for: url, profile: id)
        XCTAssertEqual(TidyTitles.override(for: url, in: id), "Private name")
        XCTAssertTrue(DeveloperMode.wants(url, profile: id))
        XCTAssertNil(UserDefaults.vane.object(forKey: ProfileManager.defaultsKey("tidyTitleOverrides", id)))
        XCTAssertNil(UserDefaults.vane.object(forKey: ProfileManager.defaultsKey("developerSites", id)))
        PrivateBrowsing.endSession()
        XCTAssertNil(TidyTitles.override(for: url, in: id))
        XCTAssertFalse(DeveloperMode.wants(url, profile: id))
    }

    func testSessionEndRemovesLegacyPrivateOverridesAndPreservesRegularOverrides() {
        let id = Profile.incognito.id, regular = UUID()
        let url = URL(string: "https://legacy-private.example/secret")!
        let namesKey = ProfileManager.defaultsKey("tidyTitleOverrides", id)
        let developerKey = ProfileManager.defaultsKey("developerSites", id)
        UserDefaults.vane.set([url.absoluteString: "Legacy name"], forKey: namesKey)
        UserDefaults.vane.set([url.host!: true], forKey: developerKey)
        defer {
            PrivateBrowsing.endSession()
            TidyTitles.forget(regular)
            UserDefaults.vane.removeObject(forKey: ProfileManager.defaultsKey("developerSites", regular))
        }
        XCTAssertNil(TidyTitles.override(for: url, in: id))
        XCTAssertFalse(DeveloperMode.wants(url, profile: id))
        TidyTitles.rename(url, in: regular, to: "Regular name")
        DeveloperMode.set(true, for: url, profile: regular)
        PrivateBrowsing.endSession()
        XCTAssertNil(UserDefaults.vane.object(forKey: namesKey))
        XCTAssertNil(UserDefaults.vane.object(forKey: developerKey))
        XCTAssertEqual(TidyTitles.override(for: url, in: regular), "Regular name")
        XCTAssertTrue(DeveloperMode.wants(url, profile: regular))
        XCTAssertEqual(UserDefaults.vane.dictionary(forKey: ProfileManager.defaultsKey("tidyTitleOverrides", regular)) as? [String: String], [url.absoluteString: "Regular name"])
    }

    func testSessionEndClearsExistingLibraryAndManagerButPreservesCompletedFiles() throws {
        defer { PrivateBrowsing.endSession() }
        let manager = Downloads.manager(for: Profile.incognito.id)
        let library = DownloadLibrary.library(for: Profile.incognito.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let completed = manager.add(.init(name: "private.pdf", destination: file, state: "done"))
        let paused = manager.add(.init(name: "paused.zip", state: "paused"))
        XCTAssertTrue(library.items.contains { $0 === completed })
        PrivateBrowsing.endSession()
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(library.items.isEmpty)
        XCTAssertFalse(manager.resume(paused))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let next = Downloads.manager(for: Profile.incognito.id)
        XCTAssertFalse(next === manager)
        XCTAssertTrue(next.items.isEmpty)
        let fresh = next.add(.init(name: "next-private.pdf", state: "done"))
        XCTAssertTrue(library.items.contains { $0 === fresh }, "An existing Library follows the fresh private manager")
    }
}
