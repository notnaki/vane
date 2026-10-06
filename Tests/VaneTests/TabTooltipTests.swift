import AppKit
import SwiftUI
import XCTest
@testable import vane

final class TabTooltipTests: XCTestCase {
    @MainActor func testInputStaysDismissedThroughUnrelatedDisabledControlUpdates() {
        let (row, control, tooltip) = nestedAnchors()
        row.mouseEntered(with: hoverEvent(.mouseEntered))
        control.mouseEntered(with: hoverEvent(.mouseEntered))
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        _ = tooltip.handle(click)
        let unrelated = TabTooltipAnchorView(tooltip: tooltip)
        unrelated.frame = CGRect(x: 100, y: 0, width: 20, height: 32)
        row.superview?.addSubview(unrelated)
        unrelated.configure(title: "Unavailable", enabled: false)
        XCTAssertFalse(tooltip.isPending, "An unrelated update must not reopen a tooltip after input")
        control.mouseExited(with: hoverEvent(.mouseExited))
        XCTAssertTrue(tooltip.isPending, "Actual pointer movement back to the title can re-arm the row")
        tooltip.dismiss()
        row.mouseExited(with: hoverEvent(.mouseExited))
        XCTAssertFalse(tooltip.isPending, "Menu or window dismissal must clear remembered hover targets")
    }

    @MainActor func testLeavingANestedControlRestoresTheContainingRowsTooltip() {
        let (row, control, tooltip) = nestedAnchors()
        row.mouseEntered(with: hoverEvent(.mouseEntered))
        control.mouseEntered(with: hoverEvent(.mouseEntered))
        control.mouseExited(with: hoverEvent(.mouseExited))
        XCTAssertTrue(tooltip.isPending, "The pointer is still inside the row's title target")
        tooltip.dismiss(for: row)
        XCTAssertFalse(tooltip.isPending, "The restored tooltip must belong to the row")
    }

    @MainActor func testNestedControlWinsEvenWhenItsContainingRowEntersLast() {
        let (row, control, tooltip) = nestedAnchors()
        control.mouseEntered(with: hoverEvent(.mouseEntered))
        row.mouseEntered(with: hoverEvent(.mouseEntered))
        tooltip.dismiss(for: row)
        XCTAssertTrue(tooltip.isPending, "A containing row must not replace its smaller control's hint")
        control.mouseExited(with: hoverEvent(.mouseExited))
        XCTAssertFalse(tooltip.isPending)
    }

