import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FolderRolloutTests: XCTestCase {
    private final class Markers { var views: [String: NSView] = [:] }
    private struct Marker: NSViewRepresentable {
        let id: String
        let markers: Markers
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemRed.cgColor
            markers.views[id] = view
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    func testFolderChildrenFollowMotionPolicyAcrossNativeOwners() async throws {
        try await checkRollout(reduceDuringMotion: false)
    }

    func testBatterySaverSettlesAnActiveRolloutWithoutReplacingItsControls() async throws {
        try await checkRollout(reduceDuringMotion: true)
    }

    func testDetachedPendingRolloutReturnsFullyVisible() async throws {
        try await checkRollout(reduceDuringMotion: false, detachDuringStart: true)
    }

    func testLargeFolderRolloutRevealsVisibleRowsWithoutTravellingItsEntireDocument() async throws {
        try await checkRollout(reduceDuringMotion: false, largeFolder: true)
    }

    func testBatterySaverKeepsDisclosureImmediate() async throws {
        try await checkRollout(reduceDuringMotion: false, startWithSaver: true)
    }

    func testBatterySaverFinishesAnActiveFolderClosing() async throws {
        try await checkRollout(reduceDuringMotion: false, reduceDuringClose: true)
    }

    func testUnrelatedRefreshPreservesTheClosingStrip() async throws {
        try await checkRollout(reduceDuringMotion: false, refreshDuringClose: true)
    }

    private func checkRollout(reduceDuringMotion: Bool, detachDuringStart: Bool = false,
                              largeFolder: Bool = false, startWithSaver: Bool = false,
                              reduceDuringClose: Bool = false, refreshDuringClose: Bool = false) async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared.mode
        BatterySaver.shared.setMode(startWithSaver ? .alwaysOn : .off)
        defer { BatterySaver.shared.setMode(saver) }
        let reduced = Motion.reduced || EnvironmentValues().accessibilityReduceMotion
        print("FOLDER_ROLLOUT_POLICY reduced=\(reduced) system=\(Motion.spaceReduced) saver=\(BatterySaver.shared.isActive)")
        let markers = Markers()
        let folder = Folder(name: "Rollout", collapsed: true)
        let childCount = largeFolder ? 300 : 12
        let tabs = (0..<(childCount + 12)).map { _ in Tab(isPrivate: true) }
        let shape = Pins(entries: [.init(row: .folder(folder))] + tabs.enumerated().map {
            .init(row: .tab($0.element.id.uuidString), parent: $0.offset < childCount ? folder.id : nil)
        })
        let modelIDs = Set(shape.entries.map(\.id))
        let view = NativeCachedSidebarBatchesView<Marker>(frame: NSRect(x: 0, y: 0, width: 250, height: 750))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { view.detach(); window.contentView = nil; window.close(); SharedTabs.release(tabs) }
        func configure(_ shape: Pins, animation: Animation?) {
            let rows = SidebarRows(tabs: tabs, splits: [], shape: shape).rows
            view.configure(rows: rows, modelIDs: modelIDs, environment: EnvironmentValues(),
                           transaction: Transaction(animation: animation)) { row, _, _ in
                Marker(id: row.id, markers: markers)
            }
            view.reconcile(visible: view.bounds)
            view.layoutSubtreeIfNeeded()
        }
        configure(shape, animation: nil)
        // Admit the collapsed layout's current owners before expansion. Waiting
        // for the expanded destination here would erase the early-motion sample.
        let initialRows = SidebarRows(tabs: tabs, splits: [], shape: shape).rows
        func rowAnchors(in root: NSView) -> [NativeSidebarRowLayoutView] {
            ((root as? NativeSidebarRowLayoutView).map { [$0] } ?? []) + root.subviews.flatMap { rowAnchors(in: $0) }
        }
        try await compatibilityWait {
            let anchors = rowAnchors(in: view)
            return view.window === window && window.isVisible && initialRows.allSatisfy { row in
                guard let marker = markers.views[row.id], marker.window === window,
                      let anchor = anchors.first(where: { $0.rowID == row.id && $0.window === window }) else { return false }
                return anchor.committedGeneration == anchor.generation && anchor.hasCommittedCurrentBounds
                    && anchor.bounds.width > 0 && anchor.bounds.height > 0
            }
        }
        var expanded = shape
        expanded.toggle(folder: folder.id)
        configure(expanded, animation: .linear(duration: 1))
        if largeFolder {
            try await compatibilityWait { markers.views[tabs[0].id.uuidString]?.window != nil }
            try await Task.sleep(for: .milliseconds(250))
            let revealed = tabs.prefix(16).compactMap { markers.views[$0.id.uuidString] }.filter {
                $0.convert($0.bounds, to: view).intersects(CGRect(x: 0, y: 41, width: 250, height: 709))
            }
            XCTAssertFalse(revealed.isEmpty,
                           "A large folder must reveal its visible rows without rolling through 300 offscreen slots")
            return
        }
        if detachDuringStart {
            window.contentView = nil
            try await Task.sleep(for: .milliseconds(100))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            let returned = try XCTUnwrap(markers.views[tabs[11].id.uuidString])
            XCTAssertEqual(returned.convert(returned.bounds, to: view).minY,
                           12 * (Look.rowHeight + Look.rowGap), accuracy: 1,
                           "An interrupted startup must return as settled content, not stay folded")
            return
        }
        try await compatibilityWait { markers.views[tabs[11].id.uuidString]?.window != nil }
        try await Task.sleep(for: .milliseconds(120))
        let child = try XCTUnwrap(markers.views[tabs[11].id.uuidString])
        let early = child.convert(child.bounds, to: view).minY
        let destination = 12 * (Look.rowHeight + Look.rowGap)
        let firstChild = try XCTUnwrap(markers.views[tabs[0].id.uuidString])
        XCTAssertEqual(early - firstChild.convert(firstChild.bounds, to: view).minY,
                       11 * (Look.rowHeight + Look.rowGap), accuracy: 1,
                       "Rolling children must keep their full row spacing instead of compressing into a pile")
        let header = try XCTUnwrap(markers.views[folder.id.uuidString])
        let headerPoint = header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: view.superview)
        let headerHit = view.hitTest(headerPoint)
        XCTAssertTrue(headerHit === header || headerHit?.isDescendant(of: header) == true,
                      "Masked children must leave the header clickable during rollout")
        if reduced {
            XCTAssertEqual(early, destination, accuracy: 1, "Reduced motion must expose children immediately")
        } else {
            XCTAssertLessThan(early, destination - 10,
                             "New child owners must start beneath the folder, not appear at their final slots")
        }
        if reduceDuringMotion {
            BatterySaver.shared.setMode(.alwaysOn)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertTrue(markers.views[tabs[11].id.uuidString] === child)
        } else {
            try await Task.sleep(for: reduced ? .milliseconds(40) : .milliseconds(1100))
        }
        XCTAssertEqual(child.convert(child.bounds, to: view).minY, destination, accuracy: 1)
        XCTAssertGreaterThan(view.attachedGraphCount, 1)
        if !reduceDuringMotion {
            // All visible owners and the destination pose are admitted above.
            // Sample immediately after closing; waiting for hidden children would
            // make this regression incapable of catching an instant disappearance.
            configure(shape, animation: .linear(duration: 1))
            try await Task.sleep(for: .milliseconds(120))
            if !reduced {
                XCTAssertTrue(child.window === window, "Closing children must remain visible while folding under their header")
                let closingY = child.convert(child.bounds, to: view).minY
                XCTAssertLessThan(closingY, destination - 10, "Closing must slide the strip upward")
                XCTAssertGreaterThan(closingY, destination - 12 * (Look.rowHeight + Look.rowGap) + 10,
                                     "Closing must not jump straight to its folded pose")
                XCTAssertEqual(closingY - firstChild.convert(firstChild.bounds, to: view).minY,
                               11 * (Look.rowHeight + Look.rowGap), accuracy: 1,
                               "Closing rows must retain their spacing across native owners")
                let point = child.convert(NSPoint(x: child.bounds.midX, y: child.bounds.midY), to: view.superview)
                let hit = view.hitTest(point)
                XCTAssertFalse(hit === child || hit?.isDescendant(of: child) == true,
                               "Closing rows must stop accepting clicks immediately")
            }
            if reduceDuringClose {
                BatterySaver.shared.setMode(.alwaysOn)
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertNil(child.window, "Battery Saver must finish an active closing immediately")
                return
            }
            if refreshDuringClose {
                configure(shape, animation: nil)
                try await Task.sleep(for: .milliseconds(120))
                if !reduced {
                    XCTAssertTrue(child.window === window, "An unrelated refresh must not remove a closing strip early")
                    XCTAssertGreaterThan(child.convert(child.bounds, to: view).minY, 10)
                }
            }
            try await Task.sleep(for: reduced ? .milliseconds(40) : .milliseconds(1100))
            XCTAssertNil(child.window, "Closing must release its visual rows after the animation")
            configure(expanded, animation: .linear(duration: 1))
            try await compatibilityWait { markers.views[tabs[11].id.uuidString]?.window != nil }
            try await Task.sleep(for: .milliseconds(120))
            let reopened = try XCTUnwrap(markers.views[tabs[11].id.uuidString])
            if reduced {
                XCTAssertEqual(reopened.convert(reopened.bounds, to: view).minY, destination, accuracy: 1)
            } else {
                XCTAssertLessThan(reopened.convert(reopened.bounds, to: view).minY, destination - 10,
                                  "Cached child-only owners must roll out on subsequent openings too")
            }
            let point = reopened.convert(NSPoint(x: reopened.bounds.midX, y: reopened.bounds.midY), to: view.superview)
            let hit = view.hitTest(point)
            XCTAssertTrue(hit === reopened || hit?.isDescendant(of: reopened) == true,
                          "The moving child must receive clicks at its current position")
            try await Task.sleep(for: reduced ? .milliseconds(40) : .milliseconds(1100))
            configure(shape, animation: .linear(duration: 1))
            try await Task.sleep(for: .milliseconds(20))
            configure(expanded, animation: .linear(duration: 1))
            try await Task.sleep(for: .milliseconds(120))
            let caught = try XCTUnwrap(markers.views[tabs[11].id.uuidString])
            if reduced {
                XCTAssertEqual(caught.convert(caught.bounds, to: view).minY, destination, accuracy: 1)
            } else {
                XCTAssertLessThan(caught.convert(caught.bounds, to: view).minY, destination - 10,
                                  "A quick reopen must start immediately instead of queueing behind an old animation")
            }
            try await Task.sleep(for: reduced ? .milliseconds(40) : .milliseconds(1100))
            XCTAssertEqual(caught.convert(caught.bounds, to: view).minY, destination, accuracy: 1)
        }
    }
}
