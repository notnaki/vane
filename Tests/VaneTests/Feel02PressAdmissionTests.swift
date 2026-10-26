import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel02PressAdmissionTests: XCTestCase {
    private func event(_ type: NSEvent.EventType = .mouseMoved, at point: CGPoint,
                       in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func scroll(in root: NSView, x: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: x, y: 0, width: 200, height: 160))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        root.addSubview(scroll)
        return scroll
    }
    private func window() -> NSWindow {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return window
    }

    func testPointerCandidatesExcludeDetachedCacheOtherContainersAndOtherWindows() throws {
        let window = window(), root = try XCTUnwrap(window.contentView)
        let left = scroll(in: root, x: 0), right = scroll(in: root, x: 280)
        let document = try XCTUnwrap(left.documentView)
        let anchor = Feel02PressAnchorView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        document.addSubview(anchor)
        let monitor = Feel02PressMonitor()
        monitor.recordsCandidateVisits = true
        var hovered = false
        anchor.hoverChanged = { hovered = $0 }
        monitor.register(anchor)
        // Warm native owners can retain their detached row trees. Those anchors
        // must contribute no candidate work, even though they remain registered.
        let detached = (0..<1000).map { _ in Feel02PressAnchorView(frame: anchor.frame) }
        for item in detached { item.hoverChanged = { _ in }; monitor.register(item) }
        let unrelated = (0..<1000).map { _ in Feel02PressAnchorView(frame: anchor.frame) }
        for item in unrelated {
            right.documentView?.addSubview(item)
            item.hoverChanged = { _ in }; monitor.register(item)
        }
        let otherWindow = self.window()
        let foreign = Feel02PressAnchorView(frame: anchor.frame)
        otherWindow.contentView?.addSubview(foreign)
        foreign.hoverChanged = { _ in }; monitor.register(foreign)
        defer {
            for item in detached + unrelated + [foreign, anchor] { monitor.remove(item) }
        }
        let inside = anchor.convert(NSPoint(x: 10, y: 10), to: nil)
        _ = monitor.handle(try event(at: NSPoint(x: -100, y: -100), in: window))
        let move = try event(at: inside, in: window)
        XCTAssertTrue(monitor.handle(move) === move)
        XCTAssertTrue(hovered)
        XCTAssertEqual(monitor.candidateVisits, 1,
                       "Only containers on the actual native hit ancestry may supply candidates")
        _ = monitor.handle(try event(at: NSPoint(x: 550, y: 100), in: window))
        XCTAssertFalse(hovered)
        XCTAssertEqual(monitor.candidateVisits, 1, "Pointer motion outside the containers must inspect zero anchors")
        anchor.removeFromSuperview()
        _ = monitor.handle(try event(at: inside, in: window))
        XCTAssertFalse(hovered)
        XCTAssertEqual(monitor.candidateVisits, 1, "Detachment must remove native admission immediately")
        document.addSubview(anchor)
        _ = monitor.handle(try event(at: NSPoint(x: inside.x + 1, y: inside.y), in: window))
        XCTAssertTrue(hovered, "Reattachment must restore the original anchor's membership")
        XCTAssertEqual(monitor.candidateVisits, 2)
    }

    func testFrontNativeOverlayAndClippingDoNotAdmitUnderlyingRows() throws {
        let window = window(), root = try XCTUnwrap(window.contentView)
        let scroll = scroll(in: root, x: 0)
        let anchor = Feel02PressAnchorView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        scroll.documentView?.addSubview(anchor)
        let monitor = Feel02PressMonitor()
        var hovered = false, pressed = false
        anchor.hoverChanged = { hovered = $0 }; anchor.changed = { pressed = $0 }
        monitor.register(anchor)
        defer { monitor.remove(anchor) }
        let point = anchor.convert(NSPoint(x: 10, y: 10), to: nil)
        _ = monitor.handle(try event(at: NSPoint(x: -100, y: -100), in: window))
        _ = monitor.handle(try event(at: point, in: window))
        XCTAssertTrue(hovered)
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        root.addSubview(overlay, positioned: .above, relativeTo: scroll)
        let covered = NSPoint(x: point.x + 1, y: point.y)
        _ = monitor.handle(try event(at: covered, in: window))
        XCTAssertFalse(hovered, "A front native overlay must own its actual hit route")
        let down = try event(.leftMouseDown, at: covered, in: window)
        XCTAssertTrue(monitor.handle(down) === down)
        XCTAssertFalse(pressed, "Feedback admission must not paint a covered row")
        overlay.removeFromSuperview()
        _ = monitor.handle(try event(at: covered, in: window))
        XCTAssertFalse(hovered, "Removing a cover must not turn a stationary replay into new hover")
        _ = monitor.handle(try event(at: NSPoint(x: covered.x + 1, y: covered.y), in: window))
        XCTAssertTrue(hovered)
        let clipped = anchor.convert(NSPoint(x: 250, y: 10), to: nil)
        _ = monitor.handle(try event(at: clipped, in: window))
        XCTAssertFalse(hovered, "The anchor's extended bounds must not bypass its scroll container's clip")
    }

    func testNestedNativeContainerWithoutTargetsKeepsAncestorControlEligible() throws {
        let window = window(), root = try XCTUnwrap(window.contentView)
        let anchor = Feel02PressAnchorView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        root.addSubview(anchor)
        let nested = scroll(in: root, x: 0)
        let monitor = Feel02PressMonitor()
        var hovered = false
        anchor.hoverChanged = { hovered = $0 }; monitor.register(anchor)
        defer { monitor.remove(anchor) }
        let point = nested.convert(NSPoint(x: 20, y: 20), to: nil)
        _ = monitor.handle(try event(at: NSPoint(x: -100, y: -100), in: window))
        _ = monitor.handle(try event(at: point, in: window))
        XCTAssertTrue(hovered, "A native scroll child with no feedback bucket must not discard its ancestor control")
    }

    private final class Model {
        var hovered: [String: Bool] = [:]
    }
    private struct NativeChild: NSViewRepresentable {
        let label: String
        func makeNSView(context: Context) -> NSButton { NSButton(title: label, target: nil, action: nil) }
        func updateNSView(_ view: NSButton, context: Context) {}
    }
    private struct HostedRows: View {
        let rows: [SidebarRows.Row]
        let model: Model
        var body: some View {
            ScrollView {
                NativeCachedSidebarBatchSectionRows(rows: rows, modelIDs: Set(rows.map(\.id))) { row, index, _ in
                    HStack {
                        Text("Row \(index)").frame(maxWidth: .infinity)
                        NativeChild(label: "Child \(index)").frame(width: 70, height: Look.rowHeight)
                            .modifier(Feel02PressFeedback(hoverChanged: { model.hovered["child-\(index)"] = $0 }))
                    }
                    .frame(height: Look.rowHeight)
                    .modifier(Feel02PressFeedback(hoverChanged: { model.hovered["row-\(index)"] = $0 }))
                }
            }
        }
    }
    private func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
    }
    func testRealHostedRowsAdmitNativeChildAndKeepSmallestTargetArbitration() async throws {
        let window = window(), model = Model()
        window.setContentSize(NSSize(width: 260, height: 220))
        let rows = (0..<100).map { index in
            SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Hover \(index)"))), depth: 0), tab: nil)
        }
        let host = NSHostingView(rootView: HostedRows(rows: rows, model: model))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait {
            self.descendants(host, NSButton.self).contains { $0.title == "Child 0" && $0.window === window }
        }
        let child = try XCTUnwrap(descendants(host, NSButton.self).first { $0.title == "Child 0" })
        let childPoint = child.convert(NSPoint(x: child.bounds.midX, y: child.bounds.midY), to: nil)
        _ = Feel02PressMonitor.shared.handle(try event(at: NSPoint(x: -100, y: -100), in: window))
        _ = Feel02PressMonitor.shared.handle(try event(at: childPoint, in: window))
        XCTAssertEqual(model.hovered["child-0"], true)
        XCTAssertNotEqual(model.hovered["row-0"], true,
                          "A native child hit must retain the smaller target's arbitration within the real row host")
        let rowPoint = child.convert(NSPoint(x: -80, y: child.bounds.midY), to: nil)
        _ = Feel02PressMonitor.shared.handle(try event(at: rowPoint, in: window))
        XCTAssertEqual(model.hovered["row-0"], true)
        XCTAssertEqual(model.hovered["child-0"], false)
    }
}
