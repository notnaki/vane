import Combine
import SwiftUI
import XCTest
@testable import vane

private typealias Tab = vane.Tab

@MainActor private final class SelectionDraws { var value = 0 }

private struct FocusedSelectionProbe: View {
    @SidebarObserved var store: TabStore
    let draws: SelectionDraws
    init(store: TabStore, id: UUID, draws: SelectionDraws) {
        _store = SidebarObserved(wrappedValue: store, scope: .tab(id), experimental: true)
        self.draws = draws
    }
    var body: some View {
        draws.value += 1
        return Text(store.selection.announcement)
    }
}

private struct SelectionContentProbe: View {
    let draws: SelectionDraws
    var body: some View {
        draws.value += 1
        return Text("Stable title")
    }
}

@MainActor final class SidebarSelectionObservationTests: XCTestCase {
    private func fixture() -> (TabStore, [Tab]) {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        let tabs = (0..<4).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#selection-\(index)")!, Parked(title: "Selection \(index)"))
            return tab
        }
        store.tabs = tabs
        store.todayShape = Pins(entries: tabs.map { .init(row: .tab($0.id.uuidString)) })
        addTeardownBlock { @MainActor in
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return (store, tabs)
    }

    // Removing the focused current projection would turn this into four redraws.
    func testCurrentSelectionOnlyPublishesForOldAndNewRows() {
        let (store, tabs) = fixture()
        store.current = tabs[0].id
        let models = tabs.map { SidebarObservation(store: store, scope: .tab($0.id)) }
        let structure = SidebarObservation(store: store, scope: .structure)
        var counts = [0, 0, 0, 0]
        var structures = 0
        let observations = models.enumerated().map { index, model in
            model.objectWillChange.sink { counts[index] += 1 }
        }
        let structural = structure.objectWillChange.sink { structures += 1 }
        // A publisher subscription does not own SidebarObservation. Match SwiftUI's
        // @ObservedObject ownership rather than letting optimized ARC end this array
        // immediately after the subscription-building map above.
        weak var firstOwner = models[0]
        defer {
            withExtendedLifetime(models) {}
            withExtendedLifetime(structure) {}
            observations.forEach { $0.cancel() }
            structural.cancel()
        }
        store.current = tabs[1].id
        XCTAssertGreaterThan(counts[0], 0)
        XCTAssertGreaterThan(counts[1], 0)
        XCTAssertEqual(Array(counts[2...]), [0, 0])
        XCTAssertEqual(structures, 0)
        XCTAssertNotNil(firstOwner, "The test must retain mounted observation owners through the mutation")
    }

    // A count-only or membership-only projection loses either AX counts or bulk commands.
    func testBulkSelectionUpdatesMembersAndCountWithoutUnrelatedRows() {
        let (store, tabs) = fixture()
        let models = tabs.map { SidebarObservation(store: store, scope: .tab($0.id)) }
        var counts = [0, 0, 0, 0]
        let observations = models.enumerated().map { index, model in
            model.objectWillChange.sink { counts[index] += 1 }
        }
        weak var firstOwner = models[0]
        defer {
            withExtendedLifetime(models) {}
            observations.forEach { $0.cancel() }
        }
        let section = Selection.Section(kind: .today, ids: tabs.map(\.id))
        store.selection.toggle(tabs[0].id, in: section)
        store.selection.toggle(tabs[1].id, in: section)
        XCTAssertEqual(counts, [2, 1, 0, 0])
        XCTAssertEqual(selectionSuffix(true, store.selection.count), ", one of 2 selected")
        store.selection.toggle(tabs[2].id, in: section)
        XCTAssertEqual(counts, [3, 2, 1, 0])
        XCTAssertEqual(selectionSuffix(true, store.selection.count), ", one of 3 selected")
        XCTAssertNotNil(firstOwner, "The test must retain mounted observation owners through the mutation")
    }

