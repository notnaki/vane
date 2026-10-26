import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Current viewport geometry, rather than a resident buffer's nonempty extent,
/// determines whether an offscreen nonempty section has rows left to commit.
@MainActor final class OffscreenNativeSidebarReadinessTests: XCTestCase {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    func testShortNonemptySectionAboveViewportCompletesWithoutVisibleRowLayouts() {
        _ = NSApplication.shared
        let gate = SidebarNativeReadinessCoordinator.shared
        let scopeOwner = NSObject(), shell = NSObject()
        let populationOwnerID = UUID()
        let scope = SidebarNativeReadinessScope(storeID: ObjectIdentifier(scopeOwner), spaceID: UUID())
        let row = SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Short section"))), depth: 0), tab: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 250, height: 1200))
        let native = NativeCachedSidebarBatchesView<EmptyView>(frame: NSRect(x: 0, y: 0, width: 250, height: Look.rowHeight))
        XCTAssertTrue(native.usesThreeBatchBudget, "Exercise the shipping bounded resident policy")
        var scheduled: [@MainActor () -> Void] = []
        native.geometryScheduler = { scheduled.append($0) }
        document.addSubview(native)
        scroll.documentView = document
        window.contentView = scroll
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = scope
        environment.sidebarNativeReadinessOwnerID = populationOwnerID
        gate.expectPopulation(scope, sections: ["today": [row.id]], populationOwnerID: populationOwnerID)
        gate.retainPopulationExpectation(scope, owner: ObjectIdentifier(shell), populationOwnerID: populationOwnerID)
        defer {
            native.detach()
            gate.releasePopulationExpectation(scope, owner: ObjectIdentifier(shell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        native.configure(rows: [row], modelIDs: [row.id], environment: environment,
                         readinessSection: "today") { _, _, _ in EmptyView() }
        XCTAssertTrue(native.window === window)
        XCTAssertFalse(scheduled.isEmpty, "Native geometry work must be held by the test")
        XCTAssertFalse(gate.isReady(scope), "A nonempty configure alone cannot acknowledge current viewport geometry")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        let visible = native.convert(scroll.contentView.bounds, from: scroll.contentView)
        XCTAssertGreaterThanOrEqual(visible.minY, native.bounds.maxY,
                                   "The actual native clip must lie wholly below this short section")
        XCTAssertFalse(native.bounds.intersects(visible), "No row from this nonempty section is visible")
        XCTAssertFalse(gate.isReady(scope), "Scrolling invalidates geometry before the held reconciliation executes")
        native.reconcile(visible: visible)
        XCTAssertTrue(native.residentRowRange.isEmpty,
                      "This regression exercises the empty resident-range path, not an all-row ready proxy")
        XCTAssertTrue(gate.isReady(scope),
                      "A current attached section with no visible rows must not block the Space handoff")
    }
}
