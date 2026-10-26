import AppKit
import SwiftUI
import XCTest
@testable import vane

final class SpaceStripLayoutTests: XCTestCase {
    func testEverySpaceKeepsItsIconWhenTenTargetsFit() {
        for count in 1...10 {
            let layout = SpaceStripLayout(count: count, availableWidth: 132)
            XCTAssertTrue(layout.showsAllIcons, "Space count: \(count)")
            XCTAssertGreaterThanOrEqual(layout.itemWidth, layout.iconSize + 2)
            XCTAssertLessThanOrEqual(layout.itemWidth * CGFloat(count), 132)
        }
    }

    func testOverflowUsesCompactMarkersWithoutChangingTargetSizes() {
        let ten = SpaceStripLayout(count: 10, availableWidth: 132)
        let eleven = SpaceStripLayout(count: 11, availableWidth: 132)
        XCTAssertTrue(ten.showsAllIcons)
        XCTAssertFalse(eleven.showsAllIcons)
        XCTAssertEqual(eleven.itemWidth, ten.itemWidth)
        XCTAssertEqual(eleven.iconSize, ten.iconSize)
    }

    func testNarrowViewportFallsBackOnlyUntilTheIconsFit() {
        let narrow = SpaceStripLayout(count: 5, availableWidth: 68)
        let fitting = SpaceStripLayout(count: 5, availableWidth: 80)
        XCTAssertFalse(narrow.showsAllIcons)
        XCTAssertTrue(fitting.showsAllIcons)
        XCTAssertGreaterThanOrEqual(fitting.itemWidth, fitting.iconSize + 2)
    }

    func testWideFooterKeepsEveryIconBeyondTenSpaces() {
        let layout = SpaceStripLayout(count: 12, availableWidth: 400)
        XCTAssertTrue(layout.showsAllIcons)
        XCTAssertLessThanOrEqual(layout.itemWidth * 12, 400)
    }

    func testThreeSpacesUseArcSpacingAndSizes() {
        let layout = SpaceStripLayout(count: 3, availableWidth: 154)
        XCTAssertEqual(layout.itemWidth, 34)
        XCTAssertEqual(layout.dotSize, 8)
        XCTAssertEqual(layout.iconSize, 12)
        XCTAssertFalse(layout.scrolls)
    }

    func testFiveButtonTargetsFitBetweenFooterControls() {
        let layout = SpaceStripLayout(count: 5, availableWidth: 132)
        XCTAssertTrue(layout.showsButtonBackground)
        XCTAssertFalse(layout.scrolls)
        XCTAssertLessThanOrEqual(layout.itemWidth * 5, 132)
        XCTAssertGreaterThanOrEqual(layout.itemWidth, 24)
    }

    func testSixThroughTenShrinkWithoutScrolling() {
        let six = SpaceStripLayout(count: 6, availableWidth: 132)
        let ten = SpaceStripLayout(count: 10, availableWidth: 132)
        XCTAssertFalse(six.showsButtonBackground)
        XCTAssertFalse(ten.showsButtonBackground)
        XCTAssertFalse(six.scrolls)
        XCTAssertFalse(ten.scrolls)
        XCTAssertGreaterThan(six.dotSize, ten.dotSize)
        XCTAssertLessThanOrEqual(ten.itemWidth * 10, 132)
    }

    func testEleventhSpaceScrollsWithoutShrinkingFurther() {
        let ten = SpaceStripLayout(count: 10, availableWidth: 132)
        let eleven = SpaceStripLayout(count: 11, availableWidth: 132)
        XCTAssertTrue(eleven.scrolls)
        XCTAssertEqual(eleven.dotSize, ten.dotSize)
        XCTAssertEqual(eleven.itemWidth, ten.itemWidth)
        XCTAssertGreaterThan(eleven.itemWidth * 11, 132)
    }

    func testNarrowSidebarAllowsOverflowRatherThanOverlappingIcons() {
        let layout = SpaceStripLayout(count: 10, availableWidth: 68)
        XCTAssertTrue(layout.scrolls)
        XCTAssertGreaterThanOrEqual(layout.itemWidth, layout.iconSize + 2)
    }

    func testEmptyStripHasFiniteDimensions() {
        let layout = SpaceStripLayout(count: 0, availableWidth: 0)
        XCTAssertTrue(layout.itemWidth.isFinite)
        XCTAssertFalse(layout.scrolls)
    }
}

@MainActor final class SpaceStripViewportTests: XCTestCase {
    func testOverflowCreatesScrollableNativeContent() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = manager.active.id
        let previous = manager.spaces(for: profile)
        let spaces = (1...12).map { Space(name: "Space \($0)", profileID: profile) }
        XCTAssertTrue(manager.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 212, height: 28),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BottomRow(downloadsHover: DownloadsHover(),
            hasPreviewItems: false, preparePreview: { false })
            .environmentObject(store).environmentObject(store.spaceGesture)
            .environmentObject(DownloadFeedback()))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            XCTAssertTrue(manager.saveSpaces(previous, for: profile))
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.width, scroll.contentSize.width,
                             "Twelve dots must create actual scrollable content, not draw beyond a fixed viewport")
        let before = scroll.contentView.bounds.minX
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, before)
        XCTAssertNotNil(store.spaceGesture.scrollingFooter)
    }
}
