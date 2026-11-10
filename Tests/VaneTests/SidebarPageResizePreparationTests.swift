import AppKit
import WebKit
import XCTest
@testable import vane

/// Unshown native geometry only; no activation, loop, input, or capture.
@MainActor final class SidebarPageResizePreparationTests: XCTestCase {
    private func fixture() -> (NSWindow, WebHost, WKWebView) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let host = WebHost(web)
        let window = SidebarResizeModelWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.setFrameSize(NSSize(width: 600, height: 400))
        return (window, host, web)
    }

    private func retire(_ window: NSWindow, _ host: WebHost) {
        window.contentView = nil
        host.removePage()
        window.close()
    }

    func testExpandedPaintPrecedesSidebarPublicationAndNativeMaskRestoration() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        let child = try XCTUnwrap(web.subviews.first)
        let originalChild = child.frame
        let target = PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))
        var paint: (@MainActor @Sendable () -> Void)?
        var commits = 0
        let resize = SidebarPageResizePreparation(window: window, pages: [target],
            presenter: { _, completion in paint = completion }, deadline: { _ in }, isCurrent: { true }) {
                commits += 1
                XCTAssertEqual(child.frame.width, 817)
                XCTAssertEqual(web.autoresizingMask, [])
                host.setFrameSize(NSSize(width: 817, height: 400))
            }
        resize.start()
        XCTAssertTrue(resize.awaitingPaint)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(child.frame, originalChild)
        try XCTUnwrap(paint)()
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(web.frame.width, 817, "The parent must not apply its expansion a second time")
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertNil(host.pageLayoutDidResize)
        XCTAssertFalse(resize.awaitingPaint)
    }

    func testSecondToggleCancelsBeforePaintAndLateCallbackCannotCloseSidebar() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        var paint: (@MainActor @Sendable () -> Void)?
        var commits = 0
        let resize = SidebarPageResizePreparation(window: window,
            pages: [PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))],
            presenter: { _, completion in paint = completion }, deadline: { _ in }, isCurrent: { true }) { commits += 1 }
        resize.start()
        resize.cancel()
        try XCTUnwrap(paint)()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertNil(host.pageLayoutDidResize)
    }

    func testUnrelatedParentResizeInvalidatesPreparedClose() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        var paint: (@MainActor @Sendable () -> Void)?
        var commits = 0
        let resize = SidebarPageResizePreparation(window: window,
            pages: [PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))],
            presenter: { _, completion in paint = completion }, deadline: { _ in }, isCurrent: { true }) { commits += 1 }
        resize.start()
        host.setFrameSize(NSSize(width: 700, height: 400))
        try XCTUnwrap(paint)()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(web.frame.width, 700)
        XCTAssertNil(host.pageLayoutDidResize)
    }

    func testChangedPresentationOwnerCannotPublishThePreparedClose() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        var paint: (@MainActor @Sendable () -> Void)?
        let current = SidebarResizeCurrentOwner()
        var commits = 0
        let resize = SidebarPageResizePreparation(window: window,
            pages: [PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))],
            presenter: { _, completion in paint = completion }, deadline: { _ in }, isCurrent: { current.value }) { commits += 1 }
        resize.start()
        current.value = false
        try XCTUnwrap(paint)()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertNil(host.pageLayoutDidResize)
    }

    func testStalledPaintDoesNotDisableTheCommandOrLeaveNativeSizingFrozen() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        var paint: (@MainActor @Sendable () -> Void)?
        var timeout: (@MainActor @Sendable () -> Void)?
        var commits = 0
        let resize = SidebarPageResizePreparation(window: window,
            pages: [PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))],
            presenter: { _, completion in paint = completion }, deadline: { timeout = $0 }, isCurrent: { true }) {
                commits += 1
                host.setFrameSize(NSSize(width: 817, height: 400))
            }
        resize.start()
        try XCTUnwrap(timeout)()
        try XCTUnwrap(paint)()
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertNil(host.pageLayoutDidResize)
    }

    func testExpiredPaintDeadlineCannotReleaseTheFollowingSidebarAnimation() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        var paint: (@MainActor @Sendable () -> Void)?
        var deadlines: [@MainActor @Sendable () -> Void] = []
        let resize = SidebarPageResizePreparation(window: window,
            pages: [PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))],
            presenter: { _, completion in paint = completion }, deadline: { deadlines.append($0) }, isCurrent: { true }) {
                // Native SwiftUI frame interpolation is still partway through its slide.
                host.setFrameSize(NSSize(width: 750, height: 400))
            }
        resize.start()
        let oldPaintDeadline = try XCTUnwrap(deadlines.first)
        try XCTUnwrap(paint)()
        oldPaintDeadline()
        XCTAssertEqual(web.frame.width, 817, "The painted page must remain wide throughout the sidebar slide")
        XCTAssertEqual(web.autoresizingMask, [], "An old paint timer must not release the animation's native sizing")
        host.setFrameSize(NSSize(width: 817, height: 400))
        XCTAssertEqual(web.frame.width, 817)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertNil(host.pageLayoutDidResize)
    }

    func testSplitCloseWaitsForBothPaintsAndBothParentLayouts() throws {
        let (window, first, web) = fixture()
        defer { retire(window, first) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let secondWeb = WKWebView(frame: .zero, configuration: configuration)
        let second = WebHost(secondWeb)
        defer { second.removePage() }
        first.addSubview(second)
        second.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        second.autoresizingMask = []
        var paints: [@MainActor @Sendable () -> Void] = []
        var commits = 0
        let resize = SidebarPageResizePreparation(window: window, pages: [
            PreparedPageResize(web: web, size: NSSize(width: 817, height: 400)),
            PreparedPageResize(web: secondWeb, size: NSSize(width: 408.5, height: 400))],
            presenter: { _, completion in paints.append(completion) }, deadline: { _ in }, isCurrent: { true }) {
                commits += 1
                first.setFrameSize(NSSize(width: 817, height: 400))
            }
        resize.start()
        XCTAssertEqual(paints.count, 2)
        paints[0]()
        XCTAssertEqual(commits, 0)
        paints[1]()
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(secondWeb.autoresizingMask, [], "The second split still needs its new native parent layout")
        second.setFrameSize(NSSize(width: 408.5, height: 400))
        XCTAssertEqual(secondWeb.frame.width, 408.5)
        XCTAssertEqual(secondWeb.autoresizingMask, [.width, .height])
        XCTAssertNil(first.pageLayoutDidResize)
        XCTAssertNil(second.pageLayoutDidResize)
    }

    func testNearEndpointDoesNotApplyTheRemainingParentDeltaTwice() throws {
        let (window, host, web) = fixture()
        defer { retire(window, host) }
        var paint: (@MainActor @Sendable () -> Void)?
        let resize = SidebarPageResizePreparation(window: window,
            pages: [PreparedPageResize(web: web, size: NSSize(width: 817, height: 400))],
            presenter: { _, completion in paint = completion }, deadline: { _ in }, isCurrent: { true }) {
                host.setFrameSize(NSSize(width: 816.5, height: 400))
            }
        resize.start()
        try XCTUnwrap(paint)()
        XCTAssertEqual(web.autoresizingMask, [], "Half a point of native interpolation remains")
        host.setFrameSize(NSSize(width: 817, height: 400))
        XCTAssertEqual(web.frame.width, host.bounds.width, accuracy: 0.001)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
    }
}

private final class SidebarResizeModelWindow: NSWindow {
    override var isVisible: Bool { true }
}

@MainActor private final class SidebarResizeCurrentOwner { var value = true }
