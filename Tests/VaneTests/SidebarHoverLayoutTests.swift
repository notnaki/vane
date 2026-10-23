import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarHoverLayoutTests: XCTestCase {
    func testHostedPressAnchorRejectsAncestorClipOutsideItsRowBounds() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let host = NSHostingView(rootView: SidebarHoverDisclosureRows(disclosure: .init()))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func anchors(in view: NSView) -> [Feel02PressAnchorView] {
            (view as? Feel02PressAnchorView).map { [$0] } ?? view.subviews.flatMap { anchors(in: $0) }
        }
        let rows = anchors(in: host)
        XCTAssertEqual(rows.count, 2)
        let folder = try XCTUnwrap(rows.max {
            $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY
        })
        let frame = folder.convert(folder.bounds, to: nil)
        let gap = NSPoint(x: frame.midX, y: frame.minY - Look.rowHeight / 2)
        let local = folder.convert(gap, from: nil)
        XCTAssertFalse(folder.bounds.contains(local), "The click must be in the disclosure gap")
        XCTAssertTrue(folder.visibleRect.contains(local),
                      "The hosted fixture exposes an ancestor clip beyond this row's bounds")
        var pressedRows = 0
        for row in rows {
            let callback = row.changed
            row.changed = { next in
                if next { pressedRows += 1 }
                callback?(next)
            }
        }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: gap, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown)
        XCTAssertTrue(Feel02PressMonitor.shared.handle(down) === down)
        _ = Feel02PressMonitor.shared.handle(try event(.leftMouseUp))
        XCTAssertEqual(pressedRows, 0, "A click outside both rows must not manufacture a pressed fill")
    }

    func testDisclosureDoesNotHoverNewTabUntilPointerActuallyMoves() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let disclosure = SidebarHoverDisclosureFixture()
        let host = NSHostingView(rootView: SidebarHoverDisclosureRows(disclosure: disclosure))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        func anchors(in view: NSView) -> [Feel02PressAnchorView] {
            (view as? Feel02PressAnchorView).map { [$0] } ?? view.subviews.flatMap { anchors(in: $0) }
        }
        let targets = anchors(in: host).sorted {
            $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY
        }
        XCTAssertEqual(targets.count, 2)
        let newTab = try XCTUnwrap(targets.first)
        let folder = try XCTUnwrap(targets.last)
        XCTAssertTrue(window.acceptsMouseMovedEvents, "Mounted row anchors must request native pointer input")
        let folderFrame = folder.convert(folder.bounds, to: nil)
        let stationary = NSPoint(x: folderFrame.midX, y: folderFrame.minY - Look.rowHeight / 2)
        func move(to location: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            // Direct native delivery avoids depending on the physical pointer in
            // another app. NSApp.sendEvent alone does not synthesize SwiftUI's
            // continuous-hover tracking callbacks; rendered pixels verify this
            // native input contract rather than reproducing an OS tracking replay.
            XCTAssertTrue(Feel02PressMonitor.shared.handle(event) === event)
        }
        func fillBrightness() throws -> CGFloat {
            host.layoutSubtreeIfNeeded()
            let rect = newTab.convert(newTab.bounds, to: host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
            host.cacheDisplay(in: rect, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: 8, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            return max(color.redComponent, color.greenComponent, color.blueComponent)
        }
        try move(to: stationary) // A real pointer move into the expanded folder's gap.
        XCTAssertLessThan(try fillBrightness(), 0.02)
        disclosure.expanded = false
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(newTab.convert(newTab.bounds, to: nil).midY, stationary.y, accuracy: 1)
        // Tracking-area updates can replay the pointer position after layout. They
        // must not manufacture hover when the row has moved underneath the pointer.
        try move(to: stationary)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try fillBrightness(), 0.02,
                          "Folder disclosure must not light New Tab beneath a stationary pointer")
        try move(to: NSPoint(x: stationary.x + 2, y: stationary.y))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try fillBrightness(), 0.04,
                             "Actual pointer movement must still reveal normal row hover")
        disclosure.expanded = true
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try fillBrightness(), 0.02, "Moving the hovered row clears its old highlight")
        disclosure.expanded = false
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try fillBrightness(), 0.02, "Moving the row back does not manufacture pointer motion")
        try move(to: NSPoint(x: stationary.x + 4, y: stationary.y))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try fillBrightness(), 0.04)
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                          wheelCount: 1, wheel1: 16, wheel2: 0, wheel3: 0))
        _ = Feel02PressMonitor.shared.handle(try XCTUnwrap(NSEvent(cgEvent: scroll)))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try fillBrightness(), 0.02, "Scrolling clears hover until the pointer moves")
        try move(to: NSPoint(x: stationary.x + 6, y: stationary.y))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try fillBrightness(), 0.04)
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited,
            location: NSPoint(x: -20, y: -20), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        _ = Feel02PressMonitor.shared.handle(exit)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try fillBrightness(), 0.02, "Leaving the window clears hover")
        try move(to: NSPoint(x: stationary.x + 8, y: stationary.y))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThan(try fillBrightness(), 0.04)
        disclosure.enabled = false
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try fillBrightness(), 0.02, "A retained disabled row clears hover")
    }

    func testMountedRowStillUpdatesSelectionAndRenameAfterObservationSplit() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        let tab = store.makeBlankTab(as: .today)
        tab.park(url: URL(string: "about:blank#row-observation")!, Parked(title: "A live row"))
        store.current = nil
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: Look.rowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView:
            SidebarTabSurface(store: store, tab: tab, returnHovering: .constant(false), action: {})
                .transaction { $0.disablesAnimations = true })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            store.dropStashes()
            tab.tearDown()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release([tab])
        }
        func pixels() throws -> Data {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func editableFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { $0.isEditable ? [$0] : [] }
                ?? view.subviews.flatMap { editableFields(in: $0) }
        }
        try await Task.sleep(for: .milliseconds(60))
        let unselected = try pixels()
        store.current = tab.id
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(try pixels(), unselected, "Selection must still reach the rendered row")
        store.renamingTab = tab.id
        try await compatibilityWait { !editableFields(in: host).isEmpty }
        XCTAssertEqual(editableFields(in: host).first?.stringValue, "A live row")
        store.renamingTab = nil
        try await compatibilityWait { editableFields(in: host).isEmpty }
    }

    func testHoverKeepsLongTabTitleAndSubtitleInPlace() throws {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        let tab = Tab(isPrivate: true, profileID: store.profileID)
        tab.park(url: URL(string: "about:blank")!,
                 Parked(title: "prepare Closet Dashboard with a very long title", needsRecovery: true))
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        defer {
            saver.setMode(previousMode)
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }

        // Compare only the title area of a selected row, whose fill does not change on
        // hover. Revealing the trailing button must not move or retruncate this text.
        for mode: BatterySaver.Mode in [.off, .alwaysOn] {
            saver.setMode(mode)
            func titlePixels(held: Bool) throws -> Data {
                let renderer = ImageRenderer(content:
                    SidebarTabSurface(store: store, tab: tab, held: held,
                        returnHovering: .constant(false),
                        pr: GitHub.Row(author: "notnaki", state: .open),
                        action: {}, previewSelected: true)
                    .frame(width: 250, height: Look.rowHeight)
                    .transaction { $0.disablesAnimations = true })
                let image = try XCTUnwrap(renderer.cgImage)
                let context = try XCTUnwrap(CGContext(data: nil, width: 180,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: 180 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0,
                    width: image.width, height: image.height))
                return Data(bytes: try XCTUnwrap(context.data),
                            count: context.bytesPerRow * context.height)
            }
            XCTAssertTrue(try titlePixels(held: false) == titlePixels(held: true),
                           "Hover must keep the title stable (\(mode))")
        }
    }
}

@MainActor private final class SidebarHoverDisclosureFixture: ObservableObject {
    @Published var expanded = true
    @Published var enabled = true
}

private struct SidebarHoverDisclosureRows: View {
    @ObservedObject var disclosure: SidebarHoverDisclosureFixture

    var body: some View {
        VStack(spacing: 0) {
            SidebarRow(icon: "folder", title: "Folder", selected: false, action: {})
            Color.clear.frame(height: disclosure.expanded ? 96 : 0)
            SidebarRow(icon: "plus", title: "New Tab", selected: false, dimmed: true, action: {})
                .disabled(!disclosure.enabled)
                .environment(\.sidebarRetainsControls, true)
            Spacer(minLength: 0)
        }
        .frame(width: 240, height: 240, alignment: .topLeading)
        .background(Color.black)
    }
}
