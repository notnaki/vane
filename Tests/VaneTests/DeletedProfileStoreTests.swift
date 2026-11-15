import XCTest
@testable import vane

@MainActor final class DeletedProfileStoreTests: XCTestCase {
    func testForgottenProfileCannotReopenItsBrowsingDatabase() {
        TestEnvironment.prepare()
        let profile = UUID()
        let old = Store.store(for: profile)
        Store.retire(profile)
        XCTAssertTrue(old.isRetired)
        let late = Store.store(for: profile)
        XCTAssertTrue(late.isRetired)
        XCTAssertFalse(late.recordNavigation(URL(string: "https://deleted.example.test/")!, title: "Too late"))
        XCTAssertTrue(late.history().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileManager.dbURL(for: profile, in: Store.directory).path))
        Store.forget(profile)
    }

    /// Cleanup that only forgets a store must not retire its ID for the whole process.
    func testForgetAloneLeavesTheProfileUsable() {
        TestEnvironment.prepare()
        let profile = UUID()
        _ = Store.store(for: profile)
        Store.forget(profile)
        XCTAssertFalse(Store.store(for: profile).isRetired)
        Store.forget(profile)
    }
}
