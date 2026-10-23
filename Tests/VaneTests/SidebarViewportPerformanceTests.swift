import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarViewportPerformanceTests: XCTestCase {
    func testSidebarMountsOnlyRowsNearTheViewport() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var mounted = Set<Int>()
        let host = NSHostingView(rootView: SpaceSectionsLayout {
            Text("Work").frame(height: Look.rowHeight)
        } rows: {
            ForEach(0..<300, id: \.self) { index in
                Text("Document \(index)").frame(height: Look.rowHeight)
                    .onAppear { mounted.insert(index) }
            }
        })
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        let start = ContinuousClock.now
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        print("SIDEBAR_VIEWPORT rows=300 mounted=\(mounted.count) layout=\(start.duration(to: .now))")
        XCTAssertTrue(mounted.contains(0))
        XCTAssertLessThan(mounted.count, 60,
                          "Opening or switching must not mount hundreds of offscreen row controls")
    }

    func testLazySidebarRestoresScrollOffsetAndReachesLastRow() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var mounted = Set<Int>()
        let host = NSHostingView(rootView: SpaceSectionsLayout(initialOffset: 3_000) {
            Text("Work").frame(height: Look.rowHeight)
        } rows: {
            LazyVStack(spacing: Look.rowGap) {
                ForEach(0..<300, id: \.self) { index in
                    Text("Document \(index)").frame(height: Look.rowHeight)
                        .onAppear { mounted.insert(index) }
                }
            }
        })
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func scroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let scrollView = try XCTUnwrap(scroll(in: host))
        XCTAssertEqual(scrollView.contentView.bounds.minY, 3_000, accuracy: 1,
                       "A moving preview must begin at the outgoing sidebar's scroll offset")
        let height = try XCTUnwrap(scrollView.documentView).bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: height - scrollView.contentView.bounds.height))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(mounted.contains(299), "Offscreen tabs must remain reachable by scrolling")
        XCTAssertLessThan(mounted.count, 80)
    }


    /// Exercise production row virtualization; opt in to a longer layout timing run.
    func testPopulatedSidebarScrollTiming() async throws {
        let timing = ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1"
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        store.tabs = (0..<300).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.park(url: URL(string: "about:blank#scroll-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.syncShapes()
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 400),
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
            SharedTabs.release(store.tabs)
        }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func scroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        let scrollView = try XCTUnwrap(scroll(in: host))
        var times: [Double] = []
        let offsets = timing
            ? Array(stride(from: 0, through: 2_400, by: 20))
                + Array(stride(from: 2_400, through: 0, by: -20))
            : [0, 2_400, 0]
        func mountedRows(in view: NSView) -> Int {
            let own = (view as? TabTooltipAnchorView)?.title.hasPrefix("Document ") == true ? 1 : 0
            return own + view.subviews.reduce(0) { $0 + mountedRows(in: $1) }
        }
        for offset in offsets {
            let start = ProcessInfo.processInfo.systemUptime
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(timing ? 8 : 100))
            XCTAssertEqual(scrollView.contentView.bounds.minY, CGFloat(offset), accuracy: 1,
                           "The populated sidebar must reach each requested scroll position")
            let mounted = mountedRows(in: host)
            XCTAssertGreaterThan(mounted, 0, "Scrolling must keep visible tab controls mounted")
            XCTAssertLessThan(mounted, 60, "Scrolling must not mount all 300 tab controls")
        }
        times.sort()
        print("SIDEBAR_SCROLL_LAYOUT samples=\(times.count) median_ms=\(times[times.count / 2]) p95_ms=\(times[times.count * 95 / 100]) max_ms=\(times.last!)")
        XCTAssertEqual(scrollView.contentView.bounds.minY, 0, accuracy: 1)
    }

    /// Opt-in native layout timing; this does not measure displayed frame rate.
    func testSpaceSwipeLayoutTiming() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Swipe timing").id
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile,
            tabURLs: (0..<10).map { URL(string: "https://example.com/\($0)")! })
        XCTAssertTrue(manager.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        let count = ProcessInfo.processInfo.environment["VANE_LIBRARY_PERF_TABS"].flatMap(Int.init) ?? 300
        store.sharingReady = false
        store.tabs = (0..<count).map { index in
            let tab = Tab(profileID: profile)
            tab.park(url: URL(string: "about:blank#space-\(index)")!, Parked(title: "Document \(index)"))
            return tab
        }
        store.syncShapes()
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store).environmentObject(manager))
        window.contentView = host
        defer {
            store.spaceGesture.monitor.abort()
            window.contentView = nil
            window.close()
            store.window = nil
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile)
            manager.delete(profile)
        }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        store.spaceSwiping = true
        store.spaceDrag = -15
        host.layoutSubtreeIfNeeded()
        var times: [Double] = []
        for index in 1...30 {
            let start = ContinuousClock.now
            store.spaceDrag = -15 - CGFloat(index * 3)
            host.layoutSubtreeIfNeeded()
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            try await Task.sleep(for: .milliseconds(8))
        }
        times.sort()
        print("SPACE_SWIPE_LAYOUT tabs=\(count) median_ms=\(times[15]) p95_ms=\(times[28]) max_ms=\(times.last!) display_hz=\(window.screen?.maximumFramesPerSecond ?? 0)")
    }

}
