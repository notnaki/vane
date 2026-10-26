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
