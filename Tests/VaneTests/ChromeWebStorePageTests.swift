import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ChromeWebStorePageTests: XCTestCase {
    private let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    func testInstallMessagesRequireCurrentMainFrameStoreDocument() throws {
        let url = URL(string: "https://chromewebstore.google.com/detail/dark-reader/\(id)")!
        XCTAssertNotNil(ChromeWebStorePage.authorizedSource(id: id, frameURL: url, currentURL: url, mainFrame: true, privateTab: false))
        XCTAssertNil(ChromeWebStorePage.authorizedSource(id: id, frameURL: url, currentURL: url, mainFrame: false, privateTab: false))
        XCTAssertNil(ChromeWebStorePage.authorizedSource(id: id, frameURL: url, currentURL: url, mainFrame: true, privateTab: true))
        XCTAssertNil(ChromeWebStorePage.authorizedSource(id: String(repeating: "a", count: 32), frameURL: url, currentURL: url, mainFrame: true, privateTab: false))
        XCTAssertNil(ChromeWebStorePage.authorizedSource(id: id, frameURL: url, currentURL: URL(string: "https://evil.test"), mainFrame: true, privateTab: false))
    }

    func testButtonReplacementDoesNotAllowScriptedInstallationAndHandlesSPAChanges() async throws {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        let messages = Messages()
        config.userContentController.add(messages, contentWorld: ChromeWebStorePage.world, name: ChromeWebStorePage.messageName)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: ChromeWebStorePage.messageName, contentWorld: ChromeWebStorePage.world) }
        let url = URL(string: "https://chromewebstore.google.com/detail/dark-reader/\(id)")!
        web.loadHTMLString("<html><head><title>Store fixture</title></head><body><button jsname='wQO0od'>Add to Chrome</button></body></html>", baseURL: url)
        let deadline = ContinuousClock.now + .seconds(5)
        while web.isLoading || web.title != "Store fixture" {
            guard ContinuousClock.now < deadline else { XCTFail("Store fixture did not load"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await web.evaluateJavaScript(ChromeWebStorePage.script, in: nil, in: ChromeWebStorePage.world)
        let label = try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]')?.textContent")
        XCTAssertEqual(label as? String, "Add to Vane")
        try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]').click()")
        XCTAssertEqual(messages.count, 0)
        try await web.evaluateJavaScript("history.pushState({}, '', '/category/extensions'); document.body.append(document.createElement('div'))")
        // MutationObserver and its microtask settle before the next WebKit evaluation.
        let removed = try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]') === null")
        XCTAssertEqual(removed as? Bool, true)
        let originalVisible = try await web.evaluateJavaScript("!document.querySelector('[jsname=wQO0od]').hidden")
        XCTAssertEqual(originalVisible as? Bool, true)
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        var count = 0
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { count += 1 }
    }
}
