import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import vane

@MainActor final class FavouriteDragTests: XCTestCase {
    func testTilePayloadExportsPageLinkAndKeepsInternalIdentity() async throws {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { clean(store) }
        let tab = store.tabs[0]
        let url = URL(string: "https://example.com/favourite")!
        tab.park(url: url, Parked(title: "Favourite", state: nil))
        store.move(tab.id, to: .favourite)
        let provider = dragPayload(tab, in: store)
        await Task.yield()
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(Dragging.tabType.identifier))
        let text = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        XCTAssertEqual(text, url.absoluteString)
        XCTAssertEqual(Dragging.shared.tab, tab.id)
        let exported = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { value, _ in
                continuation.resume(returning: value)
            }
        }
        XCTAssertEqual(exported, url)
        Dragging.shared.cancel()
    }

    func testDroppedLinkLandsBesideTileAndKeepsCurrentPage() throws {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { clean(store) }
        let first = store.tabs[0], last = store.tabs[1]
        store.move(first.id, to: .favourite)
        store.move(last.id, to: .favourite)
        let current = store.current
        let url = URL(string: "https://example.com/dropped")!
        let tab = try XCTUnwrap(TabActions.favouriteDropped(url, in: store,
                                                           beside: last.id, after: false))
        XCTAssertEqual(store.tabs.filter { $0.kind == .favourite }.map(\.id),
                       [first.id, tab.id, last.id])
        XCTAssertEqual(tab.homeURL, url)
        XCTAssertEqual(tab.currentURL, url)
        XCTAssertTrue(tab.suspended)
        XCTAssertEqual(store.current, current)
    }

    func testGridGapDropAddsFavouriteAndTileCanMoveBackToLists() {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { clean(store) }
        let first = store.tabs[0], incoming = store.tabs[1]
        store.move(first.id, to: .favourite)
        store.dropAtSectionRoot([incoming.id], into: .favourite)
        XCTAssertEqual(store.tabs.filter { $0.kind == .favourite }.map(\.id), [first.id, incoming.id])
        store.dropAtSectionRoot([incoming.id], into: .pinned)
        XCTAssertEqual(incoming.kind, .pinned)
        store.dropAtSectionRoot([first.id], into: .today)
        XCTAssertEqual(first.kind, .today)
        XCTAssertFalse(store.tabs.contains { $0.kind == .favourite })
    }

    func testFirstFavouriteMovesExistingTabWithoutDuplicatingIt() {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { clean(store) }
        let tab = store.tabs[1]
        let ids = Set(store.tabs.map(\.id))
        store.dropInFavourites([tab.id], at: 0)
        XCTAssertEqual(store.tabs.filter { $0.kind == .favourite }.map(\.id), [tab.id])
        XCTAssertEqual(Set(store.tabs.map(\.id)), ids)
        XCTAssertEqual(store.tabs.count, ids.count)
    }

    func testPreviewSlotCommitsSameOrderWithoutMutatingDuringHover() {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { clean(store) }
        let first = store.tabs[0], incoming = store.tabs[1], last = store.tabs[2]
        store.move(first.id, to: .favourite)
        store.move(last.id, to: .favourite)
        store.dropInFavourites([incoming.id], at: 1)
        XCTAssertEqual(store.tabs.map(\.id), [first.id, incoming.id, last.id])
        store.dropInFavourites([first.id], at: 2)
        XCTAssertEqual(store.tabs.map(\.id), [incoming.id, last.id, first.id])
    }

    func testIncomingLinkRejectsExecutableAndProfileLocalAddresses() {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { clean(store) }
        let original = store.tabs.map(\.id)
        for url in [URL(string: "javascript:alert(1)")!, URL(fileURLWithPath: "/tmp/test.pdf"),
                    EaselAddress.url(UUID())] {
            XCTAssertNil(TabActions.favouriteDropped(url, in: store))
        }
        XCTAssertEqual(store.tabs.map(\.id), original)
    }

    private func makeStore(isPrivate: Bool = true) -> TabStore {
        _ = NSApplication.shared
        let store = TabStore(isPrivate: isPrivate, profileID: UUID())
        store.tabs = (0..<3).map { _ in Tab(isPrivate: isPrivate, profileID: store.profileID) }
        store.syncShapes()
        return store
    }

    private func clean(_ store: TabStore) {
        Dragging.shared.cancel()
        store.tabs.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
        Store.forget(store.profileID)
    }
}
