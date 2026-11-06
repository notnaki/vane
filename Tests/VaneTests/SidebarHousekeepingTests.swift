import AppKit
import Combine
import QuartzCore
import XCTest
@testable import vane

@MainActor final class SidebarHousekeepingTests: XCTestCase {
    private func fixture(count: Int = 12, isPrivate: Bool = false, spaceID: UUID? = nil) -> (TabStore, [Tab]) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let space = spaceID.map { Space(id: $0, name: "Housekeeping", profileID: profile) }
        let store = TabStore(isPrivate: isPrivate, profileID: profile, space: space, session: [])
        store.sharingReady = false
        let tabs = (0..<count).map { index -> Tab in
            let tab = Tab(isPrivate: isPrivate, profileID: store.profileID)
            tab.park(url: URL(string: "https://example.test/page/\(index)")!,
                     Parked(title: "Housekeeping page \(index)"))
            return tab
        }
        store.tabs = tabs
        store.syncShapes()
        store.current = nil
        addTeardownBlock { @MainActor in
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            tabs.forEach { $0.tearDown() }
            SharedTabs.release(tabs)
            Archive.shared(for: store.profileID).clear()
            Store.forget(store.profileID)
            while ClosedTabs.pop() != nil {}
        }
        return (store, tabs)
    }

    func testClearFinishesSynchronouslyWithOneCompletedSidebarAndArchiveUpdate() {
        let (store, tabs) = fixture(count: 60)
        let urls = tabs.map { $0.currentURL!.absoluteString }
        let archive = Archive.shared(for: store.profileID)
        for index in 0..<Archive.limit {
            archive.add(url: URL(string: "https://older.test/\(index)")!, title: "Older")
        }
        var outlines: [[UUID]] = [], archives = 0
        let subscriptions = [
            store.sidebarObservation.objectWillChange.sink { outlines.append(store.tabs.map(\.id)) },
            archive.$entries.dropFirst().sink { _ in archives += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        let started = CACurrentMediaTime()
        store.archiveToday(tabs.map(\.id))
        print("SIDEBAR_CLEAR tabs=\(tabs.count) input_ms=\((CACurrentMediaTime() - started) * 1000) sidebar_updates=\(outlines.count) archive_updates=\(archives)")
        XCTAssertTrue(store.tabs.isEmpty, "Clear must finish its model mutation on the input turn")
        XCTAssertEqual(outlines, [[]], "The sidebar must receive only the completed clear")
        XCTAssertEqual(archives, 1, "Save and publish the capped archive once per Clear")
        XCTAssertEqual(archive.entries.prefix(tabs.count).map(\.url), Array(urls.reversed()))
        XCTAssertEqual(archive.entries.count, Archive.limit)
        XCTAssertNil(store.current)
    }

    func testClearKeepsPinsFavouritesAndLockedTodayTabs() {
        let (store, tabs) = fixture(count: 8)
        tabs[0].kind = .favourite
        tabs[1].kind = .pinned
        store.syncShapes()
        var folder = Folder(name: "Protected Today")
        folder.requiresAuthentication = true
        store.todayShape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(tabs[2].id.uuidString), parent: folder.id)]
            + tabs.dropFirst(3).map { .init(row: .tab($0.id.uuidString)) })
        store.archiveToday(tabs.map(\.id) + [tabs[3].id, UUID()])
        XCTAssertEqual(store.tabs.map(\.id), Array(tabs.prefix(3)).map(\.id))
        XCTAssertNotNil(store.todayShape.folder(folder.id))
        XCTAssertEqual(Archive.shared(for: store.profileID).entries.count, 5)
        XCTAssertTrue(tabs.prefix(3).allSatisfy { !$0.tornDown })
        XCTAssertTrue(tabs.dropFirst(3).allSatisfy(\.tornDown))
    }

    func testClearPrivateTabsLeavesNoArchiveOrReopenEntry() {
        let (store, tabs) = fixture(isPrivate: true)
        store.archiveToday(tabs.map(\.id))
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertTrue(Archive.shared(for: store.profileID).entries.isEmpty)
        XCTAssertNil(ClosedTabs.pop())
    }

    func testClearRemovesSharedReferencesWithoutWakingDoomedNeighbours() {
        let (store, tabs) = fixture(count: 8, spaceID: UUID())
        let space = Space(id: store.currentSpaceID!, name: "Shared housekeeping", profileID: store.profileID)
        let peer = TabStore(profileID: store.profileID, space: space, session: [])
        peer.sharingReady = false
        XCTAssertTrue(store.sharesTabs && peer.sharesTabs, "The fixture must exercise real shared-Space removal")
        peer.tabs = tabs
        peer.syncShapes()
        let stashedSpace = UUID()
        peer.stashes[stashedSpace] = Stash(tabs: tabs, pins: Pins(), todayShape: peer.todayShape,
                                          splits: [], current: tabs[0].id, fingerprint: "")
        addTeardownBlock { @MainActor in
            peer.dropStashes()
            TabStore.all.removeAll { $0 === peer }
        }
        store.current = tabs[0].id
        peer.current = tabs[0].id
        var resumed: [UUID] = [], peerOutlines: [[UUID]] = []
        var subscriptions = tabs.dropFirst().map { tab in
            tab.$suspended.dropFirst().sink { if !$0 { resumed.append(tab.id) } }
        }
        subscriptions.append(peer.sidebarObservation.objectWillChange.sink { peerOutlines.append(peer.tabs.map(\.id)) })
        defer { subscriptions.forEach { $0.cancel() } }
        store.archiveToday(tabs.map(\.id))
        XCTAssertTrue(resumed.isEmpty, "Clear must never resume another tab it is about to retire")
        XCTAssertTrue(peer.tabs.isEmpty)
        XCTAssertTrue(peer.stashes[stashedSpace]?.tabs.isEmpty == true)
        XCTAssertEqual(peerOutlines, [[]])
        XCTAssertNil(store.current)
        XCTAssertNil(peer.current)
    }

    func testBulkArchivePreservesReopenOrderAndLastDuplicateURL() {
        let (store, tabs) = fixture(count: 4)
        let urls = tabs.map { $0.currentURL! }
        tabs[3].park(url: urls[0], Parked(title: "Last duplicate"))
        store.archiveToday(tabs.map(\.id))
        let entries = Archive.shared(for: store.profileID).entries
        XCTAssertEqual(entries.map(\.url), [urls[0], urls[2], urls[1]].map(\.absoluteString))
        XCTAssertEqual(entries.first?.title, "Last duplicate")
        var reopened: [URL] = []
        while let entry = ClosedTabs.pop() { reopened.append(entry.url) }
        XCTAssertEqual(reopened, [urls[0], urls[2], urls[1], urls[0]])
    }

    func testBulkArchiveSelectsOnlyTheFinalSurvivingNeighbour() {
        let (store, tabs) = fixture(count: 4)
        store.current = tabs[0].id
        var selections: [UUID?] = []
        var doomedResumes = 0
        let subscriptions = [
            store.$current.dropFirst().sink { selections.append($0) },
            tabs[1].$suspended.dropFirst().sink { if !$0 { doomedResumes += 1 } }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        store.archiveToday([tabs[0].id, tabs[1].id])
        XCTAssertEqual(store.current, tabs[2].id)
        XCTAssertEqual(selections, [tabs[2].id])
        XCTAssertEqual(doomedResumes, 0)
    }

    func testBulkArchivePreservesCallerOrderInsteadOfTemporaryStripOrder() {
        let (store, tabs) = fixture(count: 4)
        let requested = [tabs[3], tabs[1], tabs[2], tabs[0]]
        let expected = requested.reversed().map { $0.currentURL!.absoluteString }
        store.archiveToday(requested.map(\.id))
        XCTAssertEqual(Archive.shared(for: store.profileID).entries.map(\.url), expected)
        var reopened: [String] = []
        while let entry = ClosedTabs.pop() { reopened.append(entry.url.absoluteString) }
        XCTAssertEqual(reopened, expected)
    }

    func testBulkArchiveKeepsTheSurvivingPinnedSplitPane() {
        let (store, tabs) = fixture(count: 4)
        tabs[3].kind = .pinned
        store.syncShapes()
        store.splits = [Split(tabs: [tabs[0].id, tabs[1].id, tabs[3].id])!]
        store.current = tabs[0].id
        store.archiveToday(tabs.prefix(3).map(\.id))
        XCTAssertEqual(store.tabs.map(\.id), [tabs[3].id])
        XCTAssertEqual(store.current, tabs[3].id)
        XCTAssertTrue(store.splits.isEmpty)
        XCTAssertFalse(tabs[3].tornDown)
    }

    func testArchiveSelectionKeepsPinnedCloseRulesAndBatchesToday() {
        for kind in [TabKind.today, .pinned] {
            let (store, tabs) = fixture(count: 4)
            tabs.forEach { $0.kind = kind }
            store.syncShapes()
            store.selection.selectAll(in: .init(kind: kind, ids: tabs.map(\.id)))
            var changes = 0
            let subscription = store.sidebarObservation.objectWillChange.sink { changes += 1 }
            store.archiveSelection()
            subscription.cancel()
            XCTAssertTrue(store.selection.isEmpty)
            XCTAssertEqual(changes, 1)
            if kind == .today { XCTAssertTrue(store.tabs.isEmpty) }
            else {
                XCTAssertEqual(store.tabs.count, tabs.count, "Closing parked pins unpins them instead of deleting their pages")
                XCTAssertTrue(Archive.shared(for: store.profileID).entries.isEmpty)
            }
        }
    }

    func testTidyAndUndoPublishOnlyFinishedShapeAndSidebar() {
        let (store, tabs) = fixture(count: 60)
        let original = store.todayShape
        let originalOrder = tabs.map(\.id)
        // Reordering as well as filing must share the same completed publication.
        let groups = (0..<6).map { group in
            TidyTabs.Group(name: "Group \(group)", tabIDs: stride(from: group, to: tabs.count, by: 6).map { tabs[$0].id })
        }
        var outlines: [Pins] = [], shapes: [Pins] = []
        let subscriptions = [
            store.sidebarObservation.objectWillChange.sink { outlines.append(store.todayShape) },
            store.$todayShape.dropFirst().sink { shapes.append($0) }
        ]
        defer { subscriptions.forEach { $0.cancel() } }
        let started = CACurrentMediaTime()
        XCTAssertEqual(TidyTabs.apply(groups, to: store), 6)
        print("SIDEBAR_TIDY tabs=\(tabs.count) input_ms=\((CACurrentMediaTime() - started) * 1000) sidebar_updates=\(outlines.count) shape_updates=\(shapes.count)")
        XCTAssertEqual(outlines, [store.todayShape])
        XCTAssertEqual(shapes, [store.todayShape])
        XCTAssertEqual(store.todayShape.filed.count, tabs.count)
        XCTAssertEqual(store.tabs.map(\.id), groups.flatMap(\.tabIDs))
        outlines = []; shapes = []
        TidyTabs.undo(store)
        XCTAssertEqual(outlines, [original])
        XCTAssertEqual(shapes, [original])
        XCTAssertEqual(store.todayShape, original)
        XCTAssertEqual(store.tabs.map(\.id), originalOrder)
    }

    func testSynchronizingUnchangedShapesDoesNotInvalidateSidebar() {
        let (store, _) = fixture()
        var changes = 0
        let subscription = store.sidebarObservation.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        store.syncShapes()
        XCTAssertEqual(changes, 0, "No-op shape maintenance must not rebuild sidebar hosts")
    }
}
