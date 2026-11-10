import AppKit
import WebKit
import XCTest
@testable import vane

/// Native sizing only: no window, focus, input, or capture is needed.
@MainActor final class WindowResizePreparationTests: XCTestCase {
    private func fixture() -> (WebHost, WKWebView) {
        TestEnvironment.prepare()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let host = WebHost(web)
        host.setFrameSize(NSSize(width: 600, height: 400))
        return (host, web)
    }

    func testPreparationPreservesNativeChildGeometryUntilCommit() throws {
        let (host, web) = fixture()
        defer { host.removePage() }
        let child = try XCTUnwrap(web.subviews.first)
        let original = child.frame
        let prepared = PreparedPageResize(web: web, size: NSSize(width: 800, height: 500))
        prepared.prepare()
        XCTAssertEqual(web.frame.size, NSSize(width: 800, height: 500))
        XCTAssertEqual(child.frame, original, "Do not clip old pixels ahead of the new paint")
        XCTAssertFalse(web.autoresizesSubviews)
        prepared.restore(committed: true)
        XCTAssertEqual(child.frame.size, NSSize(width: 800, height: 500))
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        prepared.restore(committed: true)
        XCTAssertEqual(child.frame.size, NSSize(width: 800, height: 500), "Cleanup must not apply the delta twice")
    }

    func testCancellationRestoresCurrentParentGeometry() {
        let (host, web) = fixture()
        defer { host.removePage() }
        let prepared = PreparedPageResize(web: web, size: NSSize(width: 800, height: 500))
        prepared.prepare()
        host.setFrameSize(NSSize(width: 700, height: 450))
        XCTAssertFalse(prepared.stillOwned, "A changed layout invalidates the prepared viewport")
        prepared.restore(committed: false)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
    }

    func testReparentingDoesNotRestoreThePreviousHostsFrameOrMask() {
        let (oldHost, web) = fixture()
        let nextHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
        defer { oldHost.removePage(); web.removeFromSuperview() }
        let prepared = PreparedPageResize(web: web, size: NSSize(width: 800, height: 500))
        prepared.prepare()
        web.removeFromSuperview()
        nextHost.addSubview(web)
        web.frame = nextHost.bounds
        web.autoresizingMask = [.height]
        prepared.restore(committed: false)
        XCTAssertEqual(web.frame, nextHost.bounds)
        XCTAssertEqual(web.autoresizingMask, [.height])
        XCTAssertTrue(web.autoresizesSubviews)
    }
}
