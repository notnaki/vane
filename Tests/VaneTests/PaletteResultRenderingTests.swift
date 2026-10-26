import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor private final class PaletteResultFixture: ObservableObject {
    @Published var selected = false
    @Published var enabled = true
    @Published var surfaceEnabled = true
    @Published var title = "First history result"
    var parentDraws = 0
    var forgotten = 0
    var activated = 0
}

private struct PaletteResultFixtureView: View {
    @ObservedObject var fixture: PaletteResultFixture
    let cache: Favicons

    var body: some View {
        fixture.parentDraws += 1
        return VStack(spacing: 0) {
            CommandField(text: .constant("query"), prompt: "Search", selectAll: false,
                         label: "Search", hint: "", onKey: { key in
                switch key {
                case .down: fixture.selected = true; return true
                case .enter: fixture.activated += 1; return true
                default: return false
                }
            })
            .frame(height: 40)
            PaletteResultRow(row: PaletteRow(id: "history", icon: "clock", title: fixture.title,
                forget: "https://example.test/history", kind: "History", run: { _ in }),
                index: 0, rowCount: 1, selected: fixture.selected,
                selectionColor: .blue, favicons: cache, animations: false,
                activate: { fixture.activated += 1 }, forget: { fixture.forgotten += 1 })
                .disabled(!fixture.enabled)
                .environment(\.feel02PressFeedbackEnabled, fixture.surfaceEnabled)
        }
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class PaletteResultRenderingTests: XCTestCase {
    func testHoverStaysInResultSlotWhileKeyboardSelectionAndForgetRemainLive() async throws {
        try await exerciseResult(nativeHover: false)
    }

    func testNativeHoverKeepsForgetKeyboardAndSlotReuseWhileScrollClearsPointerFeedback() async throws {
        try await exerciseResult(nativeHover: true)
    }

    func testNativeHoverClearsWhileActualPaletteResultsScroll() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previous = PaletteNativeHoverExperiment.enabled
        PaletteNativeHoverExperiment.enabled = true
        defer { PaletteNativeHoverExperiment.enabled = previous }
        let cache = Favicons(profileID: UUID())
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack(spacing: Look.barRowGap) {
                ForEach(0..<20, id: \.self) { index in
                    PaletteResultRow(row: PaletteRow(id: "history-\(index)", icon: "clock", title: "History result",
                        forget: "https://example.test/history-\(index)", kind: "History", run: { _ in }),
                        index: index, rowCount: 20, selected: false, selectionColor: .blue,
                        favicons: cache, animations: false, activate: {}, forget: {})
                }
            }
        }.scrollIndicators(.never).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        try await compatibilityWait { !descendants(host, Feel02PressAnchorView.self).isEmpty }
        let scroll = try XCTUnwrap(descendants(host, NSScrollView.self).first)
        let point = scroll.convert(NSPoint(x: 100, y: 80), to: nil)
        func anchorAtPointer() throws -> Feel02PressAnchorView {
            try XCTUnwrap(descendants(host, Feel02PressAnchorView.self).first {
                let local = $0.convert(point, from: nil)
                return $0.bounds.contains(local) && $0.visibleRect.contains(local)
            })
        }
        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func movePointer(_ x: CGFloat) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
                location: NSPoint(x: point.x + x, y: point.y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            _ = try XCTUnwrap(anchorAtPointer().pressMonitor).handle(event)
        }
        try movePointer(0)
        let initial = scroll.contentView.bounds.minY
        NSApp.sendEvent(ScrollEvent(window: window, phase: .began, x: point.x, y: point.y))
        for _ in 0..<12 {
            NSApp.sendEvent(ScrollEvent(window: window, dy: -3, x: point.x, y: point.y))
            try await Task.sleep(for: .milliseconds(8))
        }
        NSApp.sendEvent(ScrollEvent(window: window, phase: .ended, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY - initial, 20,
                             "The production result ScrollView must actually move")
        let afterScroll = try pixels()
        try movePointer(1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotEqual(try pixels(), afterScroll, "Real movement must light the newly visible result")
        NSApp.sendEvent(ScrollEvent(window: window, dy: 0, x: point.x, y: point.y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try pixels(), afterScroll, "Native scrolling must clear the result under a stationary pointer")
    }

    private func exerciseResult(nativeHover: Bool) async throws {
        let previous = PaletteNativeHoverExperiment.enabled
        PaletteNativeHoverExperiment.enabled = nativeHover
        defer { PaletteNativeHoverExperiment.enabled = previous }
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let fixture = PaletteResultFixture()
        let host = NSHostingView(rootView: PaletteResultFixtureView(fixture: fixture,
            cache: Favicons(profileID: UUID())))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500,
            height: 40 + Look.barRowHeight), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Keep the competing native target outside SwiftUI's managed subview tree.
        let container = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.contentView = container
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        host.layoutSubtreeIfNeeded()
        try await compatibilityWait { window.firstResponder is NSTextView }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        try await Task.sleep(for: .milliseconds(50))

        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let rect = NSRect(x: 0, y: host.isFlipped ? 40 : 0, width: 500, height: Look.barRowHeight)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func nativeAnchors(_ view: NSView) -> [Feel02PressAnchorView] {
            (view as? Feel02PressAnchorView).map { [$0] } ?? view.subviews.flatMap(nativeAnchors)
        }
        func nativeAnchor() throws -> Feel02PressAnchorView {
            let targets = nativeAnchors(host).filter { $0.hoverChanged != nil && $0.pressMonitor !== Feel02PressMonitor.shared }
            XCTAssertFalse(targets.isEmpty, "Opt-in Palette rows must expose a passive native hover target")
            return try XCTUnwrap(targets.first)
        }
        var pointerX: CGFloat = 100
        func moveNativePointer(inside: Bool, samePosition: Bool = false) throws {
            let anchor = try nativeAnchor()
            if !samePosition { pointerX += 1 }
            let point = inside ? anchor.convert(NSPoint(x: pointerX, y: anchor.bounds.midY), to: nil)
                : NSPoint(x: -20, y: -20)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            // The native fixture routes its own events without moving the user's pointer.
            XCTAssertTrue(try XCTUnwrap(anchor.pressMonitor).handle(event) === event)
        }
        func scrollNativePointer() throws {
            let anchor = try nativeAnchor()
            let event = ScrollEvent(window: window)
            XCTAssertTrue(try XCTUnwrap(anchor.pressMonitor).handle(event) === event)
        }
        func hover(_ entered: Bool) throws {
            if nativeHover {
                try moveNativePointer(inside: entered)
                return
            }
            func areas(_ view: NSView) -> [NSTrackingArea] {
                view.trackingAreas + view.subviews.flatMap(areas)
            }
            host.updateTrackingAreas()
            let targets = areas(host).filter { $0.options.contains(.mouseEnteredAndExited) }
            XCTAssertFalse(targets.isEmpty, "The mounted result must expose its real AppKit hover target")
            let selector = entered ? #selector(NSResponder.mouseEntered(with:)) : #selector(NSResponder.mouseExited(with:))
            for area in targets {
                guard let owner = area.owner as? NSObject, owner.responds(to: selector) else { continue }
                let event = PaletteHoverEvent(window: window, area: area, entered: entered)
                _ = owner.perform(selector, with: event)
            }
        }

        let unhovered = try pixels()
        let draws = fixture.parentDraws
        try hover(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotEqual(try pixels(), unhovered, "Hover still paints the result and reveals Forget")
        XCTAssertEqual(fixture.parentDraws, draws, "Crossing a result must not rebuild the search field or tab snapshots")
        XCTAssertTrue(window.firstResponder === editor, "Pointer hover must retain typing focus")

        if nativeHover {
            let anchor = try nativeAnchor()
            XCTAssertNil(anchor.hitTest(NSPoint(x: 100, y: anchor.bounds.midY)),
                         "Hover observation must not capture result or Forget clicks")
            XCTAssertFalse(anchor.pressMonitor === Feel02PressMonitor.shared,
                           "Palette hover must not arbitrate against targets behind the modal")
            try scrollNativePointer()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(try pixels(), unhovered, "Scrolling clears only pointer decoration")
            try moveNativePointer(inside: true, samePosition: true)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(try pixels(), unhovered, "Stationary tracking replay must not re-arm hover")
            try hover(true)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNotEqual(try pixels(), unhovered, "Actual pointer motion restores hover")

            anchor.updateTrackingAreas()
            let exitArea = try XCTUnwrap(anchor.trackingAreas.first { $0.options.contains(.mouseEnteredAndExited) })
            let areaCount = anchor.trackingAreas.count
            anchor.updateTrackingAreas()
            XCTAssertEqual(anchor.trackingAreas.count, areaCount, "Layout must reuse the cached exit tracking area")
            anchor.mouseExited(with: PaletteHoverEvent(window: window, area: exitArea, entered: false))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(try pixels(), unhovered, "A fast window exit must clear hover without a mouseMoved event")
            try hover(true)
            try await Task.sleep(for: .milliseconds(50))

            // A small competing target behind the Palette must not steal its hover.
            let behind = Feel02PressAnchorView(frame: anchor.convert(NSRect(x: 90, y: 0,
                width: 40, height: anchor.bounds.height), to: container))
            var behindHovered = false
            behind.hoverChanged = { behindHovered = $0 }
            container.addSubview(behind, positioned: .below, relativeTo: host)
            Feel02PressMonitor.shared.register(behind)
            defer { Feel02PressMonitor.shared.remove(behind); behind.removeFromSuperview() }
            pointerX += 1
            let point = anchor.convert(NSPoint(x: pointerX, y: anchor.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            _ = Feel02PressMonitor.shared.handle(event)
            _ = try XCTUnwrap(anchor.pressMonitor).handle(event)
            XCTAssertTrue(behindHovered, "The smaller competing target must participate in the control")
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNotEqual(try pixels(), unhovered, "The Palette retains its independent hover")

            fixture.enabled = false
            try await compatibilityWait { nativeAnchors(host).filter { $0 !== behind }.isEmpty }
            XCTAssertTrue(window.firstResponder === editor, "Disabling a row must not move typing focus")
            fixture.enabled = true
            try await compatibilityWait { nativeAnchors(host).contains { $0 !== behind } }
            XCTAssertEqual(try pixels(), unhovered, "Re-enabling must not restore stale hover after anchor disposal")
            try hover(true)
            try await Task.sleep(for: .milliseconds(50))
            fixture.surfaceEnabled = false
            try await compatibilityWait { nativeAnchors(host).filter { $0 !== behind }.isEmpty }
            fixture.surfaceEnabled = true
            try await compatibilityWait { nativeAnchors(host).contains { $0 !== behind } }
            XCTAssertEqual(try pixels(), unhovered, "Leaving an inert preview must not restore stale hover")
            try hover(true)
            try await Task.sleep(for: .milliseconds(50))
        }

        fixture.title = "Replacement in the same slot"
        try await Task.sleep(for: .milliseconds(50))
        let hoveredReplacement = try pixels()
        try hover(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotEqual(try pixels(), hoveredReplacement, "A result rewrite must retain hover on its stable slot")

        let beforeArrow = try pixels()
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await compatibilityWait {
            guard fixture.selected else { return false }
            return try pixels() != beforeArrow
        }
        XCTAssertTrue(window.firstResponder === editor, "Arrow selection must retain the command field")
        if nativeHover {
            let selectedPixels = try pixels()
            try scrollNativePointer()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(try pixels(), selectedPixels, "Scrolling must retain keyboard selection and its Forget affordance")
        }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(fixture.activated, 1)
        let forgetPoint = host.convert(NSPoint(
            x: host.bounds.maxX - Look.barInset - Look.barRowInset - Look.chip / 2,
            y: host.isFlipped ? 40 + Look.barRowHeight / 2 : Look.barRowHeight / 2), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: forgetPoint,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)))
            try await Task.sleep(for: .milliseconds(20))
        }
        try await compatibilityWait { fixture.forgotten == 1 }
        XCTAssertEqual(fixture.activated, 1, "Forget must not also activate its containing result")
    }
}

/// Deliver a tracking event to the fixture's own mounted AppKit tracking area.
/// This exercises SwiftUI hover without moving the user's pointer.
private final class PaletteHoverEvent: NSEvent, @unchecked Sendable {
    private let owner: NSWindow
    private let area: NSTrackingArea
    private let entered: Bool

    init(window: NSWindow, area: NSTrackingArea, entered: Bool) {
        owner = window
        self.area = area
        self.entered = entered
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { entered ? .mouseEntered : .mouseExited }
    override var window: NSWindow? { owner }
    override var trackingArea: NSTrackingArea? { area }
    override var locationInWindow: NSPoint { NSPoint(x: 100, y: Look.barRowHeight / 2) }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
