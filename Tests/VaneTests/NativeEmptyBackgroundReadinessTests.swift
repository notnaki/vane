import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class NativeEmptyBackgroundReadinessTests: XCTestCase {
    /// Reproduce the NewTabRow background's real native shape: an attached empty
    /// owner with zero width/height. No layout() call or population task is allowed
    /// to rescue readiness after attachment or a geometry-revision nonce refresh.
    func testAttachedZeroSizeEmptyBackgroundCompletesEachCurrentReadinessTicketWithoutLayout() {
        _ = NSApplication.shared
        let identity = NSObject(), shell = NSObject()
        let scope = SidebarNativeReadinessScope(storeID: ObjectIdentifier(identity), spaceID: UUID())
        let ownerID = UUID()
        let gate = SidebarNativeReadinessCoordinator.shared
        let sections: [String: [String]] = ["pinned": []]
        gate.expectPopulation(scope, sections: sections, populationOwnerID: ownerID)
        gate.retainPopulationExpectation(scope, owner: ObjectIdentifier(shell),
            sections: sections, populationOwnerID: ownerID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        let newTabRow = NSView(frame: NSRect(x: 0, y: 26, width: 250, height: Look.rowHeight))
        scroll.documentView = document
        document.addSubview(newTabRow)
        window.contentView = scroll
        let native = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        native.geometryScheduler = { _ in } // A zero-size row must not need deferred population.
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = scope
        environment.sidebarNativeReadinessOwnerID = ownerID
        defer {
            native.detach()
            gate.releasePopulationExpectation(scope, owner: ObjectIdentifier(shell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        native.configure(rows: [], modelIDs: [], environment: environment,
                         readinessSection: "pinned") { _, _, _ in EmptyView() }
        XCTAssertNil(native.window)
        XCTAssertFalse(gate.isReady(scope), "A configured but detached owner cannot acknowledge native readiness")
        newTabRow.addSubview(native)
        XCTAssertTrue(native.window === window)
        XCTAssertTrue(native.bounds.isEmpty)
        XCTAssertTrue(gate.isReady(scope), "Current attached empty background must complete after attachment/clip registration")
        native.setFrameOrigin(NSPoint(x: 1, y: 0))
        XCTAssertTrue(native.bounds.isEmpty)
        XCTAssertTrue(gate.isReady(scope), "A new geometry nonce must not strand an empty owner that receives no layout")
        native.removeFromSuperview()
        XCTAssertFalse(gate.isReady(scope), "Detaching removes authority even for an empty section")
        native.setFrameOrigin(NSPoint(x: 2, y: 0))
        XCTAssertFalse(gate.isReady(scope), "A passive detached callback cannot revive empty population")
    }
}
