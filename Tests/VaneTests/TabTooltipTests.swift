import AppKit
import SwiftUI
import XCTest
@testable import vane

final class TabTooltipTests: XCTestCase {
    @MainActor func testHostedFolderTooltipStaysBesideItsRowInsteadOfTheAncestorClip() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            // Supply a stable screen position without depending on the runner's
            // cursor or moving a titled window beyond the screen's usable bounds.
            var pointer = NSPoint.zero
            let tooltip = TabTooltip(mouseLocation: { pointer })
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                Color.clear.frame(height: 200)
                Text("Pull Requests").frame(width: 228, height: 36)
                    .background(HostedFolderTooltipAnchor(tooltip: tooltip))
                Spacer(minLength: 0)
            }.frame(width: 240, height: 400).background(.black))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            defer {
                tooltip.dismiss()
                window.contentView = nil
                window.close()
            }
            func find(_ view: NSView) -> TabTooltipAnchorView? {
                (view as? TabTooltipAnchorView) ?? view.subviews.lazy.compactMap { find($0) }.first
            }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return app.isRunning && app.isActive && app.keyWindow === window && window.isKeyWindow
                    && window.isVisible && window.occlusionState.contains(.visible)
                    && app.modalWindow == nil && window.attachedSheet == nil
                    && find(host)?.bounds.size == CGSize(width: 228, height: 36)
            }
            let anchor = try XCTUnwrap(find(host))
            XCTAssertGreaterThan(anchor.visibleRect.height, anchor.bounds.height,
                "The hosted fixture must expose the oversized ancestor clip behind this regression")
            let row = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            pointer = NSPoint(x: row.midX, y: row.midY)
            let screen = try XCTUnwrap(window.screen)
            tooltip.schedule(for: anchor)
            try await compatibilityWait { tooltip.isVisible }
            let panel = try XCTUnwrap(window.childWindows?.first as? NSPanel)
            let expected = TabTooltipLayout.frame(anchor: row, size: panel.frame.size,
                                                  screen: screen.visibleFrame, centered: true)
            XCTAssertEqual(panel.frame.minX, expected.minX, accuracy: 1)
            XCTAssertEqual(panel.frame.minY, expected.minY, accuracy: 1,
                "The hint must sit beside the folder, not at the edge of its ancestor's clip")
            if let path = ProcessInfo.processInfo.environment["VANE_TOOLTIP_CAPTURE_PATH"],
               let tooltipView = panel.contentView {
                let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
                let canvas = contentFrame.union(panel.frame)
                let image = NSImage(size: canvas.size)
                do {
                    image.lockFocus()
                    defer { image.unlockFocus() }
                    NSColor.black.setFill()
                    NSRect(origin: .zero, size: canvas.size).fill()
                    for view in [host, tooltipView] {
                        view.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        let frame = try XCTUnwrap(view.window).convertToScreen(view.convert(view.bounds, to: nil))
                        bitmap.draw(in: frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
                    }
                }
                let bitmap = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))
                try XCTUnwrap(bitmap?.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: path))
            }
            // Refreshing a visible hint must use the same row-sized anchor.
            anchor.configure(title: "Pull Requests updated", hint: "Click to expand or collapse",
                             centered: true, enabled: true)
            let refreshed = TabTooltipLayout.frame(anchor: row, size: panel.frame.size,
                                                   screen: screen.visibleFrame, centered: true)
            XCTAssertEqual(panel.frame.minY, refreshed.minY, accuracy: 1)
            tooltip.dismiss()
            // The surrounding clip must not admit hover in the empty space above the row.
            let gap = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.maxY + 40)
            pointer = window.convertPoint(toScreen: anchor.convert(gap, to: nil))
            XCTAssertFalse(anchor.bounds.contains(gap))
            XCTAssertTrue(anchor.visibleRect.contains(gap))
            tooltip.schedule(for: anchor)
            try await compatibilityWait { !tooltip.isPending }
            XCTAssertFalse(tooltip.isVisible,
                "An ancestor's empty space must not show the folder's tooltip")
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Tooltip fixture loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    @MainActor func testVisibleRectTrackingAreaSurvivesRepeatedClippingUpdates() throws {
        let (anchor, _, _) = nestedAnchors()
        anchor.updateTrackingAreas()
        let area = try XCTUnwrap(anchor.trackingAreas.first)
        XCTAssertTrue(area.options.contains(.inVisibleRect))
        XCTAssertTrue(area.options.contains(.activeInKeyWindow))
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(area.owner as AnyObject? === anchor)

        // AppKit owns the effective rectangle for .inVisibleRect. Rebuilding this
        // registration for each row geometry update adds tracking-region work.
        let parent = try XCTUnwrap(anchor.superview)
        parent.bounds.size.height = 16
        XCTAssertEqual(anchor.visibleRect.height, 16, accuracy: 0.01)
        for _ in 0..<20 { anchor.updateTrackingAreas() }
        XCTAssertEqual(anchor.trackingAreas.count, 1)
        XCTAssertTrue(anchor.trackingAreas.first === area,
            "Clipping changes must reuse the existing native tracking registration")
        parent.bounds.size.height = 32
        anchor.updateTrackingAreas()
        XCTAssertEqual(anchor.visibleRect.height, 32, accuracy: 0.01)
        XCTAssertTrue(anchor.trackingAreas.first === area)
        XCTAssertNil(anchor.hitTest(CGPoint(x: 10, y: 10)))
    }

    @MainActor func testTrackingOwnerKeepsHoverCancellationAcrossDisableAndWindowDetach() throws {
        let (anchor, _, tooltip) = nestedAnchors()
        anchor.updateTrackingAreas()
        let area = try XCTUnwrap(anchor.trackingAreas.first)
        let owner = try XCTUnwrap(area.owner as? TabTooltipAnchorView)
        owner.mouseEntered(with: hoverEvent(.mouseEntered))
        XCTAssertTrue(tooltip.isPending)
        owner.mouseExited(with: hoverEvent(.mouseExited))
        XCTAssertFalse(tooltip.isPending)
        owner.mouseEntered(with: hoverEvent(.mouseEntered))
        anchor.configure(title: "Page title", enabled: false)
        XCTAssertFalse(tooltip.isPending)
        owner.mouseEntered(with: hoverEvent(.mouseEntered))
        XCTAssertFalse(tooltip.isPending)
        anchor.configure(title: "Page title", enabled: true)
        owner.mouseEntered(with: hoverEvent(.mouseEntered))
        XCTAssertTrue(tooltip.isPending)
        anchor.removeFromSuperview()
        XCTAssertNil(anchor.window)
        XCTAssertFalse(tooltip.isPending)
        XCTAssertFalse(tooltip.isVisible)
    }

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

private struct HostedFolderTooltipAnchor: NSViewRepresentable {
    let tooltip: TabTooltip
    func makeNSView(context: Context) -> TabTooltipAnchorView { TabTooltipAnchorView(tooltip: tooltip) }
    func updateNSView(_ view: TabTooltipAnchorView, context: Context) {
        view.configure(title: "Pull Requests", hint: "Click to expand or collapse",
                       centered: true, enabled: true)
    }
    static func dismantleNSView(_ view: TabTooltipAnchorView, coordinator: ()) {
        view.tooltip.dismiss(for: view)
    }
}
