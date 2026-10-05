import AppKit
import XCTest
@testable import vane

final class TabTooltipTests: XCTestCase {
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
