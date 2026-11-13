import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarWidthObservationTests: XCTestCase {
    private final class Bodies {
        var counts: [String: Int] = [:]
        func record(_ event: String) {
            if event.hasPrefix("sidebar.body.") { counts[event, default: 0] += 1 }
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func browser(width: CGFloat) -> (NSWindow, NSView, TabStore, vane.Tab) {
        let store = TabStore(isPrivate: true, session: [])
        store.tabs = (0..<4).map { index in
            let tab = store.makeBlankTab(as: .favourite)
            tab.park(url: URL(string: "https://example.test/\(index)")!, Parked(title: "Favorite \(index)"))
            return tab
        }
        let page = store.newBlankTab()
        _ = page.web
        store.palette = nil
        store.sidebarShown = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let root = NSHostingView(rootView: BrowserWindow(presentsPalette: false)
            .environmentObject(store).environmentObject(ProfileManager.shared)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        root.sizingOptions = []
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            window.contentView = nil
            store.window = nil
            window.close()
            store.dropStashes()
            SharedTabs.release(store.tabs, excluding: store)
            TabStore.all.removeAll { $0 === store }
        }
        return (window, root, store, page)
    }

    func testWidthUpdatesNativeGeometryWithoutRebuildingBrowserContent() throws {
        TestEnvironment.prepare()
        let previous = SidebarWidth.shared.width
        SidebarWidth.shared.setLiveWidth(228)
        let bodies = Bodies()
        let oldSink = ResizeTimingDiagnostics.sink
        ResizeTimingDiagnostics.sink = { event, _, _, _ in bodies.record(event) }
        defer {
            ResizeTimingDiagnostics.sink = oldSink
            SidebarWidth.shared.setLiveWidth(previous)
        }
        let (window, root, store, tab) = browser(width: 900)
        let host = try XCTUnwrap(tab.web.superview as? WebHost)
        XCTAssertEqual(host.bounds.width, 661, accuracy: 0.001)
        for body in ["browser", "sidebar", "strip", "libraryHead", "header", "pill", "favorites"] {
            XCTAssertGreaterThan(bodies.counts["sidebar.body." + body, default: 0], 0,
                                 "The real \(body) must be mounted before checking invalidation")
        }
        let strip = try XCTUnwrap(store.spaceGesture.stripView)
        let sections = try XCTUnwrap(store.spaceGesture.sectionsView)
        XCTAssertEqual(strip.bounds.width, 212, accuracy: 0.001)
        let scrolls = descendants(NSScrollView.self, in: root)
        XCTAssertFalse(scrolls.isEmpty, "Retained sidebar and Library containers must actually be mounted")
        let scrollIDs = Set(scrolls.map(ObjectIdentifier.init))
        let presentation = SidebarResizeFrameLayout(window: window, root: root)
        bodies.counts.removeAll()
        for width: CGFloat in [300, 164, 500, 228] {
            let before = SidebarWidth.shared.width
            SidebarWidth.shared.setLiveWidth(width)
            presentation.didPublishWidth(from: before, to: width)
            presentation.presentFrame()
            XCTAssertTrue(tab.web.superview === host, "Width updates preserve the native page owner")
            XCTAssertEqual(host.bounds.width, 889 - width, accuracy: 0.001)
            XCTAssertTrue(store.spaceGesture.stripView === strip)
            XCTAssertTrue(store.spaceGesture.sectionsView === sections)
            XCTAssertEqual(strip.bounds.width, width - 16, accuracy: 0.001,
                           "The retained sidebar contents must receive their new native width")
            XCTAssertEqual(host.resizeLayout.sidebarWidth, width,
                           "Native buffer metadata must track the submitted shared width")
            XCTAssertEqual(Set(descendants(NSScrollView.self, in: root).map(ObjectIdentifier.init)), scrollIDs,
                           "Width layout must retain native content containers")
            XCTAssertFalse(window.isVisible)
        }
        print("SIDEBAR_WIDTH_BODIES \(bodies.counts)")
        for body in ["browser", "sidebar", "strip", "libraryHead"] {
            XCTAssertEqual(bodies.counts["sidebar.body." + body, default: 0], 0,
                           "Width-only geometry must not rebuild the unrelated \(body) content")
        }
        for body in ["header", "pill", "favorites"] {
            XCTAssertGreaterThan(bodies.counts["sidebar.body." + body, default: 0], 0,
                                 "The responsive \(body) must still observe width")
        }
        store.sidebarShown = false
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(bodies.counts["sidebar.body.browser", default: 0], 0,
                             "Real store changes must still update the browser")
        XCTAssertEqual(host.resizeLayout.sidebarWidth, 0)
    }

    func testSharedWidthFitsEachHiddenWindowAndRetainsNativePageOwners() throws {
        TestEnvironment.prepare()
        let previous = SidebarWidth.shared.width
        SidebarWidth.shared.setLiveWidth(228)
        defer { SidebarWidth.shared.setLiveWidth(previous) }
        let (wideWindow, wideRoot, _, wideTab) = browser(width: 900)
        let (narrowWindow, narrowRoot, _, narrowTab) = browser(width: 600)
        let widePage = try XCTUnwrap(wideTab.web.superview as? WebHost)
        let narrowPage = try XCTUnwrap(narrowTab.web.superview as? WebHost)
        SidebarWidth.shared.setLiveWidth(500)
        wideRoot.layoutSubtreeIfNeeded()
        narrowRoot.layoutSubtreeIfNeeded()
        XCTAssertEqual(widePage.bounds.width, 389, accuracy: 0.001)
        XCTAssertEqual(narrowPage.bounds.width, 189, accuracy: 0.001)
        XCTAssertEqual(widePage.resizeLayout.sidebarWidth, 500)
        XCTAssertEqual(narrowPage.resizeLayout.sidebarWidth, 500)
        narrowWindow.setContentSize(NSSize(width: 550, height: 600))
        narrowRoot.layoutSubtreeIfNeeded()
        narrowRoot.layoutSubtreeIfNeeded()
        XCTAssertEqual(narrowPage.bounds.width, 189, accuracy: 0.001)
        XCTAssertEqual(widePage.bounds.width, 389, accuracy: 0.001)
        XCTAssertTrue(wideTab.web.superview === widePage)
        XCTAssertTrue(narrowTab.web.superview === narrowPage)
        XCTAssertFalse(wideWindow.isVisible)
        XCTAssertFalse(narrowWindow.isVisible)
    }

    func testPageMetadataReachesSplitAndOffscreenOwnersAfterWidthChanges() throws {
        TestEnvironment.prepare()
        let previous = SidebarWidth.shared.width
        SidebarWidth.shared.setLiveWidth(228)
        defer { SidebarWidth.shared.setLiveWidth(previous) }
        let (window, root, store, first) = browser(width: 900)
        let second = store.newBlankTab(focus: false)
        let hidden = store.newBlankTab(focus: false)
        _ = second.web
        _ = hidden.web
        hidden.inMeetCall = true
        defer { hidden.inMeetCall = false }
        var split = try XCTUnwrap(Split(tabs: [first.id, second.id]))
        split.vertical = false
        store.splits = [split]
        root.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let firstHost = try XCTUnwrap(first.web.superview as? WebHost)
        let secondHost = try XCTUnwrap(second.web.superview as? WebHost)
        let hiddenHost = try XCTUnwrap(hidden.web.superview as? WebHost)
        XCTAssertFalse(firstHost === secondHost)
        XCTAssertFalse(hiddenHost === firstHost || hiddenHost === secondHost)
        XCTAssertTrue(hiddenHost.offscreen, "The separate offscreen media branch must actually be mounted")
        let presentation = SidebarResizeFrameLayout(window: window, root: root)
        for (width, paneWidth): (CGFloat, CGFloat) in [(300, 290), (500, 190)] {
            let before = SidebarWidth.shared.width
            SidebarWidth.shared.setLiveWidth(width)
            presentation.didPublishWidth(from: before, to: width)
            presentation.presentFrame()
            for host in [firstHost, secondHost, hiddenHost] {
                XCTAssertTrue(host.window === window)
                XCTAssertEqual(host.resizeLayout.sidebarWidth, width)
                XCTAssertTrue(host.resizeLayout.enabled)
            }
            XCTAssertEqual(firstHost.resizeFraction.width, 0.5)
            XCTAssertEqual(secondHost.resizeFraction.width, 0.5)
            XCTAssertEqual(firstHost.bounds.width, paneWidth, accuracy: 0.001)
            XCTAssertEqual(secondHost.bounds.width, paneWidth, accuracy: 0.001)
            XCTAssertTrue(first.web.superview === firstHost)
            XCTAssertTrue(second.web.superview === secondHost)
            XCTAssertTrue(hidden.web.superview === hiddenHost)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testWidthChangesRetainLibrarySearchAndRealQueryUpdates() throws {
        TestEnvironment.prepare()
        let previous = SidebarWidth.shared.width
        let query = Library.shared.query
        SidebarWidth.shared.setLiveWidth(228)
        defer {
            SidebarWidth.shared.setLiveWidth(previous)
            Library.shared.query = query
        }
        let (window, root, _, _) = browser(width: 900)
        let field = try XCTUnwrap(descendants(CommandField.BarField.self, in: root).first {
            $0.placeholderString == Library.shared.section.searchPrompt
        })
        let originalWidth = field.frame.width
        Library.shared.query = "kept search"
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(field.stringValue, "kept search")
        SidebarWidth.shared.setLiveWidth(164)
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(field.isDescendant(of: root))
        XCTAssertEqual(field.stringValue, "kept search")
        XCTAssertEqual(field.frame.width, originalWidth, accuracy: 0.001)
        Library.shared.query = "updated search"
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(field.stringValue, "updated search")
        XCTAssertFalse(window.isVisible)
    }

}