    @MainActor private func nestedAnchors() -> (TabTooltipAnchorView, TabTooltipAnchorView, TabTooltip) {
        _ = NSApplication.shared
        let tooltip = TabTooltip()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 220, height: 32),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 32))
        window.contentView = root
        let row = TabTooltipAnchorView(tooltip: tooltip)
        row.frame = root.bounds
        row.configure(title: "Page title", enabled: true)
        let control = TabTooltipAnchorView(tooltip: tooltip)
        control.frame = CGRect(x: 190, y: 0, width: 30, height: 32)
        control.configure(title: "Close Tab", hint: nil, centered: true, enabled: true)
        root.addSubview(row)
        root.addSubview(control)
        addTeardownBlock { @MainActor in tooltip.dismiss(); window.close() }
        return (row, control, tooltip)
    }

    private func hoverEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: CGPoint(x: 200, y: 16), modifierFlags: [],
            timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
    }

    func testControlTooltipsStayCompactEvenWithLongTitlesHintsAndShortcuts() {
        XCTAssertEqual(TabTooltipLayout.width(title: String(repeating: "Long title ", count: 50),
            hint: "Click to switch · Right-click to customize", shortcut: "⇧⌘C", compact: true), 240)
        XCTAssertLessThan(TabTooltipLayout.width(title: "Reload Page", hint: nil,
                                                 shortcut: "⌘R", compact: true), 180)
    }

    @MainActor func testControlTooltipUsesItsOwnHintAndShortcutWithoutARenamePrompt() throws {
        let anchor = try controlAnchor(disabled: false)
        XCTAssertEqual(anchor.title, "Reload Page")
        XCTAssertNil(anchor.hint, "Controls must not inherit a tab's double-click-to-rename hint")
        XCTAssertEqual(anchor.shortcut, "⌘R")
        XCTAssertTrue(anchor.centered)
        XCTAssertTrue(anchor.enabled)
    }

    @MainActor func testDisabledControlCannotScheduleACustomTooltip() throws {
        let anchor = try controlAnchor(disabled: true)
        XCTAssertFalse(anchor.enabled)
        anchor.tooltip.schedule(for: anchor)
        XCTAssertFalse(anchor.tooltip.isPending)
    }

    @MainActor private func controlAnchor(disabled: Bool) throws -> TabTooltipAnchorView {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Button("Reload") {}
            .vaneTooltip("Reload Page", shortcut: "⌘R").disabled(disabled))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            TabTooltip.shared.dismiss()
            window.close()
        }
        func find(_ view: NSView) -> TabTooltipAnchorView? {
            if let anchor = view as? TabTooltipAnchorView { return anchor }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(hosting))
    }

    func testControlTooltipCentersUnderItsButtonAndClampsAtTheScreenEdge() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let anchor = CGRect(x: -600, y: 400, width: 28, height: 28)
        let size = CGSize(width: 140, height: 32)
        let frame = TabTooltipLayout.frame(anchor: anchor, size: size, screen: screen, centered: true)
        XCTAssertEqual(frame.midX, anchor.midX)
        let edge = TabTooltipLayout.frame(anchor: CGRect(x: -20, y: -195, width: 20, height: 20),
                                         size: size, screen: screen, centered: true)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(edge))
    }

    func testShortTitlesFitTheirTextAndLongTitlesHaveAWidthCap() {
        XCTAssertLessThan(TabTooltipLayout.width(title: "Docs"), 180)
        XCTAssertLessThan(TabTooltipLayout.width(title: "Desmos | Graphing Calculator"), 250)
        XCTAssertEqual(TabTooltipLayout.width(title: String(repeating: "Long title ", count: 50)), 300)
    }

    func testTooltipCanExtendPastTheSidebarButStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 20, y: 600, width: 220, height: 32)
        let frame = TabTooltipLayout.frame(anchor: anchor, size: CGSize(width: 320, height: 64), screen: screen)
        XCTAssertGreaterThan(frame.maxX, anchor.maxX)
        XCTAssertLessThan(frame.maxY, anchor.minY)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testTooltipFlipsAboveABottomRowOnASecondaryScreen() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let anchor = CGRect(x: -100, y: -190, width: 90, height: 32)
        let frame = TabTooltipLayout.frame(anchor: anchor, size: CGSize(width: 320, height: 64), screen: screen)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
    }

    @MainActor func testAnchorNeverInterceptsTabClicksAndDisablingCancelsHover() {
        _ = NSApplication.shared
        let tooltip = TabTooltip()
        let anchor = TabTooltipAnchorView(tooltip: tooltip)
        anchor.frame = CGRect(x: 0, y: 0, width: 220, height: 32)
        XCTAssertNil(anchor.hitTest(CGPoint(x: 20, y: 10)))
        anchor.configure(title: "Desmos | Graphing Calculator", enabled: true)
        tooltip.schedule(for: anchor)
        XCTAssertTrue(tooltip.isPending)
        anchor.configure(title: "Desmos | Graphing Calculator", enabled: false)
        XCTAssertFalse(tooltip.isPending)
        XCTAssertFalse(tooltip.isVisible)
    }

    @MainActor func testLeavingAnOldRowDoesNotDismissTheNewRowsTooltip() {
        _ = NSApplication.shared
        let tooltip = TabTooltip()
        let first = TabTooltipAnchorView(tooltip: tooltip)
        let second = TabTooltipAnchorView(tooltip: tooltip)
        tooltip.schedule(for: first)
        tooltip.schedule(for: second)
        tooltip.dismiss(for: first)
        XCTAssertTrue(tooltip.isPending)
        tooltip.dismiss(for: second)
        XCTAssertFalse(tooltip.isPending)
    }

    @MainActor func testClickDismissesPendingTooltipWithoutConsumingTheEvent() {
        _ = NSApplication.shared
        let tooltip = TabTooltip()
        let anchor = TabTooltipAnchorView(tooltip: tooltip)
        tooltip.schedule(for: anchor)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 2, pressure: 1)!
        XCTAssertTrue(tooltip.handle(event) === event)
        XCTAssertFalse(tooltip.isPending)
    }
}
