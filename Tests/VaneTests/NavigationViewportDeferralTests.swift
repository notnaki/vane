import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class NavigationViewportDeferralTests: XCTestCase {
    private final class Page: WKWebView {
        var widthChanges = 0
        override func setFrameSize(_ newSize: NSSize) {
            if abs(newSize.width - frame.width) > 0.01 { widthChanges += 1 }
            super.setFrameSize(newSize)
        }
    }

    private func fixture() -> (WebHost, Page, NSWindow) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let page = Page(frame: .zero, configuration: config)
        let host = WebHost(page)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        host.frame = NSRect(x: 200, y: 0, width: 700, height: 600)
        root.addSubview(host)
        addTeardownBlock { @MainActor in
            host.removePage()
            window.contentView = nil
            window.close()
        }
        page.widthChanges = 0
        return (host, page, window)
    }

    private func intent(open: Bool = false, shown: Bool = true, tracking: Bool = false) -> NavigationViewportIntent {
        NavigationViewportIntent(libraryOpen: open, sidebarShown: shown, sidebarWidth: 200,
                                 panelWidth: 400, tracking: tracking)
    }

    func testProgrammaticTravelResizesTheRealPageOnceAtRest() async throws {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        for width in stride(from: 680, through: 500, by: -20) {
            host.setFrameSize(NSSize(width: CGFloat(width), height: 600))
            XCTAssertEqual(page.frame.width, 700)
            XCTAssertTrue(host.web === page)
            XCTAssertTrue(page.superview === host)
        }
        XCTAssertEqual(page.widthChanges, 0)
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(page.frame.width, 500)
        XCTAssertEqual(page.widthChanges, 1)
        print("RENDER_VIEWPORT host_width_samples=10 web_width_changes=\(page.widthChanges)")
        XCTAssertTrue(page.autoresizingMask.contains(.width))
    }

    func testGrowingReversalImmediatelyReleasesTheOlderSettlement() async throws {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 600, height: 600))
        try await Task.sleep(for: .milliseconds(150))
        host.prepareNavigationViewport(intent(), animated: true, reduced: false)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        host.setFrameSize(NSSize(width: 650, height: 600))
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(page.frame.width, 650, "A growing reversal must fill the live host immediately")
        host.setFrameSize(NSSize(width: 700, height: 600))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(page.frame.width, 700)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        XCTAssertGreaterThan(page.widthChanges, 0)
    }

    func testGrowingIntentsNeverFreezeAnUndersizedPage() {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(open: true), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 750, height: 600))
        XCTAssertEqual(page.frame.width, 750)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        host.prepareNavigationViewport(intent(shown: false), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 850, height: 600))
        XCTAssertEqual(page.frame.width, 850)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
    }

    func testPanelWidthChangesUseEffectiveLeadingWidthRatherThanOnlyOpenState() async throws {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(open: true), animated: false, reduced: false)
        let narrowerPanel = NavigationViewportIntent(libraryOpen: true, sidebarShown: true,
            sidebarWidth: 200, panelWidth: 300, tracking: false)
        host.prepareNavigationViewport(narrowerPanel, animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertEqual(page.frame.width, 800, "A narrower panel grows the page live")
        let widerPanel = NavigationViewportIntent(libraryOpen: true, sidebarShown: true,
            sidebarWidth: 200, panelWidth: 500, tracking: false)
        host.prepareNavigationViewport(widerPanel, animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 600, height: 600))
        XCTAssertEqual(page.frame.width, 800, "A wider panel may defer the shrinking viewport")
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(page.frame.width, 600)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
    }

    func testMotionPolicyChangeImmediatelyReleasesTheViewport() {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 550, height: 600))
        host.prepareNavigationViewport(intent(open: true), animated: false, reduced: true)
        XCTAssertEqual(page.frame.width, 550)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        host.setFrameSize(NSSize(width: 500, height: 600))
        XCTAssertEqual(page.frame.width, 500)
    }

    func testWindowResizeCancelsDeferralAndKeepsHeightLive() {
        let (host, page, window) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 600, height: 550))
        XCTAssertEqual(page.frame.height, 550)
        XCTAssertEqual(page.frame.width, 700)
        window.setContentSize(NSSize(width: 1000, height: 650))
        host.setFrameSize(NSSize(width: 650, height: 600))
        XCTAssertEqual(page.frame.width, 650)
        XCTAssertEqual(page.frame.height, 600)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
    }

    func testPageReplacementAndRemovalReleaseTheFrozenAutoresizingMask() {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 550, height: 600))
        let incoming = WKWebView(frame: .zero, configuration: page.configuration)
        host.show(incoming, keeping: [page, incoming])
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        XCTAssertTrue(host.web === incoming)
        XCTAssertEqual(incoming.frame.width, 550)
        host.prepareNavigationViewport(intent(), animated: true, reduced: false)
        host.removePage()
        XCTAssertTrue(incoming.autoresizingMask.contains(.width))
        XCTAssertNil(host.web)
        XCTAssertNil(page.superview)
        XCTAssertNil(incoming.superview)
    }

    func testInspectorAttachingDuringTravelImmediatelyReleasesWidthOwnership() async throws {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 550, height: 600))
        let inspector = NSView(frame: .zero)
        host.addSubview(inspector)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        XCTAssertEqual(page.frame.width, 550)
        // Stand in for WebKit's docked geometry after attachment. The old tail
        // must not overwrite geometry now owned by the inspector.
        page.setFrameSize(NSSize(width: 350, height: 600))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(page.frame.width, 350)
        inspector.removeFromSuperview()
    }

    func testGestureHandoffAndDisabledExperimentKeepImmediateNativeLayout() {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 550, height: 600))
        host.prepareNavigationViewport(intent(open: true, tracking: true), animated: false, reduced: false)
        XCTAssertTrue(page.autoresizingMask.contains(.width))
        XCTAssertEqual(page.frame.width, 550)
        host.prepareNavigationViewport(nil, animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 500, height: 600))
        XCTAssertEqual(page.frame.width, 500)
    }

    func testInspectorOrImmediateNavigationKeepsLegacyLayout() {
        let (host, page, _) = fixture()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        let inspector = NSView(frame: .zero)
        host.addSubview(inspector)
        host.prepareNavigationViewport(intent(open: true), animated: true, reduced: false)
        host.setFrameSize(NSSize(width: 550, height: 600))
        XCTAssertEqual(page.frame.width, 550)
        inspector.removeFromSuperview()
        host.prepareNavigationViewport(intent(), animated: false, reduced: false)
        host.setFrameSize(NSSize(width: 700, height: 600))
        XCTAssertEqual(page.frame.width, 700)
    }
}
