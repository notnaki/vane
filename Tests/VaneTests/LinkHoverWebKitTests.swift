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

    private func script(_ source: String, handler: String, baseURL: URL? = nil) async throws -> (WKWebView, Capture) {
        let capture = Capture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(capture, name: handler)
        config.userContentController.addUserScript(WKUserScript(source: source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.loadHTMLString("<a id='link' href='https://example.com/article'><span id='child'>Read</span></a>", baseURL: baseURL)
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

    func testOrdinaryNavigationNeverRequestsPreviewWithoutShift() async throws {
        for page in ["https://github.com/notnaki/vane", "https://example.com/article"] {
            let (web, capture) = try await script(Previews.script, handler: Previews.messageName,
                                                 baseURL: URL(string: page))
            try await js(web, "document.getElementById('child').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(capture.messages.isEmpty, "Ordinary navigation must cause no preview work: \(page)")
        }
    }

    func testSearchResultPreviewsButSearchNavigationDoesNot() async throws {
        let (web, capture) = try await script(Previews.script, handler: Previews.messageName,
                                             baseURL: URL(string: "https://www.google.com/search?q=vane"))
        try await js(web, "document.getElementById('link').innerHTML='<h3 id=heading>Result</h3>'; document.getElementById('heading').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        XCTAssertEqual((capture.messages.first as? [String: Any])?["shift"] as? Bool, false)
        try await js(web, "window.dispatchEvent(new Event('scroll')); document.getElementById('link').innerHTML='Next'; document.getElementById('link').href='https://www.google.com/search?q=vane&start=10'; document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(capture.messages.count, 2, "Search pagination must not start another preview")
    }

    func testHackerNewsOnlyPreviewsStoryHeadlines() async throws {
        let (web, capture) = try await script(Previews.script, handler: Previews.messageName,
                                             baseURL: URL(string: "https://news.ycombinator.com/"))
        try await js(web, "var a=document.getElementById('link'); var title=document.createElement('span'); title.className='titleline'; a.replaceWith(title); title.appendChild(a); a.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        try await js(web, "window.dispatchEvent(new Event('scroll')); var a=document.getElementById('link'); a.href='https://news.ycombinator.com/item?id=1'; a.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(capture.messages.count, 2, "Comments and site navigation must stay quiet")
    }

    func testOtherSupportedDiscoverySurfacesAndWrappedDestinations() async throws {
        let cases: [(String, String, String)] = [
            ("https://duckduckgo.com/?q=vane", "<a id=link data-testid=result-title-a href='https://example.com/article'>Result</a>", "https://example.com/article"),
            ("https://www.bing.com/search?q=vane", "<div class=b_algo><h2><a id=link href='https://www.bing.com/ck/a?u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9hcnRpY2xl'>Result</a></h2></div>", "https://example.com/article"),
            ("https://www.google.com/search?q=vane", "<a id=link href='https://www.google.com/url?q=https%3A%2F%2Fexample.com%2Farticle'><h3>Result</h3></a>", "https://example.com/article"),
            ("https://x.com/home", "<div data-testid=tweetText><a id=link role=link target=_blank href='https://t.co/article'>Article</a></div>", "https://t.co/article"),
            ("https://www.threads.net/", "<a id=link role=link rel='nofollow noreferrer' target=_blank href='https://example.com/article'>Article</a>", "https://example.com/article")
        ]
        for (page, markup, destination) in cases {
            let (web, capture) = try await script(Previews.script, handler: Previews.messageName, baseURL: URL(string: page))
            try await js(web, "document.body.innerHTML=\(String(data: try JSONEncoder().encode(markup), encoding: .utf8)!); document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));")
            try await wait { !capture.messages.isEmpty }
            XCTAssertEqual((capture.messages.first as? [String: Any])?["url"] as? String, destination, page)
        }
    }

    func testStationaryShiftRequestsAndReleasingItDismissesAnOrdinaryLink() async throws {
        let (web, capture) = try await script(Previews.script, handler: Previews.messageName)
        try await js(web, "document.getElementById('link').dispatchEvent(new MouseEvent('mouseover', {bubbles:true})); document.dispatchEvent(new KeyboardEvent('keydown', {key:'Shift', shiftKey:true, bubbles:true}));")
        try await wait { capture.messages.count == 1 }
        try await js(web, "document.dispatchEvent(new KeyboardEvent('keyup', {key:'Shift', bubbles:true}));")
        try await wait { capture.messages.count == 2 }
        XCTAssertEqual((capture.messages.last as? [String: Any])?["gone"] as? Bool, true)
    }

    func testDownloadsAndSameDocumentLinksStayQuietEvenWithShift() async throws {
        let (web, capture) = try await script(Previews.script, handler: Previews.messageName, baseURL: URL(string: "https://example.com/article"))
        try await js(web, "var a=document.getElementById('link'); a.href='#section'; a.dispatchEvent(new MouseEvent('mouseover', {bubbles:true,shiftKey:true})); a.href='https://example.com/file.zip'; a.download='file.zip'; a.dispatchEvent(new MouseEvent('mouseover', {bubbles:true,shiftKey:true}));")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(capture.messages.isEmpty)
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
