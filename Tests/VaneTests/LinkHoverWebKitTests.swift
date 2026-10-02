import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class LinkHoverWebKitTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [Any] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            messages.append(message.body)
        }
    }

    private func script(_ source: String, handler: String) async throws -> (WKWebView, Capture) {
        let capture = Capture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(capture, name: handler)
        config.userContentController.addUserScript(WKUserScript(source: source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.loadHTMLString("<a id='link' href='https://example.com/article'><span id='child'>Read</span></a>", baseURL: nil)
        try await wait { !web.isLoading }
        try await js(web, "if (!document.getElementById('link')) throw new Error('fixture not ready');")
        addTeardownBlock { @MainActor in
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: handler)
        }
        return (web, capture)
    }

    private func js(_ web: WKWebView, _ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            web.evaluateJavaScript(source) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition() {
            if Date.now >= deadline { throw NSError(domain: "LinkHoverFixtureTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStatusScriptTracksTargetsAndClearsOnScrollAndClick() async throws {
        let (web, capture) = try await script(StatusBar.script, handler: StatusBar.messageName)
        try await js(web, "document.getElementById('child').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[0]), .init(url: "https://example.com/article", target: .main))
        try await js(web, "document.getElementById('link').target='_blank'; document.getElementById('child').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 2 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[1])?.target, .newWindow)
        try await js(web, "window.dispatchEvent(new Event('scroll'));")
        try await wait { capture.messages.count == 3 }
        XCTAssertNil(StatusBar.hover(from: capture.messages[2]))
        try await js(web, "document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true})); document.dispatchEvent(new MouseEvent('mousedown', {bubbles:true}));")
        try await wait { capture.messages.count == 5 }
        XCTAssertNil(StatusBar.hover(from: capture.messages[4]))
    }

    func testNamedPopupAndExistingFrameHaveDifferentHoverTargets() async throws {
        let (web, capture) = try await script(StatusBar.script, handler: StatusBar.messageName)
        try await js(web, "document.getElementById('link').target='details'; document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[0])?.target, .newWindow)
        try await js(web, "var frame=document.createElement('iframe'); frame.name='details'; document.body.appendChild(frame); document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 2 }
        XCTAssertEqual(StatusBar.hover(from: capture.messages[1])?.target, .subframe)
    }

    func testShiftHeldBeforeHoverPreviewsImmediatelyAndCommandCancelsIt() async throws {
        let (web, capture) = try await script(Previews.script, handler: Previews.messageName)
        try await js(web, "document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true, shiftKey:true}));")
        try await wait { !capture.messages.isEmpty }
        XCTAssertEqual((capture.messages.first as? [String: Any])?["shift"] as? Bool, true)
        try await js(web, "document.dispatchEvent(new KeyboardEvent('keydown', {key:'Meta', metaKey:true, shiftKey:true, bubbles:true}));")
        try await wait { capture.messages.count == 2 }
        XCTAssertEqual((capture.messages.last as? [String: Any])?["gone"] as? Bool, true)
        try await js(web, "document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true, metaKey:true, shiftKey:true}));")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(capture.messages.count, 2, "Command-Shift must show an opening hint without starting a preview")
    }
}
