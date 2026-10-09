import AppKit
import WebKit
import XCTest
@testable import vane

/// Real WebKit plus deterministic replay of callbacks retained from actual loads.
@MainActor final class NavigationWebKitTests: XCTestCase {
    var server: NavigationHTTPFixture!
    var tab: Tab!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        tab = Tab(popup: config, isPrivate: false, profileID: UUID())
    }

    override func tearDown() async throws {
        tab.tearDown()
        tab = nil
        server.stop()
        server = nil
    }

    @discardableResult func load(_ path: String) async throws -> WKNavigation {
        let navigation = try XCTUnwrap(tab.web.load(URLRequest(url: try server.url(path))))
        try await compatibilityWait { self.tab.web.url == (try self.server.url(path)) && !self.tab.loading && !self.tab.web.isLoading }
        return navigation
    }

    func testSupersededCancellationCannotStopCurrentLoad() async throws {
        let old = try await load("/old")
        let current = try XCTUnwrap(tab.web.load(URLRequest(url: try server.url("/new"))))
        // Replay with real identities so the ordering is deterministic rather than timed.
        tab.webView(tab.web, didStartProvisionalNavigation: current)
        tab.webView(tab.web, didFailProvisionalNavigation: old, withError: URLError(.cancelled))
        XCTAssertTrue(tab.loading, "Old cancellation must not stop the current spinner")
    }

    func testRetiredViewCallbacksCannotMutateClosedTabOrRecreateWebView() async throws {
        let navigation = try await load("/old")
        let retired = tab.web
        tab.tearDown()
        tab.loading = false
        tab.progress = 0.3
        tab.webView(retired, didStartProvisionalNavigation: navigation)
        XCTAssertFalse(tab.loading)
        tab.webView(retired, didFinish: navigation)
        XCTAssertEqual(tab.progress, 0.3)
        tab.webView(retired, didFailProvisionalNavigation: navigation,
                    withError: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: try server.url("/failed")]))
        XCTAssertNil(tab.existingWeb)
        var closed = false
        tab.onClose = { closed = true }
        tab.webViewDidClose(retired)
        XCTAssertFalse(closed, "A retired popup close must not close its replacement tab")
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/failed").absoluteString) })
    }

    func testSPARoutesUpdateAddressAndHistoryWithoutDocumentNavigation() async throws {
        try await load("/spa")
        let generation = tab.readingDocumentGeneration
        _ = try await tab.web.evaluateJavaScript("history.pushState({}, '', '/route'); document.title='Route title'")
        try await compatibilityWait { self.tab.address == (try self.server.url("/route")).absoluteString }
        XCTAssertEqual(tab.readingDocumentGeneration, generation)
        XCTAssertTrue(tab.history.recent().contains { $0.url == (try? server.url("/route").absoluteString) })
        tab.back()
        try await compatibilityWait { self.tab.address == (try self.server.url("/spa")).absoluteString && self.tab.canGoForward }
        tab.forward()
        try await compatibilityWait { self.tab.address == (try self.server.url("/route")).absoluteString }
        XCTAssertFalse(tab.loading)
    }

    func testPOSTReloadRequiresConsentInsteadOfRepeatingSubmission() async throws {
        server.pages["/form"] = "<title>Form</title><form method='post' action='/submit'><input name='value' value='once'></form>"
        try await load("/form")
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit()")
        try await compatibilityWait { self.server.submissions.count == 1 && !self.tab.web.isLoading && !self.tab.loading }
        let probe = NavigationActionProbe(tab: tab)
        tab.web.navigationDelegate = probe
        tab.reload()
        try await Task.sleep(for: .milliseconds(500))
        print("NAVIGATION POST reload actions: \(probe.actions)")
        XCTAssertEqual(server.submissions.count, 1, "An invisible tab cannot consent to resubmitting a POST")
    }

    func testSupersededErrorPageCannotSuppressSuccessfulHistory() async throws {
        try await load("/first")
        tab.show(URLError(.notConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: try server.url("/offline")]), in: tab.web)
        try await load("/recovered")
        XCTAssertTrue(tab.history.recent().contains { $0.url == (try? server.url("/recovered").absoluteString) })
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/offline").absoluteString) })
    }

    func testHeldNavigationStopAndReplacementRemainInOwningTab() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        defer { window.close() }
        try await load("/first")
        server.heldPaths.insert("/held")
        tab.go(try server.url("/held"))
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /held ") } && self.tab.loading }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let other = Tab(popup: config, isPrivate: false, profileID: UUID())
        defer { other.tearDown() }
        window.contentView = other.web
        other.go(try server.url("/other"))
        try await compatibilityWait { other.title == "Page /other" && !other.loading }
        tab.stop()
        try await compatibilityWait { !self.tab.web.isLoading }
        let stoppedLocation = try await tab.web.evaluateJavaScript("location.href") as? String
        XCTAssertEqual(tab.address, stoppedLocation)
        server.heldPaths.remove("/held")
        try await load("/replacement")
        XCTAssertEqual(tab.address, try server.url("/replacement").absoluteString)
        XCTAssertEqual(other.address, try server.url("/other").absoluteString)
        XCTAssertFalse(other.loading)
        window.contentView = tab.web
        let pathname = try await tab.web.evaluateJavaScript("location.pathname") as? String
        XCTAssertEqual(pathname, "/replacement")
    }

    func testInterruptedResponseAndOfflineFailureRecoverWithoutFailureHistory() async throws {
        server.interruptedPaths.insert("/broken")
        tab.go(try server.url("/broken"))
        try await compatibilityWait { self.tab.title == "The connection dropped" && !self.tab.loading }
        XCTAssertEqual(tab.address, try server.url("/broken").absoluteString)
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/broken").absoluteString) })
        server.interruptedPaths.remove("/broken")
        tab.reload()
        try await compatibilityWait { self.tab.title == "Page /broken" && !self.tab.loading }
        XCTAssertTrue(tab.history.recent().contains { $0.url == (try? server.url("/broken").absoluteString) })
        let dead = try NavigationHTTPFixture()
        try await compatibilityWait { dead.port != nil }
        let offlineURL = try dead.url("/offline")
        dead.stop()
        tab.go(offlineURL)
        try await compatibilityWait { self.tab.title == "Connection refused" && !self.tab.loading }
        XCTAssertEqual(tab.address, offlineURL.absoluteString)
        XCTAssertFalse(tab.history.recent().contains { $0.url == offlineURL.absoluteString })
        try await load("/recovered")
    }

    func testSimulatedHTTPSFailureNeverClaimsSecureConnection() async throws {
        let failed = URL(string: "https://unreachable.invalid/page")!
        tab.show(URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: failed]), in: tab.web)
        try await compatibilityWait { self.tab.title == "Connection refused" && !self.tab.loading }
        let model = SiteControlModel(tab)
        XCTAssertNotEqual(model.glyph, "lock")
        XCTAssertNotEqual(model.connection, "Connection is secure")
        XCTAssertFalse(tab.history.recent().contains { $0.url == failed.absoluteString })
    }

    func testVisiblePOSTReloadCanCancelOrExplicitlySendAgain() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        defer { window.close() }
        server.pages["/form"] = "<title>Form</title><form method='post' action='/submit'><input name='value' value='once'></form>"
        try await load("/form")
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit()")
        try await compatibilityWait { self.server.submissions.count == 1 && !self.tab.web.isLoading && !self.tab.loading }
        tab.reload()
        try await compatibilityWait { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await compatibilityWait { window.attachedSheet == nil }
        XCTAssertEqual(server.submissions.count, 1)
        tab.reload()
        try await compatibilityWait { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await compatibilityWait { self.server.submissions.count == 2 && !self.tab.web.isLoading }
        XCTAssertEqual(server.submissions[0], server.submissions[1])
    }

    func testMovingTabWhileResubmissionSheetIsPendingRejectsAnswer() async throws {
        let windows = (0..<2).map { _ in NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false) }
        for window in windows { window.isReleasedWhenClosed = false; window.orderFront(nil) }
        defer { windows.forEach { $0.close() } }
        windows[0].contentView = tab.web
        server.pages["/form"] = "<title>Form</title><form method='post' action='/submit'><input name='value' value='once'></form>"
        try await load("/form")
        _ = try await tab.web.evaluateJavaScript("document.forms[0].submit()")
        try await compatibilityWait { self.server.submissions.count == 1 && !self.tab.web.isLoading && !self.tab.loading }
        tab.reload()
        try await compatibilityWait { windows[0].attachedSheet != nil }
        let sheet = try XCTUnwrap(windows[0].attachedSheet)
        tab.web.removeFromSuperview()
        windows[1].contentView = tab.web
        windows[0].endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.submissions.count, 1)
        try await load("/recovered")
    }

    func testClosingTabWithHeldRequestCannotRecordLateResponse() async throws {
        try await load("/first")
        server.heldPaths.insert("/held")
        tab.go(try server.url("/held"))
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /held ") } }
        tab.tearDown()
        server.heldPaths.remove("/held")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(tab.existingWeb)
        XCTAssertFalse(tab.loading)
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/held").absoluteString) })
    }

    func testAuthenticationCancellationAndDownloadLeaveRecoverableDocument() async throws {
        try await load("/first")
        server.authPaths.insert("/auth")
        tab.go(try server.url("/auth"))
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /auth ") } && !self.tab.web.isLoading && !self.tab.loading }
        XCTAssertEqual(tab.address, tab.web.url?.absoluteString)
        XCTAssertFalse(server.requests.contains { $0.lowercased().contains("authorization:") })
        try await load("/recovered")
        server.attachmentPaths.insert("/download")
        let manager = Downloads.manager(for: tab.profileID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-navigation-download-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manager.destinationDirectory = root
        defer { manager.items.forEach { manager.cancel($0) }; Downloads.forget(tab.profileID); try? FileManager.default.removeItem(at: root) }
        tab.go(try server.url("/download"))
        try await compatibilityWait { !manager.items.isEmpty && !self.tab.loading }
        XCTAssertEqual(tab.address, try server.url("/recovered").absoluteString)
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/download").absoluteString) })
        try await load("/after-download")
    }

    func testPopupRetainsOpenerAndOwnsPendingNavigationAndClose() async throws {
        try await load("/opener")
        var popup: Tab?
        var popupClosed = false
        tab.onPopup = { config, _ in
            let created = Tab(popup: config, isPrivate: false, profileID: self.tab.profileID)
            created.onClose = { [weak created] in
                Task { @MainActor in created?.tearDown(); popupClosed = true }
            }
            popup = created
            return created.web
        }
        defer { popup?.tearDown(); tab.onPopup = nil }
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await tab.web.evaluateJavaScript("window.child = window.open('/popup', 'navigationFixture'); void 0")
        try await compatibilityWait { popup?.title == "Page /popup" && popup?.loading == false }
        let child = try XCTUnwrap(popup)
        let hasOpener = try await child.web.evaluateJavaScript("window.opener !== null") as? Bool
        XCTAssertEqual(hasOpener, true)
        server.heldPaths.insert("/popup-held")
        child.go(try server.url("/popup-held"))
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /popup-held ") } }
        _ = try await tab.web.evaluateJavaScript("window.child.close()")
        try await compatibilityWait { popupClosed }
        server.heldPaths.remove("/popup-held")
        XCTAssertNil(child.existingWeb)
        XCTAssertEqual(tab.address, try server.url("/opener").absoluteString)
    }

    func testSupersededFailureAndFinishCannotReplaceCurrentDocumentOrWriteHistory() async throws {
        let old = try await load("/old")
        server.heldPaths.insert("/held")
        let current = try XCTUnwrap(tab.web.load(URLRequest(url: try server.url("/held"))))
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /held ") } && self.tab.loading }
        tab.webView(tab.web, didFinish: old)
        XCTAssertTrue(tab.loading)
        tab.webView(tab.web, didFailProvisionalNavigation: old,
            withError: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: try server.url("/old-failed")]))
        XCTAssertTrue(tab.loading)
        let location = try await tab.web.evaluateJavaScript("location.pathname") as? String
        XCTAssertEqual(location, "/old")
        server.heldPaths.remove("/held")
        try await compatibilityWait { self.tab.title == "Page /held" && !self.tab.loading }
        tab.webView(tab.web, didFinish: current)
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/old-failed").absoluteString) })
    }

    func testNewNavigationDismissesPendingHTTPAuthentication() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        defer { window.close() }
        server.authPaths.insert("/auth")
        tab.go(try server.url("/auth"))
        try await compatibilityWait { window.attachedSheet != nil }
        tab.go(try server.url("/after-auth"))
        try await compatibilityWait { self.tab.title == "Page /after-auth" && !self.tab.loading && window.attachedSheet == nil }
        XCTAssertEqual(tab.address, try server.url("/after-auth").absoluteString)
        XCTAssertFalse(server.requests.contains { $0.lowercased().contains("authorization:") })
    }

    func testRedirectFragmentAndReloadKeepChromeAligned() async throws {
        server.redirects["/redirect"] = try server.url("/final")
        tab.go(try server.url("/redirect"))
        try await compatibilityWait { self.tab.title == "Page /final" && !self.tab.loading }
        XCTAssertEqual(tab.address, try server.url("/final").absoluteString)
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/redirect").absoluteString) })
        _ = try await tab.web.evaluateJavaScript("location.hash='section'")
        try await compatibilityWait { self.tab.address.hasSuffix("#section") && self.tab.canGoBack }
        tab.back()
        try await compatibilityWait { !self.tab.address.hasSuffix("#section") && self.tab.canGoForward }
        tab.forward()
        try await compatibilityWait { self.tab.address.hasSuffix("#section") }
        tab.reload()
        try await compatibilityWait { !self.tab.loading && !self.tab.web.isLoading }
        XCTAssertEqual(tab.address, tab.web.url?.absoluteString)
    }
}

@MainActor private final class NavigationActionProbe: NSObject, WKNavigationDelegate {
    let tab: Tab
    var actions: [String] = []
    init(tab: Tab) { self.tab = tab }
    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        actions.append("type=\(action.navigationType.rawValue) method=\(action.request.httpMethod ?? "nil")")
        tab.webView(web, decidePolicyFor: action, decisionHandler: decisionHandler)
    }
    func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { tab.webView(web, didStartProvisionalNavigation: navigation) }
    func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) { tab.webView(web, didCommit: navigation) }
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { tab.webView(web, didFinish: navigation) }
    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { tab.webView(web, didFailProvisionalNavigation: navigation, withError: error) }
}
