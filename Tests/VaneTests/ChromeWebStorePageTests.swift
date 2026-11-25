import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ChromeWebStorePageTests: XCTestCase {
    private let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    func testInstallConsentRequiresItsTabToRemainActive() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared, policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        // Key-window state exists only while a real AppKit loop is admitted.
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        let profile = UUID()
        var failure: (any Error)?
        do {
            let store = TabStore(profileID: profile, session: [])
            let tab = store.newBlankTab(focus: false)
            store.current = tab.id
            let web = tab.web
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.makeKeyAndOrderFront(nil)
            defer {
                store.tabs.forEach { $0.tearDown() }
                TabStore.all.removeAll { $0 === store }
                window.close()
            }
            let document = URL(string: "https://chromewebstore.google.com/detail/fixture/\(id)")!
            web.loadHTMLString("<title>Consent owner fixture</title>", baseURL: document)
            try await compatibilityWait {
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                return window.isKeyWindow && web.title == "Consent owner fixture" && !web.isLoading
            }
            XCTAssertTrue(ChromeWebStorePage.canReview(tab: tab, web: web, document: web.url))
            _ = store.newBlankTab()
            XCTAssertFalse(ChromeWebStorePage.canReview(tab: tab, web: web, document: web.url))
        } catch { failure = error }
        try await NativeFixtureProfileCleanup.release([profile])
        try await loop.close()
        if let failure { throw failure }
    }

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
        // The store's markup in Turkish: its button found by its place, not its English label.
        web.loadHTMLString("<html><head><title>Store fixture</title></head><body><div jsaction='JIbuQc:IkY2J(wQO0od)'><button disabled>Chrome'a ekle</button></div></body></html>", baseURL: url)
        let deadline = ContinuousClock.now + .seconds(5)
        while web.isLoading || web.title != "Store fixture" {
            guard ContinuousClock.now < deadline else { XCTFail("Store fixture did not load"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        web.evaluateJavaScript(ChromeWebStorePage.script, in: nil, in: ChromeWebStorePage.world, completionHandler: nil)
        let label = try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]')?.textContent")
        XCTAssertEqual(label as? String, "Add to Vane")
        // In the store's place, never floating over the page.
        let placed = try await web.evaluateJavaScript("""
            const ours = document.querySelector('[data-vane-store-install]');
            ours.nextElementSibling.hidden && ours.style.position === '' && ours.parentElement.matches('[jsaction]')
            """)
        XCTAssertEqual(placed as? Bool, true)
        try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]').click()")
        XCTAssertEqual(messages.count, 0)
        try await web.evaluateJavaScript("history.pushState({}, '', '/category/extensions'); document.body.append(document.createElement('div'))")
        // MutationObserver and its microtask settle before the next WebKit evaluation.
        let removed = try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]') === null")
        XCTAssertEqual(removed as? Bool, true)
        let originalVisible = try await web.evaluateJavaScript("!document.querySelector('[jsaction] button').hidden")
        XCTAssertEqual(originalVisible as? Bool, true)
    }

    func testNoStoreButtonMeansNothingFloatsOverThePage() async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: WKWebViewConfiguration())
        defer { web.stopLoading() }
        let url = URL(string: "https://chromewebstore.google.com/detail/dark-reader/\(id)")!
        web.loadHTMLString("<html><head><title>Store fixture</title></head><body><p>Loading</p></body></html>", baseURL: url)
        let deadline = ContinuousClock.now + .seconds(5)
        while web.isLoading || web.title != "Store fixture" {
            guard ContinuousClock.now < deadline else { XCTFail("Store fixture did not load"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        web.evaluateJavaScript(ChromeWebStorePage.script, in: nil, in: ChromeWebStorePage.world, completionHandler: nil)
        let none = try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]') === null")
        XCTAssertEqual(none as? Bool, true)
        // The store renders its button later; the observer puts ours in its place.
        try await web.evaluateJavaScript("document.body.innerHTML = \"<div jsaction='x:IkY2J(wQO0od)'><button>Add to Chrome</button></div>\"")
        let placed = try await web.evaluateJavaScript("document.querySelector('[data-vane-store-install]')?.parentElement?.matches('[jsaction]') === true")
        XCTAssertEqual(placed as? Bool, true)
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        var count = 0
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { count += 1 }
    }
}
