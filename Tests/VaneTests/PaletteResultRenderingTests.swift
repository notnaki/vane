import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor private final class PaletteResultFixture: ObservableObject {
    @Published var selected = false
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
        }
        .environment(\.colorScheme, .dark)
    }
}

@MainActor final class PaletteResultRenderingTests: XCTestCase {
    func testHoverStaysInResultSlotWhileKeyboardSelectionAndForgetRemainLive() async throws {
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
        window.contentView = host
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
        func hover(_ entered: Bool) throws {
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
