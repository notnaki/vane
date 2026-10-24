import AppKit
import Combine
import XCTest
@testable import vane

@MainActor final class TabClosePublicationTests: XCTestCase {
    private func fixture() -> (TabStore, [Tab]) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let tabs = (0..<3).map { index -> Tab in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#close-publication-\(index)")!,
                     Parked(title: "Close fixture \(index)"))
            return tab
        }
        store.tabs = tabs
        store.syncShapes()
        store.current = nil
        addTeardownBlock { @MainActor in
            store.dropStashes()
            tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        return (store, tabs)
    }

    func testBackgroundTodayCloseDoesNotInvalidateUnchangedPinsOrSelection() {
        let (store, tabs) = fixture()
        var folder = Folder(name: "Keep empty protected pin")
        folder.requiresAuthentication = true
        let pins = Pins(entries: [.init(row: .folder(folder))])
        store.pins = pins
        store.selection.toggle(tabs[0].id, in: .init(kind: .today, ids: tabs.map(\.id)))
        let selected = store.selection
        var pinChanges = 0, selectionChanges = 0, tabChanges = 0
        let observations = [
            store.$pins.dropFirst().sink { _ in pinChanges += 1 },
            store.$selection.dropFirst().sink { _ in selectionChanges += 1 },
            store.$tabs.dropFirst().sink { _ in tabChanges += 1 }
        ]
        defer { observations.forEach { $0.cancel() } }

        store.close(tabs[1].id)

        XCTAssertEqual(store.tabs.map(\.id), [tabs[0].id, tabs[2].id])
        XCTAssertEqual(store.pins, pins)
        XCTAssertEqual(store.selection, selected)
        XCTAssertEqual(pinChanges, 0, "Closing Today must not invalidate an unchanged pinned outline")
        XCTAssertEqual(selectionChanges, 0, "An unchanged surviving selection must not redraw every row")
        XCTAssertEqual(tabChanges, 1, "The actual tab removal must still publish")
        XCTAssertNil(store.current)
    }

    func testLastTodayFolderClosePublishesOnlyThePrunedOutline() {
        let (store, tabs) = fixture()
        let folder = Folder(name: "Last child closes")
        store.todayShape = Pins(entries: [
            .init(row: .folder(folder)),
            .init(row: .tab(tabs[1].id.uuidString), parent: folder.id),
            .init(row: .tab(tabs[0].id.uuidString)),
            .init(row: .tab(tabs[2].id.uuidString))
        ])
        var transitions: [Pins] = []
        var selectionChanges = 0
        let shapeObservation = store.$todayShape.dropFirst().sink { transitions.append($0) }
        let selectionObservation = store.$selection.dropFirst().sink { _ in selectionChanges += 1 }
        defer { shapeObservation.cancel(); selectionObservation.cancel() }

        store.close(tabs[1].id)

        let expected = Pins(entries: [.init(row: .tab(tabs[0].id.uuidString)),
                                      .init(row: .tab(tabs[2].id.uuidString))])
        XCTAssertEqual(store.todayShape, expected)
        XCTAssertEqual(transitions, [expected],
                       "Observers must see one completed close, never a transient empty Today folder")
        XCTAssertEqual(selectionChanges, 0, "An empty selection must not invalidate the outline")
    }

    func testCloseRemovesSelectedIDAndKeepsSynchronousWillChange() {
        let (store, tabs) = fixture()
        store.selection.selectAll(in: .init(kind: .today, ids: tabs.map(\.id)))
        let before = store.selection
        var changes: [(published: Selection, previous: Selection)] = []
        let observation = store.$selection.dropFirst().sink { changes.append(($0, store.selection)) }
        defer { observation.cancel() }

        store.close(tabs[0].id)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.previous, before,
                       "Selection publication must remain synchronous and precede its assignment")
        XCTAssertEqual(changes.first?.published, store.selection)
        XCTAssertEqual(store.selection.ids, Set([tabs[1].id, tabs[2].id]))
        XCTAssertEqual(store.selection.anchor, tabs[1].id)
    }
}
