import AppKit
import XCTest
@testable import vane

@MainActor final class NativeFixtureProfileCleanupTests: XCTestCase {
    @MainActor private final class CacheReferences {
        weak var store: Store?
        weak var icons: Favicons?

        init(profile: UUID) {
            store = Store.store(for: profile)
            icons = Favicons.cache(for: profile)
        }
    }

    func testDisposalReleasesOwnedBrowsingCachesAndPreservesUnrelatedProfile() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let owned = UUID(), unrelated = UUID()
        defer {
            for profile in [owned, unrelated] {
                Store.forget(profile)
                Favicons.forget(profile)
            }
        }
        let released = CacheReferences(profile: owned)
        XCTAssertNotNil(released.store)
        XCTAssertNotNil(released.icons)
        let otherStore = Store.store(for: unrelated)
        let otherIcons = Favicons.cache(for: unrelated)
        let bookmark = URL(string: "https://unrelated-fixture.invalid/kept")!
        XCTAssertTrue(otherStore.toggleBookmark(bookmark, title: "Keep this profile"))

        let ownedDB = ProfileManager.dbURL(for: owned, in: Store.directory)
        let otherDB = ProfileManager.dbURL(for: unrelated, in: Store.directory)
        let ownedIcons = ProfileManager.faviconDir(for: owned, in: Store.directory)
        let otherIconDirectory = ProfileManager.faviconDir(for: unrelated, in: Store.directory)
        for directory in [ownedIcons, otherIconDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("fixture-marker"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDB.path))

        try await NativeFixtureProfileCleanup.release([owned])

        XCTAssertNil(released.store, "Disposed profiles must release their cached SQLite connection")
        XCTAssertNil(released.icons, "Disposed profiles must release their favicon cache")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedIcons.path))
        XCTAssertTrue(Store.store(for: unrelated) === otherStore)
        XCTAssertTrue(Favicons.cache(for: unrelated) === otherIcons)
        XCTAssertTrue(otherStore.isBookmarked(bookmark))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDB.path))
        XCTAssertEqual(try Data(contentsOf: otherIconDirectory.appendingPathComponent("fixture-marker")), Data([1, 2, 3]))
    }
}
