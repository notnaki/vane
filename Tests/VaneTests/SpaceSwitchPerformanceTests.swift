import AppKit
import Combine
import XCTest
@testable import vane

@MainActor final class SpaceSwitchPerformanceTests: XCTestCase {
    func testBulkFavouriteRestoreDoesNotReinsertRowsPropagatedToOtherWindows() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Shared restore fixture").id
        let spaces = (0..<3).map { Space(name: "Window \($0)", profileID: profile) }
        XCTAssertTrue(manager.saveSpaces(spaces, for: profile))
        let stores = spaces.map { TabStore(profileID: profile, space: $0, session: []) }
        defer {
            SharedTabs.flush()
            let owned = stores.flatMap(\.everyTab)
            stores.forEach { $0.dropStashes() }
            TabStore.all.removeAll { store in stores.contains { $0 === store } }
            SharedTabs.release(owned)
            Store.forget(profile)
            manager.delete(profile)
        }
        let urls = (0..<2).map { URL(string: "https://example.test/favourite/\($0)")! }
        for store in stores {
            let restored = store.restore(urls, as: .favourite, parked: [:])
            XCTAssertEqual(restored.count, urls.count)
        }
        SharedTabs.flush()
        let expected = stores[0].tabs.map(\.id)
        for store in stores {
            XCTAssertEqual(store.tabs.count, urls.count)
            XCTAssertEqual(store.tabs.map(\.id), expected)
            XCTAssertEqual(Set(store.tabs.map(\.id)).count, urls.count)
        }
    }

    func testColdSpacePublishesCompletedCollectionsInsteadOfEachRestoredTab() throws {
        try checkColdRestore(template: false)
    }

    func testColdTemplatePublishesCompletedCollectionsInsteadOfEachRestoredTab() throws {
        try checkColdRestore(template: true)
    }

    private func checkColdRestore(template: Bool) throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Cold switch fixture").id
        let source = Space(name: "Source", profileID: profile)
        let urls = (0..<50).map { URL(string: "https://example.test/document/\($0)")! }
        var target = Space(name: "Destination", profileID: profile, tabURLs: urls)
        if template {
            let pages = urls.map { SpaceLayout.Page(id: UUID(), url: $0, kind: .today, title: "Saved page") }
            target.layout = SpaceLayout(tabs: pages, pins: Pins(),
                today: Pins(entries: pages.map { .init(row: .tab($0.id.uuidString)) }),
                splits: [], selected: pages.last?.id)
        }
        XCTAssertTrue(manager.saveSpaces([source, target], for: profile))
        let store = TabStore(profileID: profile, space: source, session: [])
        defer {
            let owned = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(owned)
            Store.forget(profile)
            manager.delete(profile)
        }
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        let start = ContinuousClock.now
        store.switchTo(space: target)
        observation.cancel()
        print("COLD_SPACE_SWITCH template=\(template) publications=\(publications) duration=\(start.duration(to: .now))")
        XCTAssertEqual(store.tabs.count, urls.count)
        XCTAssertEqual(store.todayShape.tabs.count, urls.count)
        XCTAssertEqual(store.tabs.compactMap(\.currentURL), urls)
        XCTAssertLessThan(publications, 40, "The content handoff must not invalidate the browser once per saved row")
        if template { XCTAssertEqual(store.current, target.layout?.selected) }
        XCTAssertLessThanOrEqual(store.tabs.filter { $0.existingWeb != nil }.count, 1)
    }
}
