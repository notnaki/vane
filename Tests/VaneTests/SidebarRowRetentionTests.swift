import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarRowRetentionTests: XCTestCase {
    /// The small real-world outline (a seven-tab folder above Today) should not
    /// rebuild native controls when it folds or when those rows cross the viewport.
    func testSmallSidebarKeepsControlsThroughFolderToggleAndScroll() async throws {
        useLegacySidebarMountingPolicy()
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        let tabs = (0..<22).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.kind = index < 11 ? .pinned : .today
            tab.park(url: URL(string: "about:blank#retained-\(index)")!, Parked(title: "Retained \(index)"))
            return tab
        }
        store.tabs = tabs
        let folder = Folder(name: "Documents")
        store.pins = Pins(entries: tabs.prefix(4).map { .init(row: .tab($0.id.uuidString)) }
            + [.init(row: .folder(folder))]
            + tabs[4..<11].map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
        store.todayShape = Pins(entries: tabs[11...].map { .init(row: .tab($0.id.uuidString)) })
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func anchors(in view: NSView) -> [TabTooltipAnchorView] {
            let own = (view as? TabTooltipAnchorView).map { [$0] } ?? []
            return own + view.subviews.flatMap { anchors(in: $0) }
        }
        func pressAnchors(in view: NSView) -> [Feel02PressAnchorView] {
            let own = (view as? Feel02PressAnchorView).map { [$0] } ?? []
            return own + view.subviews.flatMap { pressAnchors(in: $0) }
        }
        let originalPress = Set(pressAnchors(in: host).map(ObjectIdentifier.init))
        let original = try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 4" })
        let next = try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 5" })
        let today = try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 11" })
        let visibleSibling = try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 0" })
        let pitch = Look.rowHeight + Look.rowGap
        let folderY = original.convert(original.bounds, to: host).minY - pitch
        let folderControl = try XCTUnwrap(pressAnchors(in: host).first {
            $0.bounds.width > 150 && abs($0.convert($0.bounds, to: host).minY - folderY) < 1
        })
        XCTAssertEqual(abs(original.convert(.zero, to: host).y - next.convert(.zero, to: host).y),
                       pitch, accuracy: 0.5)
        let todayBefore = today.convert(.zero, to: host).y
        Motion.instant { store.toggleFolder(folder.id) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let afterPress = Set(pressAnchors(in: host).map(ObjectIdentifier.init))
        if RetainedRowVirtualizationExperiment.enabled {
            XCTAssertTrue(pressAnchors(in: host).contains { $0 === folderControl })
            XCTAssertTrue(anchors(in: host).contains { $0 === visibleSibling })
            XCTAssertTrue(anchors(in: host).contains { $0 === today })
            XCTAssertTrue(original.window == nil || !original.enabled,
                          "A collapsed child must be unmounted or inert")
            XCTAssertFalse(anchors(in: host).contains { $0.title == "Retained 4" && $0.enabled })
        } else {
            XCTAssertTrue(anchors(in: host).contains { $0 === original },
                          "Small collapsed folders must retain their controls for the next opening")
            XCTAssertFalse(original.enabled, "Collapsed rows must disable their native tooltip/input anchors")
            XCTAssertEqual(afterPress, originalPress,
                           "The eager outline must retain exactly the same passive press anchors")
            XCTAssertGreaterThanOrEqual(pressAnchors(in: host).filter { !$0.enabled }.count, 7)
        }
        XCTAssertEqual(abs(today.convert(.zero, to: host).y - todayBefore), 7 * pitch, accuracy: 0.5,
                       "Closing must remove each child's height and gap, without phantom slots")
        Motion.instant { store.toggleFolder(folder.id) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        if RetainedRowVirtualizationExperiment.enabled {
            XCTAssertTrue(pressAnchors(in: host).contains { $0 === folderControl })
            XCTAssertTrue(anchors(in: host).contains { $0 === visibleSibling })
            XCTAssertTrue(anchors(in: host).contains { $0 === today })
            XCTAssertTrue(try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 4" }).enabled)
            XCTAssertTrue(try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 5" }).enabled)
        } else {
            XCTAssertTrue(anchors(in: host).contains { $0 === original })
            XCTAssertTrue(anchors(in: host).contains { $0 === next })
            XCTAssertTrue(original.enabled)
        }
        func scroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let scrollView = try XCTUnwrap(scroll(in: host))
        let timing = ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1"
        let offsets = timing ? Array(stride(from: 0, through: 300, by: 4))
            + Array(stride(from: 300, through: 0, by: -4)) : [300, 0]
        var times: [Double] = []
        for offset in offsets {
            let start = ProcessInfo.processInfo.systemUptime
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(timing ? 8 : 80))
        }
        times.sort()
        if timing {
            print("SMALL_SIDEBAR_SCROLL samples=\(times.count) median_ms=\(times[times.count / 2]) p95_ms=\(times[times.count * 95 / 100]) max_ms=\(times.last!)")
        }
        if RetainedRowVirtualizationExperiment.enabled {
            XCTAssertTrue(try XCTUnwrap(anchors(in: host).first { $0.title == "Retained 4" }).enabled,
                          "Returning to the viewport must restore a usable row")
        } else {
            XCTAssertTrue(anchors(in: host).contains { $0 === original },
                          "Scrolling an eager small sidebar must reuse its existing row controls")
        }
        XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
    }
}
