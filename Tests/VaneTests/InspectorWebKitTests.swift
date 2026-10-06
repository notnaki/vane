import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class InspectorWebKitTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while !condition() {
            if Date.now >= deadline { throw NSError(domain: "InspectorFixtureTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testPageUpdatesKeepAttachedInspectorAndElementSelectionAlive() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let keys = ["InspectorAttachmentSide", "InspectorAttachedWidth", "InspectorAttachedHeight", "InspectorStartsAttached"]
            .map { "__WebInspectorPageGroupLevel1__.WebKit2" + $0 }
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        Inspector.configure()
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web.isInspectable = true
        let host = WebHost(web)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        web.loadHTMLString("<h1 id='target'>Inspect this</h1>", baseURL: nil)
        try await wait { !web.isLoading }
        let inspector = try XCTUnwrap(web.perform(Selector(("_inspector")))?.takeUnretainedValue())
        addTeardownBlock { @MainActor in
            _ = inspector.perform(NSSelectorFromString("hide"))
            web.stopLoading()
            window.close()
        }
        Inspector.show(web)
        try await wait { inspector.value(forKey: "visible") as? Bool == true }
        let frontend = try XCTUnwrap(inspector.value(forKey: "inspectorWebView") as? WKWebView)
        try await wait { frontend.superview === host }
        _ = inspector.perform(Selector(("toggleElementSelection")))
        try await wait { inspector.value(forKey: "elementSelectionActive") as? Bool == true }

        XCTAssertLessThanOrEqual(frontend.frame.width, 600, "The initial panel should leave at least half this window for the page")

        // Hover/status and other published page state repeatedly update the representable.
        host.show(web, keeping: [web])
        XCTAssertTrue(frontend.superview === host, "A page update must not prune WebKit's inspector as a closed tab")
        XCTAssertFalse(frontend.isHidden)
        XCTAssertTrue(inspector.value(forKey: "elementSelectionActive") as? Bool == true)

        let other = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        host.show(other, keeping: [web, other])
        try await wait { inspector.value(forKey: "elementSelectionActive") as? Bool == false }
        XCTAssertNil(frontend.superview, "A docked inspector must not linger over another tab")
        XCTAssertTrue(web.isHidden)
        XCTAssertEqual(other.frame, host.bounds)
        host.show(web, keeping: [web, other])
        Inspector.show(web)
        try await wait { frontend.superview === host }
        host.removePage()
        XCTAssertNil(frontend.superview, "Removing pages also removes their docked inspectors")
        XCTAssertNil(web.superview)
        XCTAssertNil(other.superview)
    }
}
