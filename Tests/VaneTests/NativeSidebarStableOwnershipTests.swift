import AppKit
import SwiftUI
import XCTest
@testable import vane

/// These tests exercise the production NSHostingView cache and real AppKit field
/// editors. Repartitioning on topology changes or detaching an editing owner must
/// break identity, draft preservation, and authoritative index delivery below.
@MainActor final class NativeSidebarStableOwnershipTests: XCTestCase {
    private final class Controls {
        var fields: [String: WeakField] = [:]
        var commits: [(String, String)] = []
        var interactions: [String: NativeSidebarInteraction] = [:]
    }
    private final class WeakField {
        weak var value: NSTextField?
        init(_ value: NSTextField) { self.value = value }
    }
    private struct EditableRow: NSViewRepresentable {
        let id: String
        let index: Int
        let total: Int
        let controls: Controls
        @Environment(\.nativeSidebarInteraction) private var interaction
        final class Coordinator: NSObject, NSTextFieldDelegate {
            let id: String
            let controls: Controls
            init(id: String, controls: Controls) { self.id = id; self.controls = controls }
            func controlTextDidEndEditing(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                controls.commits.append((id, field.stringValue))
            }
        }
        func makeCoordinator() -> Coordinator { Coordinator(id: id, controls: controls) }
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(string: "Original")
            field.delegate = context.coordinator
            controls.fields[id] = WeakField(field)
            return field
        }
        func updateNSView(_ view: NSTextField, context: Context) {
            view.placeholderString = "\(index)/\(total)"
            controls.interactions[id] = interaction
        }
    }
    private func rows(_ count: Int) -> [SidebarRows.Row] {
        (0..<count).map { index in
            SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Row \(index)"))), depth: 0), tab: nil)
        }
    }
    private func owner(of field: NSView, in container: NSView) -> NSView? {
        var candidate: NSView? = field
        while let current = candidate, current.superview !== container { candidate = current.superview }
        return candidate
    }
    private func mount(_ container: NSView) -> NSWindow {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        scroll.documentView = container
        let window = NSWindow(contentRect: scroll.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// Attribution experiment: returning to a recently exposed Space must reuse
    /// its actual controls, while accepting current authoritative row membership.
    func testWarmSpaceReturnReusesNativeControlsAndAppliesCurrentMembership() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let first = rows(24), second = rows(24)
        let controls = Controls()
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        let view = NativeCachedSidebarBatchesView<EditableRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 979))
        let window = mount(view)
        defer {
            view.detach(); window.orderOut(nil); window.contentView = nil; window.close()
            store.dropStashes(); TabStore.all.removeAll { $0 === store }
        }
        let spaceA = UUID(), spaceB = UUID()
        func update(_ space: UUID, _ rows: [SidebarRows.Row]) {
            var environment = EnvironmentValues()
            let scope = SidebarNativeReadinessScope(store: store, spaceID: space)
            environment.sidebarNativeReadinessScope = scope
            view.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: environment, owner: store) { row, index, total in
                EditableRow(id: row.id, index: index, total: total, controls: controls)
            }
            XCTAssertFalse(SidebarNativeReadinessCoordinator.shared.isReady(scope),
                           "A restored graph must commit its current generation before readiness")
            view.reconcile(visible: CGRect(x: 0, y: 0, width: 250, height: 300))
            view.layoutSubtreeIfNeeded()
        }
        update(spaceA, first)
        try await compatibilityWait { controls.fields[first[3].id]?.value?.window === window }
        let original = try XCTUnwrap(controls.fields[first[3].id]?.value)
        let originalOwner = try XCTUnwrap(owner(of: original, in: view))
        update(spaceB, second)
        try await compatibilityWait { controls.fields[second[3].id]?.value?.window === window }
        XCTAssertNil(original.window, "Inactive controls must leave the native input/AX hierarchy")
        let coldCreates = view.batchCounts.coldGraphCreates
        update(spaceA, Array(first.dropFirst()))
        try await compatibilityWait {
            controls.fields[first[3].id]?.value?.placeholderString == "2/23"
                && SidebarNativeReadinessCoordinator.shared.isReady(
                    SidebarNativeReadinessScope(store: store, spaceID: spaceA))
        }
        XCTAssertNil(controls.fields[first[0].id]?.value?.window,
                     "A deleted cached control must leave the mounted native hierarchy")
        XCTAssertTrue(controls.fields[first[3].id]?.value === original,
                      "A warm return must reuse the original native control")
        XCTAssertTrue(owner(of: original, in: view) === originalOwner,
                      "A warm return must reuse its laid-out hosting graph")
        XCTAssertEqual(view.batchCounts.coldGraphCreates, coldCreates,
                       "A warm return must not recreate visible row hosting graphs")
        XCTAssertFalse(view.nativeRowsInAuthoritativeOrder().contains { $0.0 == first[0].id },
                       "Restored owners must apply current membership before exposure")
    }

    private func warmFixture(profileID: UUID = UUID()) -> (Controls, NativeCachedSidebarBatchesView<EditableRow>, NSWindow, TabStore) {
        TestEnvironment.prepare()
        let controls = Controls()
        let store = TabStore(profileID: profileID, session: [])
        let view = NativeCachedSidebarBatchesView<EditableRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 979))
        let window = mount(view)
        addTeardownBlock { @MainActor in
            view.detach(); window.orderOut(nil); window.contentView = nil; window.close()
            store.dropStashes(); TabStore.all.removeAll { $0 === store }
        }
        return (controls, view, window, store)
    }

    private func configureWarm(_ view: NativeCachedSidebarBatchesView<EditableRow>, store: TabStore,
                               space: UUID, rows: [SidebarRows.Row], controls: Controls) {
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = SidebarNativeReadinessScope(store: store, spaceID: space)
        view.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: environment, owner: store) { row, index, total in
            EditableRow(id: row.id, index: index, total: total, controls: controls)
        }
        view.reconcile(visible: CGRect(x: 0, y: 0, width: 250, height: 300))
        view.layoutSubtreeIfNeeded()
    }

    func testHiddenOwnerCannotRefillCacheThroughLaterNativeConfigurations() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (controls, view, _, store) = warmFixture()
        let rows = rows(24), a = UUID(), b = UUID(), c = UUID()
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        XCTAssertGreaterThan(view.inactiveGraphCount, 0)
        store.profileVisible = false
        XCTAssertEqual(view.inactiveGraphCount, 0)
        configureWarm(view, store: store, space: c, rows: rows, controls: controls)
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        XCTAssertEqual(view.inactiveGraphCount, 0)
        store.profileVisible = true
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        XCTAssertEqual(view.inactiveGraphCount, 0, "Showing a revoked visit cannot reauthorize its old graphs")
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        XCTAssertGreaterThan(view.inactiveGraphCount, 0, "A fresh visible visit can become warm again")
        view.detach()
        XCTAssertEqual(view.inactiveGraphCount, 0)
    }

    func testOldVisitCannotAcquireOrReleaseCurrentRowInteraction() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (controls, view, window, store) = warmFixture()
        let rows = rows(24), a = UUID(), b = UUID()
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        try await compatibilityWait { controls.fields[rows[3].id]?.value?.window === window }
        let outgoing = try XCTUnwrap(controls.interactions[rows[3].id])
        controls.interactions.removeAll()
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        try await compatibilityWait { controls.interactions[rows[3].id] != nil }
        let current = try XCTUnwrap(controls.interactions[rows[3].id])
        let token = UUID()
        current.set(true, token: token)
        XCTAssertTrue(view.protectedRows.contains(rows[3].id))
        outgoing.set(false, token: token)
        XCTAssertTrue(view.protectedRows.contains(rows[3].id), "An old visit cannot release the current presentation")
        current.set(false, token: token)
        outgoing.set(true, token: UUID())
        XCTAssertFalse(view.protectedRows.contains(rows[3].id), "An old visit cannot acquire a current keepalive")
    }

    func testReplacingSupplyingStoreCannotRestoreItsPredecessorsGraphs() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (controls, view, window, first) = warmFixture()
        let rows = rows(24), a = UUID(), b = UUID()
        configureWarm(view, store: first, space: a, rows: rows, controls: controls)
        try await compatibilityWait { controls.fields[rows[3].id]?.value?.window === window }
        let oldField = try XCTUnwrap(controls.fields[rows[3].id]?.value)
        configureWarm(view, store: first, space: b, rows: rows, controls: controls)
        XCTAssertGreaterThan(view.inactiveGraphCount, 0)
        let second = TabStore(profileID: UUID(), session: [])
        defer { second.dropStashes(); TabStore.all.removeAll { $0 === second } }
        configureWarm(view, store: second, space: a, rows: rows, controls: controls)
        XCTAssertEqual(view.inactiveGraphCount, 0)
        try await compatibilityWait { controls.fields[rows[3].id]?.value?.window === window }
        XCTAssertFalse(controls.fields[rows[3].id]?.value === oldField)
        XCTAssertNil(oldField.window)
    }

    func testOrdinaryPreviewInvalidationPreservesWarmControlReuse() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (controls, view, _, store) = warmFixture()
        let rows = rows(24), a = UUID(), b = UUID()
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        let retained = view.inactiveGraphCount
        XCTAssertGreaterThan(retained, 0)
        store.sidebarPreviewInvalidated.send()
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        XCTAssertEqual(view.inactiveGraphCount, retained)
        let cold = view.batchCounts.coldGraphCreates
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        XCTAssertEqual(view.batchCounts.inactiveScopeHits, 1)
        XCTAssertEqual(view.batchCounts.coldGraphCreates, cold)
    }

    func testMemoryPressurePreventsRefillUntilNormalAndAFreshVisit() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (controls, view, _, store) = warmFixture()
        let rows = rows(24), a = UUID(), b = UUID(), c = UUID()
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        XCTAssertGreaterThan(view.inactiveGraphCount, 0)
        SidebarWarmOwnerBudget.setUnderPressure(true)
        defer { SidebarWarmOwnerBudget.setUnderPressure(false) }
        XCTAssertEqual(view.inactiveGraphCount, 0)
        configureWarm(view, store: store, space: c, rows: rows, controls: controls)
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        XCTAssertEqual(view.inactiveGraphCount, 0)
        SidebarWarmOwnerBudget.setUnderPressure(false)
        configureWarm(view, store: store, space: a, rows: rows, controls: controls)
        configureWarm(view, store: store, space: b, rows: rows, controls: controls)
        XCTAssertEqual(view.inactiveGraphCount, 0)
        configureWarm(view, store: store, space: c, rows: rows, controls: controls)
        XCTAssertGreaterThan(view.inactiveGraphCount, 0)
    }

    func testFolderDefinitionRevokesAllProfileWindowsBeforeItPublishes() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VANE_RETAIN_INACTIVE_SPACE_ROW_OWNERS"] == "0")
        let (controls, view, _, store) = warmFixture()
        let (peerControls, peerView, _, peer) = warmFixture(profileID: store.profileID)
        let (otherControls, otherView, _, other) = warmFixture()
        let folder = Folder(name: "Protect warm rows")
        store.pins = Pins(entries: [.init(row: .folder(folder), parent: nil)])
        SharedTabs.flush()
        let rows = rows(24), a = UUID(), b = UUID()
        for (controls, view, owner) in [(controls, view, store), (peerControls, peerView, peer), (otherControls, otherView, other)] {
            configureWarm(view, store: owner, space: a, rows: rows, controls: controls)
            configureWarm(view, store: owner, space: b, rows: rows, controls: controls)
            XCTAssertGreaterThan(view.inactiveGraphCount, 0)
        }
        var revokedBeforePublications: [Bool] = []
        let observation = store.$pins.dropFirst().sink { shape in
            if shape.folder(folder.id)?.requiresAuthentication == true {
                revokedBeforePublications.append(view.inactiveGraphCount == 0 && peerView.inactiveGraphCount == 0)
            }
        }
        store.lockFolder(folder.id)
        withExtendedLifetime(observation) {}
        XCTAssertFalse(revokedBeforePublications.isEmpty)
        XCTAssertTrue(revokedBeforePublications.allSatisfy { $0 })
        XCTAssertEqual(view.inactiveGraphCount, 0)
        XCTAssertEqual(peerView.inactiveGraphCount, 0)
        XCTAssertGreaterThan(otherView.inactiveGraphCount, 0, "Another profile retains its authorized owners")
        XCTAssertEqual(store.pins.folder(folder.id)?.requiresAuthentication, true)
    }

    func testActualEditorAndHostSurviveEarlierDeletionInsertionAndCrossChunkReorder() async throws {
        var rows = rows(100)
        let original = rows
        let controls = Controls()
        let view = NativeCachedSidebarBatchesView<EditableRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 4095))
        let window = mount(view)
        defer { window.makeFirstResponder(nil); view.detach(); window.orderOut(nil); window.contentView = nil; window.close() }
        let pitch = Look.rowHeight + Look.rowGap
        func update(visibleIndex: Int) {
            view.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: EnvironmentValues()) { row, index, total in
                EditableRow(id: row.id, index: index, total: total, controls: controls)
            }
            view.reconcile(visible: CGRect(x: 0, y: CGFloat(visibleIndex) * pitch, width: 250, height: 300))
            view.layoutSubtreeIfNeeded()
        }
        update(visibleIndex: 36)
        let editedID = original[40].id
        try await compatibilityWait { controls.fields[editedID]?.value?.window != nil }
        let field = try XCTUnwrap(controls.fields[editedID]?.value)
        let host = try XCTUnwrap(owner(of: field, in: view))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.string = "Uncommitted native draft"
        let coldCreates = view.batchCounts.coldGraphCreates

        rows.removeFirst()
        update(visibleIndex: 36)
        try await compatibilityWait { controls.fields[editedID]?.value?.placeholderString == "39/99" }
        XCTAssertTrue(controls.fields[editedID]?.value === field)
        XCTAssertTrue(owner(of: field, in: view) === host)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Uncommitted native draft")
        XCTAssertLessThanOrEqual(view.batchCounts.coldGraphCreates - coldCreates, 1,
                                 "Earlier deletion must not rebuild all visible owner graphs")

        rows.insert(contentsOf: self.rows(1), at: 0)
        update(visibleIndex: 36)
        try await compatibilityWait { controls.fields[editedID]?.value?.placeholderString == "40/100" }
        let moving = rows.remove(at: 40)
        rows.insert(moving, at: 72)
        update(visibleIndex: 68)
        try await compatibilityWait { controls.fields[editedID]?.value?.placeholderString == "72/100" }
        XCTAssertTrue(controls.fields[editedID]?.value === field)
        XCTAssertTrue(owner(of: field, in: view) === host)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Uncommitted native draft")
        XCTAssertTrue(controls.commits.isEmpty, "Topology updates must not silently commit an active edit")
        window.makeFirstResponder(nil)
        try await compatibilityWait { controls.commits.count == 1 }
        XCTAssertEqual(controls.commits.first?.0, editedID)
        XCTAssertEqual(controls.commits.first?.1, "Uncommitted native draft")
    }

    func testActualEditorOwnerStaysAttachedFarAwayButDeletedControlsLeaveImmediately() async throws {
        var rows = rows(100)
        let controls = Controls()
        let view = NativeCachedSidebarBatchesView<EditableRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 4095))
        let window = mount(view)
        defer { window.makeFirstResponder(nil); view.detach(); window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ y: CGFloat) {
            view.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: EnvironmentValues()) { row, index, total in
                EditableRow(id: row.id, index: index, total: total, controls: controls)
            }
            view.reconcile(visible: CGRect(x: 0, y: y, width: 250, height: 300))
            view.layoutSubtreeIfNeeded()
        }
        update(0)
        let editedID = rows[2].id
        try await compatibilityWait { controls.fields[editedID]?.value?.window != nil }
        let field = try XCTUnwrap(controls.fields[editedID]?.value)
        let host = try XCTUnwrap(owner(of: field, in: view))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.string = "Kept away from viewport"
        update(3000)
        XCTAssertTrue(host.superview === view, "The actual native editor protects its original group")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Kept away from viewport")
        rows.removeAll { $0.id == editedID }
        update(3000)
        view.layoutSubtreeIfNeeded()
        try await compatibilityWait { field.window == nil }
        XCTAssertNil(field.window, "A stale keepalive must never retain a deleted or unauthorized native control")
    }

    func testInterleavedOwnerPassesGapHitsToAuthoritativeNativeRow() async throws {
        var rows = rows(100)
        let original = rows
        let controls = Controls()
        let view = NativeCachedSidebarBatchesView<EditableRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 4095))
        let window = mount(view)
        defer { window.makeFirstResponder(nil); view.detach(); window.orderOut(nil); window.contentView = nil; window.close() }
        let pitch = Look.rowHeight + Look.rowGap
        func update() {
            view.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: EnvironmentValues()) { row, index, total in
                EditableRow(id: row.id, index: index, total: total, controls: controls)
            }
            view.reconcile(visible: CGRect(x: 0, y: 36 * pitch, width: 250, height: 300))
            view.layoutSubtreeIfNeeded()
        }
        update()
        let moved = rows.removeFirst()
        rows.insert(moved, at: 80)
        update()
        let targetID = original[40].id
        try await compatibilityWait { controls.fields[targetID]?.value?.window != nil }
        let field = try XCTUnwrap(controls.fields[targetID]?.value)
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: view.superview)
        let hit = try XCTUnwrap(view.hitTest(point))
        XCTAssertTrue(hit === field || hit.isDescendant(of: field),
                      "An overlapping owner's blank slot must never swallow the actual row's native hit")
        XCTAssertEqual(field.placeholderString, "39/100", "Native content must reflect the new authoritative order")
    }

    func testCollapsePreservesOriginalOwnerShellAndDoesNotRetainHiddenControls() async throws {
        let rows = rows(24), controls = Controls()
        let view = NativeCachedSidebarBatchesView<EditableRow>(frame: NSRect(x: 0, y: 0, width: 250, height: 979))
        let window = mount(view)
        defer { view.detach(); window.orderOut(nil); window.contentView = nil; window.close() }
        func update(_ shown: [SidebarRows.Row]) {
            view.configure(rows: shown, modelIDs: Set(rows.map(\.id)), environment: EnvironmentValues()) { row, index, total in
                EditableRow(id: row.id, index: index, total: total, controls: controls)
            }
            view.reconcile(visible: CGRect(x: 0, y: 0, width: 250, height: 300))
            view.layoutSubtreeIfNeeded()
        }
        update(rows)
        try await compatibilityWait { controls.fields[rows[2].id]?.value?.window != nil }
        let field = try XCTUnwrap(controls.fields[rows[2].id]?.value)
        let host = try XCTUnwrap(owner(of: field, in: view))
        let creates = view.batchCounts.coldGraphCreates
        update([])
        try await compatibilityWait { field.window == nil }
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertEqual(view.attachedLogicalRows, 0)
        XCTAssertEqual(view.cachedLogicalRows, 0, "Collapsed rows must not remain logical controls in cached roots")
        update(rows)
        try await compatibilityWait { controls.fields[rows[2].id]?.value?.window != nil }
        let restored = try XCTUnwrap(controls.fields[rows[2].id]?.value)
        XCTAssertTrue(owner(of: restored, in: view) === host)
        XCTAssertEqual(view.batchCounts.coldGraphCreates, creates)
    }

}
