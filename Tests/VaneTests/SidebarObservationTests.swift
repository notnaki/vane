import Combine
import SwiftUI
import XCTest
@testable import vane

@MainActor private final class SidebarDrawCount {
    var value = 0
}

private struct ObservedSidebarProbe: View {
    @SidebarObserved var store: TabStore
    let draws: SidebarDrawCount

    var body: some View {
        draws.value += 1
        return Text(store.renamingFolder?.uuidString ?? "No rename")
    }
}

@MainActor final class SidebarObservationTests: XCTestCase {
    private func fixture() -> TabStore {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        addTeardownBlock { @MainActor in
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return store
    }

    func testSearchAndChromeChangesDoNotInvalidateEverySidebarRow() {
        let store = fixture()
        var changes = 0
        let observation = store.sidebarObservation.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        for index in 0..<20 {
            store.palette = .newTab
            store.suggestions = []
            store.suggestionIndex = index
            store.palette = nil
            store.sidebarShown.toggle()
            store.sidebarPeeking.toggle()
            store.libraryOpen.toggle()
            store.findOpen.toggle()
        }
        XCTAssertEqual(changes, 0,
                       "Window presentation and search input must not fan out through the tab outline")
    }

    func testOutlineSelectionRenameAndProtectionStillInvalidateRowsSynchronously() {
        let store = fixture()
        var changes = 0
        let observation = store.sidebarObservation.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        func assertInvalidates(_ name: String, _ change: () -> Void) {
            let before = changes
            change()
            XCTAssertGreaterThan(changes, before, "\(name) must reach mounted rows on the same turn")
        }
        assertInvalidates("Tabs") { store.tabs = [] }
        assertInvalidates("Pinned folders") { store.pins = Pins() }
        assertInvalidates("Today folders") { store.todayShape = Pins() }
        assertInvalidates("Splits") { store.splits = [] }
        assertInvalidates("Selection") { store.selection.clear() }
        assertInvalidates("Current tab") { store.current = nil }
        assertInvalidates("Tab rename") { store.renamingTab = UUID() }
        assertInvalidates("Folder rename") { store.renamingFolder = UUID() }
        assertInvalidates("Space rename") { store.renamingSpace = UUID() }
        assertInvalidates("Pinned collapse") { store.togglePinnedSection() }
        assertInvalidates("Space creation") { store.creatingSpace.toggle() }
        assertInvalidates("Profile visibility") { store.profileVisible.toggle() }
        assertInvalidates("Folder protection") { store.sidebarPreviewInvalidated.send() }
    }

    func testMountedSidebarSkipsSearchUpdatesButRendersRenameChanges() async throws {
        let store = fixture()
        let draws = SidebarDrawCount()
        let host = NSHostingView(rootView: ObservedSidebarProbe(store: store, draws: draws))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 40)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let before = draws.value
        XCTAssertGreaterThan(before, 0)
        store.palette = .newTab
        for index in 0..<20 { store.suggestions = []; store.suggestionIndex = index }
        store.palette = nil
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(draws.value, before, "Search must not reevaluate mounted sidebar content")
        store.renamingFolder = UUID()
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { draws.value > before }
    }
}