    // Normalizing split focus globally must not hide it from its own row.
    func testSplitFocusAndManualPaneMetadataReachOnlyTheSplitRow() throws {
        let (store, tabs) = fixture()
        store.splits = [try XCTUnwrap(Split(tabs: [tabs[0].id, tabs[1].id]))]
        let split = SidebarObservation(store: store, scope: .tab(tabs[0].id))
        let other = SidebarObservation(store: store, scope: .tab(tabs[3].id))
        let structure = SidebarObservation(store: store, scope: .structure)
        var counts = [0, 0, 0]
        let observations = [split, other, structure].enumerated().map { index, model in
            model.objectWillChange.sink { counts[index] += 1 }
        }
        defer { observations.forEach { $0.cancel() } }
        store.splits[0] = store.splits[0].focusing(tabs[1].id)
        XCTAssertEqual(counts, [1, 0, 0])
        tabs[1].objectWillChange.send()
        XCTAssertEqual(counts, [2, 0, 0], "Manual title/mute notifications must reach split AX and voice controls")
        let replacement = Tab(id: tabs[1].id, isPrivate: true, profileID: store.profileID)
        store.tabs[1] = replacement
        counts = [0, 0, 0]
        tabs[1].objectWillChange.send()
        XCTAssertEqual(counts, [0, 0, 0], "Replaced objects must relinquish notification ownership")
        replacement.objectWillChange.send()
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testIncomingSplitMembershipDoesNotLeaveCurrentProjectionStale() throws {
        let (store, tabs) = fixture()
        store.current = tabs[2].id
        let row = SidebarObservation(store: store, scope: .tab(tabs[0].id))
        var changes = 0
        let observation = row.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        store.splits = [try XCTUnwrap(Split(tabs: [tabs[0].id, tabs[2].id]))]
        let before = changes
        store.current = tabs[3].id
        XCTAssertGreaterThan(changes, before, "Leaving a newly formed split must deselect its lead row")
    }

    // Global tooltip availability belongs to the light wrapper, not the title/editor surface.
    func testRenameMovesEditorAuthorityAndKeepsSectionInteractionLifetimeLive() {
        let (store, tabs) = fixture()
        let first = SidebarObservation(store: store, scope: .surface(tabs[0].id))
        let second = SidebarObservation(store: store, scope: .surface(tabs[1].id))
        let unrelated = SidebarObservation(store: store, scope: .surface(tabs[3].id))
        let lifetime = SidebarObservation(store: store, scope: .interactionLifetime)
        var counts = [0, 0, 0, 0]
        let observations = [first, second, unrelated, lifetime].enumerated().map { index, model in
            model.objectWillChange.sink { counts[index] += 1 }
        }
        defer { observations.forEach { $0.cancel() } }
        store.renamingTab = tabs[0].id
        XCTAssertEqual(Array(counts.prefix(3)), [1, 0, 0])
        XCTAssertGreaterThanOrEqual(counts[3], 1)
        let session = store.tabRenameSession
        store.renamingTab = tabs[1].id
        XCTAssertEqual(Array(counts.prefix(3)), [2, 1, 0])
        XCTAssertGreaterThanOrEqual(counts[3], 2)
        XCTAssertFalse(store.tabRenameSession === session)
        store.renamingFolder = UUID()
        XCTAssertEqual(counts[1], 2)
        XCTAssertGreaterThan(counts[3], 2)
    }

    func testRenameDraftSurvivesSelectionAndBulkCountChanges() throws {
        let (store, tabs) = fixture()
        store.renamingTab = tabs[0].id
        let session = try XCTUnwrap(store.tabRenameSession)
        session.prepare("Selection 0", tab: tabs[0])
        session.draft = "Uncommitted draft"
        let observer = SidebarObservation(store: store, scope: .surface(tabs[0].id))
        var changes = 0
        let observation = observer.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        store.current = tabs[1].id
        store.selection.toggle(tabs[2].id, in: .init(kind: .today, ids: tabs.map(\.id)))
        XCTAssertTrue(store.tabRenameSession === session)
        XCTAssertEqual(session.draft, "Uncommitted draft")
        XCTAssertEqual(changes, 0)
        store.renamingTab = nil
    }

    func testMountedUnselectedRowDoesNotReevaluateForSelectionElsewhere() async throws {
        let (store, tabs) = fixture()
        let draws = SelectionDraws()
        let host = NSHostingView(rootView: FocusedSelectionProbe(store: store, id: tabs[3].id, draws: draws))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 40)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let before = draws.value
        XCTAssertGreaterThan(before, 0)
        store.current = tabs[0].id
        store.selection.toggle(tabs[1].id, in: .init(kind: .today, ids: tabs.map(\.id)))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(draws.value, before)
        store.current = tabs[3].id
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { draws.value > before }
    }

    // If bulk observation moves back into TabRow, its captured heavy content redraws.
    func testBulkCountChangesLeaveMountedTitleContentIntact() async throws {
        let (store, tabs) = fixture()
        let section = Selection.Section(kind: .today, ids: tabs.map(\.id))
        store.selection.toggle(tabs[0].id, in: section)
        let draws = SelectionDraws()
        let host = NSHostingView(rootView: SelectionContentProbe(draws: draws)
            .modifier(SidebarTabRowInteractions(store: store, tab: tabs[0],
                returnHovering: .constant(false), experimental: true)))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 40)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let before = draws.value
        XCTAssertGreaterThan(before, 0)
        store.selection.toggle(tabs[1].id, in: section)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(draws.value, before, "Bulk/AX wrapper must not reevaluate captured title/editor content")
    }

    func testOptOutKeepsLegacyWholeSidebarInvalidation() {
        let (store, tabs) = fixture()
        let observed = SidebarObserved(wrappedValue: store, scope: .tab(tabs[3].id), experimental: false)
        // The wrapper's target remains authoritative and uses the existing shared observer.
        XCTAssertTrue(observed.wrappedValue === store)
        var changes = 0
        let observation = store.sidebarObservation.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }
        store.selection.clear()
        XCTAssertEqual(changes, 1)
    }
}
