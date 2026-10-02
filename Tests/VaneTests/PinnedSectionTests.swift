import XCTest
@testable import vane

@MainActor final class PinnedSectionTests: XCTestCase {
    func testCollapseKeepsPinsAndSelectionAndIsIndependentPerSpace() {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Space(name: "First", profileID: profile,
                          tabURLs: [URL(string: "about:blank")!],
                          pinnedTabURLs: [URL(string: "https://example.com")!])
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first)
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        let pins = store.pins
        let selected = store.current
        XCTAssertFalse(store.pinnedSectionCollapsed)
        store.togglePinnedSection()
        XCTAssertTrue(store.pinnedSectionCollapsed)
        XCTAssertEqual(store.pins, pins)
        XCTAssertEqual(store.current, selected)
        XCTAssertTrue(store.swipePreview(in: first).rows.pinned.isEmpty)
        XCTAssertEqual(store.swipePreview(in: first).rows.today.count, 1)

        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertFalse(store.pinnedSectionCollapsed)
        store.switchTo(space: first)
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertTrue(store.pinnedSectionCollapsed)
        store.togglePinnedSection()
        XCTAssertFalse(store.pinnedSectionCollapsed)
        XCTAssertEqual(store.pins, pins)
        XCTAssertFalse(store.swipePreview(in: first).rows.pinned.isEmpty)
    }
}
