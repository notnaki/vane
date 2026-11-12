import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class HTTPSOnlySecurityTests: XCTestCase {
    private var loop: NativeFixtureApplicationLoop?
    private func withApplicationLoop(_ body: () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        var failure: (any Error)?
        do {
            loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
            try await body()
        } catch { failure = error }
        if let loop {
            do { try await loop.close() } catch { if failure == nil { failure = error } }
        }
        loop = nil
        NSApp.setActivationPolicy(policy)
        if let failure { throw failure }
    }

    private func admit(_ window: NSWindow, web: WKWebView) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await compatibilityWait {
            try self.loop?.isReadyForInteraction() == true && window.isKeyWindow && NSApp.isActive
                && NativeFixtureMountAdmission.surfaceReady(web, in: window)
        }
    }
    func testForgedMainFrameSentinelCannotAskForAnException() throws {
        let target = URL(string: "http://plain.example/private")!
        let sentinel = try XCTUnwrap(HTTPSOnly.sentinel(for: target))
        XCTAssertEqual(HTTPSOnly.decide(url: sentinel, isMainFrame: true), .deny)
    }

    func testForgedSubframeSentinelCannotAskForAnException() throws {
        let target = URL(string: "http://plain.example/private")!
        let sentinel = try XCTUnwrap(HTTPSOnly.sentinel(for: target))
        XCTAssertEqual(HTTPSOnly.decide(url: sentinel, isMainFrame: false), .deny)
    }
    private let target = URL(string: "http://plain.example/private")!

    private func link(in presentation: HTTPSOnly.Continuation.Presentation) throws -> URL {
        let expression = try NSRegularExpression(pattern: #"href="(x-vane-insecure:[^"]+)""#)
        let range = NSRange(presentation.html.startIndex..., in: presentation.html)
        let match = try XCTUnwrap(expression.firstMatch(in: presentation.html, range: range))
        let capture = try XCTUnwrap(Range(match.range(at: 1), in: presentation.html))
        return try XCTUnwrap(URL(string: String(presentation.html[capture])))
    }

    func testPresentationPassRequiresNativeTokenAndBelongsToOneTab() {
        let first = HTTPSOnly.Continuation(), second = HTTPSOnly.Continuation()
        let page = first.prepare(for: target)
        XCTAssertFalse(first.consumePresentationLoad(request: URLRequest(url: target), isMainFrame: true))
        XCTAssertFalse(second.consumePresentationLoad(request: page.request, isMainFrame: true))
        XCTAssertFalse(first.consumePresentationLoad(request: page.request, isMainFrame: false))
        XCTAssertTrue(first.consumePresentationLoad(request: page.request, isMainFrame: true))
        XCTAssertFalse(first.consumePresentationLoad(request: page.request, isMainFrame: true))
    }

    func testContinuationRequiresCommittedMainFrameAndConsumesNonce() throws {
        let state = HTTPSOnly.Continuation()
        let page = state.prepare(for: target), navigation = NSObject()
        let url = try link(in: page)
        state.expectNavigation(navigation)
        XCTAssertNil(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: true,
                                     sourceURL: target, documentURL: target))
        state.navigationStarted(navigation)
        state.navigationCommitted(navigation, documentURL: target)
        XCTAssertNil(state.authorize(url: url, isMainFrame: false, sourceIsMainFrame: true,
                                     sourceURL: target, documentURL: target))
        XCTAssertNil(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: false,
                                     sourceURL: target, documentURL: target))
        XCTAssertNil(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: true,
                                     sourceURL: URL(string: "http://other.example/"), documentURL: target))
        XCTAssertNil(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: true,
                                     sourceURL: target, documentURL: URL(string: "http://other.example/")))
        XCTAssertEqual(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: true,
                                       sourceURL: target, documentURL: target), target)
        XCTAssertNil(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: true,
                                     sourceURL: target, documentURL: target))
    }

    func testNonceCannotCrossTabsOrSurviveAnotherNavigation() throws {
        let first = HTTPSOnly.Continuation(), second = HTTPSOnly.Continuation()
        let firstPage = first.prepare(for: target), secondPage = second.prepare(for: target)
        let navigation = NSObject()
        first.expectNavigation(navigation)
        first.navigationStarted(navigation)
        first.navigationCommitted(navigation, documentURL: target)
        XCTAssertNil(first.authorize(url: try link(in: secondPage), isMainFrame: true,
                                    sourceIsMainFrame: true, sourceURL: target, documentURL: target))
        first.navigationStarted(NSObject())
        XCTAssertNil(first.authorize(url: try link(in: firstPage), isMainFrame: true,
                                    sourceIsMainFrame: true, sourceURL: target, documentURL: target))
    }

    func testWrongCommitCannotActivateAnInterstitial() throws {
        let state = HTTPSOnly.Continuation()
        let page = state.prepare(for: target)
        state.expectNavigation(NSObject())
        state.navigationCommitted(NSObject(), documentURL: target)
        XCTAssertNil(state.authorize(url: try link(in: page), isMainFrame: true,
                                    sourceIsMainFrame: true, sourceURL: target, documentURL: target))
    }

    func testMalformedOrMissingNonceCannotAuthorizeCurrentInterstitial() throws {
        let state = HTTPSOnly.Continuation()
        _ = state.prepare(for: target)
        let navigation = NSObject()
        state.expectNavigation(navigation)
        state.navigationCommitted(navigation, documentURL: target)
        for raw in ["x-vane-insecure:", "x-vane-insecure:?nonce=", "x-vane-insecure:%%%"] {
            let url = try XCTUnwrap(URL(string: raw, encodingInvalidCharacters: true))
            XCTAssertNil(HTTPSOnly.insecureTarget(url))
            XCTAssertNil(state.authorize(url: url, isMainFrame: true, sourceIsMainFrame: true,
                                        sourceURL: target, documentURL: target))
        }
        XCTAssertNil(state.authorize(url: try XCTUnwrap(HTTPSOnly.sentinel(for: target)),
                                    isMainFrame: true, sourceIsMainFrame: true,
                                    sourceURL: target, documentURL: target))
    }

    @MainActor private final class InterstitialDelegate: NSObject, WKNavigationDelegate {
        let continuation = HTTPSOnly.Continuation()
        var committed = false
        var authorized: URL?
        var denied = false

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            switch HTTPSOnly.decide(navigationAction, continuation: continuation, documentURL: webView.url) {
            case .allow: decisionHandler(.allow)
            case .confirm(let target): authorized = target; decisionHandler(.cancel)
            case .deny: denied = true; decisionHandler(.cancel)
            case .upgrade, .block: denied = true; decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            continuation.navigationStarted(navigation)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            continuation.navigationCommitted(navigation, documentURL: webView.url)
            committed = true
        }
    }

    func testRealSimulatedInterstitialCanCommitAndAuthorizeItsMainFrameLink() async throws {
        try await withApplicationLoop {
            TestEnvironment.prepare()
            _ = NSApplication.shared
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
            let delegate = InterstitialDelegate()
            web.navigationDelegate = delegate
            let window = NSWindow(contentRect: web.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.contentView = web
            defer {
                web.stopLoading(); web.navigationDelegate = nil
                window.orderOut(nil); window.contentView = nil; window.close()
            }
            try await admit(window, web: web)
            let presentation = delegate.continuation.prepare(for: target)
            let navigation = web.loadSimulatedRequest(presentation.request, responseHTML: presentation.html)
            delegate.continuation.expectNavigation(try XCTUnwrap(navigation))
            let deadline = Date.now.addingTimeInterval(10)
            while !delegate.committed && !delegate.denied && Date.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(delegate.committed, "The native token-bearing simulated document must load")
            XCTAssertFalse(delegate.denied)
            guard delegate.committed else { return }
            _ = try await web.evaluateJavaScript("document.querySelector('a').click()")
            while delegate.authorized == nil && !delegate.denied && Date.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(delegate.authorized, target)
            XCTAssertFalse(delegate.denied)

        }
    }

    func testActualTabInterstitialOffersSheetAndDeclineCreatesNoException() async throws {
        try await withApplicationLoop {
            TestEnvironment.prepare()
            _ = NSApplication.shared
            let suite = "vane.https-security." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let originalDefaults = HTTPSOnly.defaults
            HTTPSOnly.defaults = defaults
            HTTPSOnly.enabled = true
            HTTPSOnly.forgetLoopState()
            defer {
                HTTPSOnly.defaults = originalDefaults
                HTTPSOnly.forgetLoopState()
                UserDefaults.dropScratchSuite(suite)
            }
            let tab = Tab(isPrivate: true, profileID: UUID())
            let web = tab.web
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.contentView = web
            defer {
                tab.tearDown()
                window.orderOut(nil); window.contentView = nil; window.close()
            }
            try await admit(window, web: web)
            // Seed a known failed upgrade without network traffic, then let the real Tab
            // policy create, commit and authorize its simulated document.
            XCTAssertEqual(HTTPSOnly.decide(url: target, isMainFrame: true, profileID: tab.profileID),
                           .upgrade(URL(string: "https://plain.example/private")!))
            tab.navigate(to: target)
            let deadline = Date.now.addingTimeInterval(10)
            while (tab.certificateDocumentURL != target || tab.loading || web.isLoading) && Date.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(tab.certificateDocumentURL, target)
            guard tab.certificateDocumentURL == target else { return }
            let href = try await web.evaluateJavaScript("document.querySelector('a')?.href") as? String
            XCTAssertTrue(href?.hasPrefix(HTTPSOnly.insecureScheme + ":") == true)
            guard href != nil else { return }
            _ = try await web.evaluateJavaScript("document.querySelector('a').click()")
            while window.attachedSheet == nil && Date.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let sheet = try XCTUnwrap(window.attachedSheet, "The real tab's current interstitial must offer the confirmation sheet")
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            try await compatibilityWait { window.attachedSheet == nil && !sheet.isVisible }
            XCTAssertFalse(HTTPSOnly.isExcepted(host: "plain.example", profileID: tab.profileID))

        }
    }

}
