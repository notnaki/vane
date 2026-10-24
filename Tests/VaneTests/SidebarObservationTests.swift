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

    func testLiveOnlyPresentationChangesDoNotInvalidateCapturedSidebars() {
        let store = fixture()
        var snapshots = 0
        var draws = 0
        let snapshotObservation = store.sidebarSnapshotChanges.sink { snapshots += 1 }
        let liveObservation = store.sidebarObservation.objectWillChange.sink { draws += 1 }
        defer { snapshotObservation.cancel(); liveObservation.cancel() }
        XCTAssertEqual(snapshots, 0, "Subscribing must not report initial published values as mutations")
        XCTAssertEqual(draws, 0)

        func assertLiveOnly(_ name: String, _ change: () -> Void) {
            let before = draws
            change()
            XCTAssertGreaterThan(draws, before, "\(name) must redraw live controls synchronously")
            XCTAssertEqual(snapshots, 0, "\(name) must not retire unchanged captured sidebars")
        }
        assertLiveOnly("Tab rename") { store.renamingTab = UUID() }
        assertLiveOnly("Folder rename") { store.renamingFolder = UUID() }
        assertLiveOnly("Space rename") { store.renamingSpace = UUID() }
        assertLiveOnly("Live folder announcement") { store.announcing = UUID() }
        assertLiveOnly("Space creation") { store.creatingSpace = true }
    }

    func testSnapshotChangesRevokeBeforeOutlineAssignmentAndIncludeProtection() {
        let store = fixture()
        var visibleShapes: [Pins] = []
        let observation = store.sidebarSnapshotChanges.sink { visibleShapes.append(store.todayShape) }
        defer { observation.cancel() }
        XCTAssertTrue(visibleShapes.isEmpty)

        let changed = Pins(entries: [.init(row: .folder(Folder(name: "Protected outline")))])
        store.todayShape = changed
        XCTAssertEqual(visibleShapes, [Pins()],
                       "A subscriber must revoke a stale capture before the new outline is installed")
        store.sidebarPreviewInvalidated.send()
        XCTAssertEqual(visibleShapes, [Pins(), changed],
                       "Protection revocation must publish synchronously without a shape assignment")
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
