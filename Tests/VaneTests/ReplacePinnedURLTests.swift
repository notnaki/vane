import Foundation
import XCTest
@testable import vane

/// "Replace Pinned URL with Current": a pinned row that has browsed away from its page takes the
/// page it is on as its new home, so it returns there instead of the old page.
@MainActor final class ReplacePinnedURLTests: XCTestCase {
    func testReplacePinnedURLMakesTheCurrentPageTheHome() throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Replace pin").id
        let space = Space(name: "Replace pin", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        store.sharingReady = false
        let home = try XCTUnwrap(URL(string: "https://example.test/home"))
        let away = try XCTUnwrap(URL(string: "https://example.test/away"))
        let tab = Tab(profileID: profile)
        tab.park(url: home, Parked(title: "Home"))
        tab.kind = .pinned
        store.tabs = [tab]
        defer {
            SharedTabs.release([tab])
            TabStore.all.removeAll { $0 === store }
            _ = ProfileManager.shared.delete(profile)
        }

        tab.park(url: away, Parked(title: "Away"))
        XCTAssertFalse(tab.atHome, "The row should be away from its pinned page")

        store.replacePinnedURL(tab.id)

        XCTAssertEqual(tab.homeURL, away, "The current page should become the pinned page")
        XCTAssertTrue(tab.atHome, "The row should now stand on its new home")
    }
}
