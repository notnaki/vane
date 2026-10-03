import XCTest
@testable import vane

@MainActor final class FolderExitTests: XCTestCase {
    func testDropOnTodayMovesTidyTabsToRootInSelectionOrder() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let tabs = (0..<4).map { _ in store.newBlankTab(focus: false) }
        let ids = tabs.map(\.id)
        _ = TidyTabs.apply([.init(name: "Work", tabIDs: [ids[0], ids[1]]),
                           .init(name: "Reading", tabIDs: [ids[2], ids[3]])], to: store)
        XCTAssertEqual(store.todayShape.filed.count, 4)

        store.dropAtSectionRoot([ids[0], ids[1]], into: .today)

        XCTAssertEqual(store.tabs.map(\.id), ids)
        XCTAssertEqual(store.todayShape.visible.prefix(2).map(\.entry.tab),
                       [ids[0].uuidString, ids[1].uuidString])
        XCTAssertEqual(store.todayShape.filed, Set([ids[2].uuidString, ids[3].uuidString]))
        XCTAssertEqual(store.todayShape.entries.compactMap(\.folder).map(\.name), ["Reading"])
        XCTAssertTrue(tabs.allSatisfy { $0.kind == .today })
    }

    func testRemovingNestedPinnedTabKeepsItsKindAndOtherFolderContents() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let first = store.newBlankTab(focus: false, as: .pinned)
        let second = store.newBlankTab(focus: false, as: .pinned)
        let outer = store.pins.newFolder(named: "Outer")!
        let inner = store.pins.newFolder(named: "Inner")!
        store.pins.move(inner.id.uuidString, into: outer.id)
        store.pins.move(first.id.uuidString, into: inner.id)
        store.pins.move(second.id.uuidString, into: outer.id)
        store.applyOrder(.pinned)

        store.dropAtSectionRoot([first.id], into: .pinned)

        XCTAssertNil(store.pins.spot(of: first.id.uuidString)?.parent)
        XCTAssertEqual(store.pins.children(of: outer.id), [second.id.uuidString])
        XCTAssertEqual(store.tabs.map(\.id), [second.id, first.id])
        XCTAssertEqual(first.kind, .pinned)
        XCTAssertNotNil(store.pins.folder(inner.id))
    }

    func testCrossSectionRootDropPreservesRunOrderAndEveryTab() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let pinned = (0..<2).map { _ in store.newBlankTab(focus: false, as: .pinned) }
        let today = store.newBlankTab(focus: false)
        store.dropAtSectionRoot(pinned.map(\.id), into: .today)
        XCTAssertEqual(store.tabs.map(\.id), pinned.map(\.id) + [today.id])
        XCTAssertTrue(store.tabs.allSatisfy { $0.kind == .today })
        XCTAssertTrue(store.pins.tabs.isEmpty)
        XCTAssertTrue(store.todayShape.filed.isEmpty)
    }

    func testBottomDropLeavesCollapsedLastFolderAndKeepsRunAtEnd() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let tabs = (0..<4).map { _ in store.newBlankTab(focus: false) }
        let ids = tabs.map(\.id)
        _ = TidyTabs.apply([.init(name: "Work", tabIDs: [ids[0], ids[1]]),
                           .init(name: "Reading", tabIDs: [ids[2], ids[3]])], to: store)
        let folder = store.todayShape.entries.compactMap(\.folder).last!
        store.todayShape.edit(folder: folder.id) { $0.collapsed = true }
        XCTAssertEqual(store.todayShape.visible.last?.entry.folder?.id, folder.id)

        store.dropAtSectionRoot([ids[2], ids[3]], into: .today, atEnd: true)

        XCTAssertEqual(store.todayShape.visible.suffix(2).map(\.entry.tab),
                       [ids[2].uuidString, ids[3].uuidString])
        XCTAssertTrue(store.todayShape.visible.suffix(2).allSatisfy { $0.depth == 0 })
        XCTAssertEqual(store.tabs.map(\.id), ids)
        XCTAssertEqual(store.todayShape.filed, Set([ids[0].uuidString, ids[1].uuidString]))
        XCTAssertNil(store.todayShape.folder(folder.id))
        XCTAssertTrue(tabs.allSatisfy { $0.kind == .today })
    }

    func testBottomDropAppendsPinnedRunAfterExistingTodayTabs() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let pinned = (0..<2).map { _ in store.newBlankTab(focus: false, as: .pinned) }
        let today = store.newBlankTab(focus: false)

        store.dropAtSectionRoot(pinned.map(\.id), into: .today, atEnd: true)

        XCTAssertEqual(store.tabs.map(\.id), [today.id] + pinned.map(\.id))
        XCTAssertTrue(store.tabs.allSatisfy { $0.kind == .today })
        XCTAssertTrue(store.todayShape.filed.isEmpty)
    }

    private func cleanUp(_ store: TabStore) {
        store.tabs.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
        Store.forget(store.profileID)
    }
}
