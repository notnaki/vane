import XCTest
@testable import vane

@MainActor final class DeletedProfileStoreTests: XCTestCase {
    func testForgottenProfileCannotReopenItsBrowsingDatabase() {
        TestEnvironment.prepare()
        let profile = UUID()
        let old = Store.store(for: profile)
        Store.forget(profile)
        XCTAssertTrue(old.isRetired)
        let late = Store.store(for: profile)
        XCTAssertTrue(late.isRetired)
        XCTAssertFalse(late.recordNavigation(URL(string: "https://deleted.example.test/")!, title: "Too late"))
        XCTAssertTrue(late.history().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfileManager.dbURL(for: profile, in: Store.directory).path))
        Store.forget(profile)
    }

}
