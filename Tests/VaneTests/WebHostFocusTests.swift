import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WebHostFocusTests: XCTestCase {
    private final class Page: WKWebView {
        var willHide: (() -> Void)?
        override var isHidden: Bool {
            get { super.isHidden }
            set {
                if newValue && !super.isHidden { willHide?() }
                super.isHidden = newValue
            }
        }
    }

    func testPageRelinquishesFocusBeforeItIsHidden() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let outgoing = Page(frame: .zero, configuration: configuration)
        let incoming = Page(frame: .zero, configuration: configuration)
        let host = WebHost(outgoing)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { host.removePage(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(outgoing))
        var hidden = false
        outgoing.willHide = {
            hidden = true
            XCTAssertFalse(window.firstResponder === outgoing,
                           "Hiding the focused page must not trigger AppKit's key-view search through SwiftUI")
        }
        host.show(incoming, keeping: [outgoing, incoming])
        XCTAssertTrue(hidden)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(window.firstResponder === incoming)
    }
}
