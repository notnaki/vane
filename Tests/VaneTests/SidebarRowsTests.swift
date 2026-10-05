import XCTest
@testable import vane

@MainActor final class SidebarRowsTests: XCTestCase {
    func testFolderDepthCollapseStaleIDsAndSectionOrder() {
        TestEnvironment.prepare()
        let tabs = (0..<3).map { _ in Tab(profileID: UUID()) }
        let outer = Folder(name: "Outer"), inner = Folder(name: "Inner")
        var shape = Pins(entries: [
            .init(row: .tab(tabs[2].id.uuidString)),
            .init(row: .folder(outer)),
            .init(row: .folder(inner), parent: outer.id),
            .init(row: .tab(tabs[0].id.uuidString), parent: inner.id),
            .init(row: .tab("stale"), parent: outer.id),
            .init(row: .tab(tabs[1].id.uuidString))
        ])
        let rows = SidebarRows(tabs: tabs, splits: [], shape: shape).rows
        XCTAssertEqual(rows.map(\.id), [tabs[2].id.uuidString, outer.id.uuidString,
                                        inner.id.uuidString, tabs[0].id.uuidString, tabs[1].id.uuidString])
        XCTAssertEqual(rows.map(\.visible.depth), [0, 0, 1, 2, 0])
        XCTAssertTrue(rows[3].tab === tabs[0])
        XCTAssertNil(rows[1].tab)

        shape.edit(folder: outer.id) { $0.collapsed = true }
        XCTAssertEqual(SidebarRows(tabs: tabs, splits: [], shape: shape).rows.map(\.id),
                       [tabs[2].id.uuidString, outer.id.uuidString, tabs[1].id.uuidString])
    }

    func testSplitLeadSkipsFavouriteAndFollowsStripRatherThanPaneOrder() {
        TestEnvironment.prepare()
        let tabs = (0..<4).map { _ in Tab(profileID: UUID()) }
        tabs[0].kind = .favourite
        tabs[1].kind = .pinned
        let split = Split(tabs: [tabs[3].id, tabs[0].id, tabs[1].id])!
        let shape = Pins(entries: tabs.reversed().map { .init(row: .tab($0.id.uuidString)) })
        let rows = SidebarRows(tabs: tabs, splits: [split], shape: shape).rows
        XCTAssertEqual(rows.compactMap { $0.tab?.id }, [tabs[2].id, tabs[1].id])

        let reordered = [tabs[3], tabs[0], tabs[1], tabs[2]]
        XCTAssertEqual(SidebarRows(tabs: reordered, splits: [split], shape: shape).rows
            .compactMap { $0.tab?.id }, [tabs[3].id, tabs[2].id])
        XCTAssertEqual(SidebarRows(tabs: tabs, splits: [], shape: shape).rows.count, 4)
    }

    func testDuplicateIDsAndOverlappingSplitsKeepFirstMatchSemantics() {
        TestEnvironment.prepare()
        let first = Tab(profileID: UUID()), duplicate = Tab(id: first.id, profileID: UUID())
        let second = Tab(profileID: UUID()), third = Tab(profileID: UUID())
        let shape = Pins(entries: [first, second, third].map { .init(row: .tab($0.id.uuidString)) })
        let rows = SidebarRows(tabs: [first, duplicate, second, third],
                               splits: [Split(tabs: [first.id, second.id])!,
                                        Split(tabs: [second.id, third.id])!], shape: shape).rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.first?.tab === first)
    }

    func testAllFavouriteSplitUsesFirstPaneAndMissingTabDisappears() {
        TestEnvironment.prepare()
        let tabs = (0..<2).map { _ in Tab(profileID: UUID()) }
        tabs.forEach { $0.kind = .favourite }
        let split = Split(tabs: [tabs[1].id, tabs[0].id])!
        let shape = Pins(entries: tabs.map { .init(row: .tab($0.id.uuidString)) })
        XCTAssertEqual(SidebarRows(tabs: tabs, splits: [split], shape: shape).rows
            .compactMap { $0.tab?.id }, [tabs[1].id])
        XCTAssertTrue(SidebarRows(tabs: [tabs[0]], splits: [split], shape: shape).rows.isEmpty)
    }
}
