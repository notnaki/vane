import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FolderRolloutControlTests: XCTestCase {
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

    func testNewFolderChildrenRollDownFromTheirHeaderAcrossNativeOwners() async throws {
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

    private func checkRollout(reduceDuringMotion: Bool, detachDuringStart: Bool = false,
                              largeFolder: Bool = false) async throws {
        TestEnvironment.prepare()
        let saver = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(saver) }
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
        print("FOLDER_CONTROL_CONTEXT active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.occlusionState.rawValue) reduced=\(Motion.reduced)")
        configure(shape, animation: nil)
        try await Task.sleep(for: .milliseconds(80))
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
        XCTAssertLessThan(early, destination - 10,
                         "New child owners must start beneath the folder, not appear at their final slots")
        if reduceDuringMotion {
            BatterySaver.shared.setMode(.alwaysOn)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertTrue(markers.views[tabs[11].id.uuidString] === child)
        } else {
            try await Task.sleep(for: .milliseconds(1100))
        }
        XCTAssertEqual(child.convert(child.bounds, to: view).minY, destination, accuracy: 1)
        XCTAssertGreaterThan(view.attachedGraphCount, 1)
        if !reduceDuringMotion {
            configure(shape, animation: .linear(duration: 1))
            try await Task.sleep(for: .milliseconds(1100))
            configure(expanded, animation: .linear(duration: 1))
            try await compatibilityWait { markers.views[tabs[11].id.uuidString]?.window != nil }
            try await Task.sleep(for: .milliseconds(120))
            let reopened = try XCTUnwrap(markers.views[tabs[11].id.uuidString])
            XCTAssertLessThan(reopened.convert(reopened.bounds, to: view).minY, destination - 10,
                              "Cached child-only owners must roll out on subsequent openings too")
            let point = reopened.convert(NSPoint(x: reopened.bounds.midX, y: reopened.bounds.midY), to: view.superview)
            let hit = view.hitTest(point)
            XCTAssertTrue(hit === reopened || hit?.isDescendant(of: reopened) == true,
                          "The moving child must receive clicks at its current position")
            try await Task.sleep(for: .milliseconds(1100))
            configure(shape, animation: .linear(duration: 1))
            try await Task.sleep(for: .milliseconds(20))
            configure(expanded, animation: .linear(duration: 1))
            try await Task.sleep(for: .milliseconds(120))
            let caught = try XCTUnwrap(markers.views[tabs[11].id.uuidString])
            XCTAssertLessThan(caught.convert(caught.bounds, to: view).minY, destination - 10,
                              "A quick reopen must start immediately instead of queueing behind an old animation")
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertEqual(caught.convert(caught.bounds, to: view).minY, destination, accuracy: 1)
        }
    }
}