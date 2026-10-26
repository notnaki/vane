import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Exercise the actual owner cache: skipping a detached root must save work,
/// without letting a stale root reach a window or retain revoked membership.
@MainActor final class NativeSidebarHostReuseTests: XCTestCase {
    private final class Controls {
        var fields: [String: NSTextField] = [:]
        var tabs: [String: ObjectIdentifier] = [:]
    }
    private struct RowControl: View {
        let row: SidebarRows.Row
        let index: Int
        let total: Int
        let revision: String
        let controls: Controls
        var body: some View {
            NativeField(row: row, index: index, total: total, revision: revision, controls: controls)
                .disabled(row.visible.entry.folder?.requiresAuthentication ?? false)
        }
    }
    private struct NativeField: NSViewRepresentable {
        let row: SidebarRows.Row
        let index: Int
        let total: Int
        let revision: String
        let controls: Controls
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField(string: "Unedited")
            controls.fields[row.id] = field
            return field
        }
        func updateNSView(_ view: NSTextField, context: Context) {
            view.placeholderString = "\(revision):\(index)/\(total):\(colorScheme == .dark ? "dark" : "light")"
            view.isEnabled = isEnabled
            if let tab = row.tab { controls.tabs[row.id] = ObjectIdentifier(tab) }
        }
    }
    private func rows(_ count: Int = 160) -> [SidebarRows.Row] {
        (0..<count).map { index in
            SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Row \(index)"))), depth: 0), tab: nil)
        }
    }
    @MainActor private final class Fixture {
        var rows: [SidebarRows.Row]
        var modelIDs: Set<String>
        var environment = EnvironmentValues()
        var revision = "first"
        let controls = Controls()
        let owner: NativeCachedSidebarBatchesView<RowControl>
        let scroll: NSScrollView
        let window: NSWindow
        let pitch = Look.rowHeight + Look.rowGap
        init(rows: [SidebarRows.Row], reuse: Bool = true) {
            _ = NSApplication.shared
            self.rows = rows
            modelIDs = Set(rows.map(\.id))
            owner = NativeCachedSidebarBatchesView(frame: NSRect(x: 0, y: 0, width: 250,
                height: CGFloat(rows.count) * (Look.rowHeight + Look.rowGap) - Look.rowGap),
                defersDetachedRootUpdates: reuse)
            // Keep population deterministic while still using real native layout.
            owner.geometryScheduler = { _ in }
            scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
            scroll.documentView = owner
            window = NSWindow(contentRect: scroll.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            environment.colorScheme = .light
            configure()
            visit(0)
        }
        func configure(protectedRows: Set<String> = []) {
            let revision = revision
            owner.configure(rows: rows, modelIDs: modelIDs, environment: environment,
                protectedRows: protectedRows) { [controls] row, index, total in
                RowControl(row: row, index: index, total: total, revision: revision, controls: controls)
            }
        }
        func visit(_ index: Int) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index) * pitch))
            scroll.reflectScrolledClipView(scroll.contentView)
            owner.reconcile(visible: owner.convert(scroll.contentView.bounds, from: scroll.contentView))
            owner.layoutSubtreeIfNeeded()
        }
        func close() {
            window.makeFirstResponder(nil)
            owner.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        func warmDetachedMiddle() async throws -> NSTextField {
            visit(48)
            let id = rows[48].id
            try await compatibilityWait { self.controls.fields[id]?.window === self.window }
            let field = try XCTUnwrap(controls.fields[id])
            visit(120)
            try await compatibilityWait { field.window == nil }
            XCTAssertGreaterThan(owner.cachedGraphCount, owner.attachedGraphCount)
            return field
        }
    }

    // Fails if configure continues to replace every detached root, or if a
    // deferred root reattaches with an old caller closure/environment/generation.
    func testContentOnlyUpdatesTouchMountedRootsAndLatestContentArrivesOnWarmReattachment() async throws {
        let fixture = Fixture(rows: rows())
        defer { fixture.close() }
        let field = try await fixture.warmDetachedMiddle()
        let id = fixture.rows[48].id
        let warmReattachments = fixture.owner.batchCounts.warmGraphReattachments
        for revision in ["second", "latest"] {
            fixture.revision = revision
            fixture.environment.colorScheme = .dark
            let before = fixture.owner.batchCounts.rootUpdates
            let mounted = fixture.owner.attachedGraphCount
            fixture.configure()
            XCTAssertEqual(fixture.owner.batchCounts.rootUpdates - before, mounted,
                "Unchanged detached owners should receive no content-only root assignment")
        }
        XCTAssertFalse(fixture.owner.nativeRowsInAuthoritativeOrder().contains { $0.0 == id },
            "A detached anchor from an older generation cannot satisfy native readiness")
        fixture.visit(48)
        try await compatibilityWait { field.window === fixture.window && field.placeholderString == "latest:48/160:dark" }
        XCTAssertTrue(fixture.controls.fields[id] === field, "Warm reattachment preserves native control identity")
        XCTAssertGreaterThan(fixture.owner.batchCounts.warmGraphReattachments, warmReattachments)
        try await compatibilityWait { fixture.owner.nativeRowsInAuthoritativeOrder().contains { $0.0 == id } }
    }

    func testOptOutKeepsRefreshingEveryCachedRoot() async throws {
        let fixture = Fixture(rows: rows(), reuse: false)
        defer { fixture.close() }
        _ = try await fixture.warmDetachedMiddle()
        let before = fixture.owner.batchCounts.rootUpdates
        let cached = fixture.owner.cachedGraphCount
        fixture.revision = "next"
        fixture.configure()
        XCTAssertEqual(fixture.owner.batchCounts.rootUpdates - before, cached)
    }

    // A visible host must never deduplicate using a partial content whitelist.
    func testMountedRootReceivesArbitraryCallerClosureAndEnvironmentChanges() async throws {
        let fixture = Fixture(rows: rows())
        defer { fixture.close() }
        let id = fixture.rows[2].id
        try await compatibilityWait { fixture.controls.fields[id]?.window === fixture.window }
        let field = try XCTUnwrap(fixture.controls.fields[id])
        fixture.revision = "caller-changed"
        fixture.environment.colorScheme = .dark
        fixture.configure()
        fixture.owner.layoutSubtreeIfNeeded()
        try await compatibilityWait { field.placeholderString == "caller-changed:2/160:dark" }
    }

    // The protected child remains in structural modelIDs when a folder locks;
    // visibility filtering alone must still clear its detached root immediately.
    func testRevokedDetachedMembershipIsSanitizedDespiteStaleKeepalive() async throws {
        let fixture = Fixture(rows: rows())
        defer { fixture.close() }
        let field = try await fixture.warmDetachedMiddle()
        let id = fixture.rows[48].id
        let token = UUID()
        fixture.owner.setInteraction(true, row: id, token: token)
        fixture.rows.remove(at: 48)
        let before = fixture.owner.batchCounts.rootUpdates
        let mounted = fixture.owner.attachedGraphCount
        fixture.configure(protectedRows: [id])
        XCTAssertFalse(fixture.owner.protectedRows.contains(id))
        XCTAssertGreaterThan(fixture.owner.batchCounts.rootUpdates - before, mounted,
            "Membership removal must refresh detached roots on the configure turn")
        XCTAssertNil(field.window)
        fixture.owner.setAccessibilityRowsExpanded()
        fixture.owner.layoutSubtreeIfNeeded()
        try await compatibilityWait { !fixture.owner.nativeRowsInAuthoritativeOrder().isEmpty }
        XCTAssertFalse(fixture.owner.nativeRowsInAuthoritativeOrder().contains { $0.0 == id })
        XCTAssertEqual(fixture.owner.cachedLogicalRows, 159)
    }

    func testDetachedFolderPermissionAndPlacementChangesRefreshImmediately() async throws {
        let fixture = Fixture(rows: rows())
        defer { fixture.close() }
        let field = try await fixture.warmDetachedMiddle()
        var folder = try XCTUnwrap(fixture.rows[48].visible.entry.folder)
        folder.requiresAuthentication = true
        fixture.rows[48] = SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(folder)), depth: 1), tab: nil)
        let before = fixture.owner.batchCounts.rootUpdates
        let mounted = fixture.owner.attachedGraphCount
        fixture.configure()
        XCTAssertGreaterThan(fixture.owner.batchCounts.rootUpdates - before, mounted,
            "Same row ID does not make a changed permission/shape snapshot safe to defer")
        fixture.visit(48)
        try await compatibilityWait { field.window === fixture.window && !field.isEnabled }
        fixture.visit(120)
        let moving = fixture.rows.remove(at: 48)
        fixture.rows.insert(moving, at: 64)
        let beforeReorder = fixture.owner.batchCounts.rootUpdates
        let mountedBeforeReorder = fixture.owner.attachedGraphCount
        fixture.configure()
        XCTAssertGreaterThan(fixture.owner.batchCounts.rootUpdates - beforeReorder, mountedBeforeReorder,
            "Detached roots must absorb structural placements without replaying old motion")
        fixture.visit(64)
        try await compatibilityWait { field.window === fixture.window && field.placeholderString == "first:64/160:light" }
        try await compatibilityWait { fixture.owner.nativeRowsInAuthoritativeOrder().contains { $0.0 == moving.id } }
        let anchor = try XCTUnwrap(fixture.owner.nativeRowsInAuthoritativeOrder().first { $0.0 == moving.id }?.1)
        XCTAssertEqual(anchor.convert(anchor.bounds, to: fixture.owner).minY, 64 * fixture.pitch, accuracy: 1)
    }

    func testDeletingAllMembersEvictsTheDetachedOwnerImmediately() async throws {
        let fixture = Fixture(rows: rows())
        defer { fixture.close() }
        let field = try await fixture.warmDetachedMiddle()
        let deletedIDs = Set(fixture.rows[48..<56].map(\.id))
        let evictions = fixture.owner.batchCounts.graphEvictions
        fixture.rows.removeSubrange(48..<56)
        fixture.modelIDs.subtract(deletedIDs)
        fixture.configure(protectedRows: deletedIDs)
        XCTAssertEqual(fixture.owner.batchCounts.graphEvictions - evictions, 1)
        XCTAssertTrue(fixture.owner.protectedRows.isDisjoint(with: deletedIDs))
        XCTAssertNil(field.window)
        fixture.owner.setAccessibilityRowsExpanded()
        fixture.owner.layoutSubtreeIfNeeded()
        try await compatibilityWait { !fixture.owner.nativeRowsInAuthoritativeOrder().isEmpty }
        XCTAssertTrue(Set(fixture.owner.nativeRowsInAuthoritativeOrder().map(\.0)).isDisjoint(with: deletedIDs))
    }

    func testSameUUIDReplacementTabRefreshesDetachedRootUsingObjectIdentity() async throws {
        var source = rows()
        let tab = Tab(profileID: UUID())
        source[48] = SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .tab(tab.id.uuidString)), depth: 0), tab: tab)
        let fixture = Fixture(rows: source)
        defer { fixture.close() }
        _ = try await fixture.warmDetachedMiddle()
        let replacement = Tab(id: tab.id, profileID: UUID())
        fixture.rows[48] = SidebarRows.Row(visible: source[48].visible, tab: replacement)
        let before = fixture.owner.batchCounts.rootUpdates
        let mounted = fixture.owner.attachedGraphCount
        fixture.configure()
        XCTAssertGreaterThan(fixture.owner.batchCounts.rootUpdates - before, mounted,
            "Equal UUIDs cannot preserve a detached root bound to the old Tab object")
        fixture.visit(48)
        try await compatibilityWait { fixture.controls.tabs[tab.id.uuidString] == ObjectIdentifier(replacement) }
        XCTAssertNil(tab.existingWeb)
        XCTAssertNil(replacement.existingWeb)
    }

    func testNativeEditorAndPresentationKeepaliveStayCurrentOutsideViewport() async throws {
        let fixture = Fixture(rows: rows())
        defer { fixture.close() }
        fixture.visit(48)
        let id = fixture.rows[48].id
        try await compatibilityWait { fixture.controls.fields[id]?.window === fixture.window }
        let field = try XCTUnwrap(fixture.controls.fields[id])
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        editor.string = "Uncommitted draft"
        fixture.visit(120)
        fixture.revision = "editing"
        fixture.configure()
        fixture.owner.layoutSubtreeIfNeeded()
        try await compatibilityWait { field.placeholderString == "editing:48/160:light" }
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Uncommitted draft")
        fixture.window.makeFirstResponder(nil)
        let token = UUID()
        fixture.owner.setInteraction(true, row: id, token: token)
        fixture.visit(120)
        fixture.revision = "presentation"
        fixture.configure()
        fixture.owner.layoutSubtreeIfNeeded()
        try await compatibilityWait { field.window === fixture.window && field.placeholderString == "presentation:48/160:light" }
        fixture.owner.setInteraction(false, row: id, token: token)
        fixture.visit(120)
        try await compatibilityWait { field.window == nil }
    }
}
