import XCTest
@testable import vane

@MainActor final class SpaceCardTests: XCTestCase {
    func testCollapseIsPerSpaceAndDoesNotChangeTabs() {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        store.newTab(URL(string: "about:blank")!)
        let tabIDs = store.tabs.map(\.id)
        let activeID = store.current
        XCTAssertFalse(store.spaceCardCollapsed)
        store.toggleSpaceCard()
        XCTAssertTrue(store.spaceCardCollapsed)
        XCTAssertEqual(store.tabs.map(\.id), tabIDs)
        XCTAssertEqual(store.current, activeID)
        store.switchTo(space: second)
        XCTAssertFalse(store.spaceCardCollapsed)
        store.switchTo(space: first)
        XCTAssertTrue(store.spaceCardCollapsed)
        store.toggleSpaceCard()
        XCTAssertFalse(store.spaceCardCollapsed)
    }

    func testCollapsedSwipePreviewKeepsTodayAndHidesPinnedRows() {
        TestEnvironment.prepare()
        let today = URL(string: "https://today.example")!
        let pinned = URL(string: "https://pinned.example")!
        let space = Space(name: "Work", profileID: UUID(), tabURLs: [today], pinnedTabURLs: [pinned])
        let expanded = SpacePreviewList(space: space, liveTabs: nil)
        let collapsed = SpacePreviewList(space: space, liveTabs: nil, pinnedCollapsed: true)
        XCTAssertEqual(expanded.rows.pinned.count, 1)
        XCTAssertTrue(collapsed.rows.pinned.isEmpty)
        XCTAssertEqual(collapsed.rows.today.count, 1)
    }

    func testPrivateWindowCannotCollapseASpaceCard() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, session: [])
        defer {
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
        }
        XCTAssertNil(store.currentSpaceID)
        store.toggleSpaceCard()
        XCTAssertFalse(store.spaceCardCollapsed)
    }
}
