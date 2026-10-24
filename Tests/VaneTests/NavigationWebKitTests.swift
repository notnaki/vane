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

    func testFavouriteBlankTargetCrossSiteLinkPeeksInsteadOfCreatingPopupTab() async throws {
        let saved = UserDefaults.vane.object(forKey: Peek.prefKey)
        UserDefaults.vane.set(true, forKey: Peek.prefKey)
        defer { UserDefaults.vane.set(saved, forKey: Peek.prefKey) }
        let destination = try server.url("/document", host: "localhost")
        server.pages["/favourite"] = """
        <title>Favourite</title><a id="document" href="\(destination.absoluteString)" target="_blank">Document</a>
        """
        tab.kind = .favourite
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        var peeked: URL?
        var popupRequested = false
        tab.onPeek = { peeked = $0 }
        tab.onPopup = { _, _, _ in popupRequested = true; return nil }
        try await load("/favourite")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('document').click()")
        try await compatibilityWait { peeked != nil || popupRequested }
        XCTAssertEqual(peeked, destination)
        XCTAssertFalse(popupRequested, "Automatic Peek must intercept the link before WebKit creates a sidebar tab")
        XCTAssertEqual(tab.web.url, try server.url("/favourite"))
    }

    func testFavouritePeriodSelectorHashLinkStaysInDocument() async throws {
        server.pages["/periods"] = """
        <title>Periods</title><a id="period" href="#" onclick="document.body.dataset.period='2'">2. dönem</a>
        """
        tab.kind = .favourite
        var peeked: URL?
        tab.onPeek = { peeked = $0 }
        try await load("/periods")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('period').click()")
        try await compatibilityWait { peeked != nil || self.tab.web.url?.absoluteString.hasSuffix("#") == true }
        XCTAssertNil(peeked, "A same-document period selector must not open a duplicate Peek")
        let period = try await tab.web.evaluateJavaScript("document.body.dataset.period") as? String
        XCTAssertEqual(period, "2")
    }

    func testFavouriteSameSiteBlankTargetKeepsWebKitPopupRouting() async throws {
        server.pages["/favourite"] = """
        <title>Favourite</title><a id="document" href="/document" target="_blank">Document</a>
        """
        tab.kind = .favourite
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        var peeked: URL?
        var popupRequested = false
        tab.onPeek = { peeked = $0 }
        tab.onPopup = { _, _, _ in popupRequested = true; return nil }
        try await load("/favourite")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('document').click()")
        try await compatibilityWait { peeked != nil || popupRequested }
        XCTAssertNil(peeked, "A same-site link must not be mistaken for a link out of about:blank")
        XCTAssertTrue(popupRequested, "Same-site new-window links retain WebKit's opener configuration")
        XCTAssertEqual(tab.web.url, try server.url("/favourite"))
        XCTAssertFalse(server.requests.contains { $0.hasPrefix("GET /document ") })
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
        tab.hardReload()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.submissions.count, 1, "Reload from origin also needs consent")
        try await load("/after-form")
        tab.back()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.submissions.count, 1, "History may restore a cached form result but cannot silently send it again")
        let location = try await tab.web.evaluateJavaScript("location.href") as? String
        XCTAssertEqual(tab.address, location)
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
        tab.onPopup = { config, _, _ in
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

    func testPopupWithNoGestureIsBlockedAndOfferedUnlessTheSiteAllowsIt() async throws {
        var opened = 0
        var blocked: [URL?] = []
        tab.onPopup = { _, _, _ in opened += 1; return nil }
        tab.onPopupBlocked = { url, _ in blocked.append(url) }
        defer { tab.onPopup = nil; tab.onPopupBlocked = nil; SitePermissions.resetAll(profileID: tab.profileID) }
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = Popup.readsGesture
        let page = "<title>Opener</title><script>window.open('/popup')</script>"
        let base = try server.url("/opener")
        // Block before anything has loaded: once Ask has shown a toast, the toast's own rate
        // limit would hide a Block that wrongly showed one too.
        let scope = try XCTUnwrap(SitePermissions.Scope(url: base, profileID: tab.profileID))
        SitePermissions.set(scope: scope, type: .popups, answer: false)
        tab.web.loadHTMLString(page, baseURL: base)
        try await compatibilityWait { self.tab.title == "Opener" && !self.tab.loading }
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(blocked.isEmpty, "Block drops the popup without a toast")

        SiteControl.set(.popups, to: nil, on: tab)
        tab.web.loadHTMLString(page, baseURL: base)
        try await compatibilityWait { !blocked.isEmpty }
        XCTAssertEqual(blocked, [try server.url("/popup")])
        XCTAssertEqual(opened, 0)

        SiteControl.set(.popups, to: true, on: tab)
        tab.web.loadHTMLString(page, baseURL: base)
        try await compatibilityWait { opened == 1 }
        XCTAssertEqual(blocked.count, 1)
    }

    func testPageLeavingForAnAllowedSiteCannotBorrowItsPopupAllow() async throws {
        var opened = 0
        var blocked: [(URL?, SitePermissions.Scope?)] = []
        tab.onPopup = { _, _, _ in opened += 1; return nil }
        tab.onPopupBlocked = { blocked.append(($0, $1)) }
        defer {
            tab.onPopup = nil; tab.onPopupBlocked = nil
            server.heldPaths.remove("/held")
            SitePermissions.resetAll(profileID: tab.profileID)
        }
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = Popup.readsGesture
        let allowed = try XCTUnwrap(SitePermissions.Scope(url: try server.url("/held"), profileID: tab.profileID))
        SitePermissions.set(scope: allowed, type: .popups, answer: true)
        server.heldPaths.insert("/held")
        let page = """
        <script>location.href = '\(try server.url("/held").absoluteString)'
        setTimeout(() => window.open('/popup'), 300)</script>
        """
        tab.web.loadHTMLString(page, baseURL: URL(string: "https://leaving.example/")!)
        try await compatibilityWait { !blocked.isEmpty }
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(blocked.first?.1?.host, "leaving.example", "the toast names, and its Allow saves, the page that asked")
    }

    func testPageLeavingForAnotherOriginKeepsItsSilentPopupBlock() async throws {
        var opened = 0
        var blocked = 0
        tab.onPopup = { _, _, _ in opened += 1; return nil }
        tab.onPopupBlocked = { _, _ in blocked += 1 }
        defer {
            tab.onPopup = nil; tab.onPopupBlocked = nil
            server.heldPaths.remove("/held")
            SitePermissions.resetAll(profileID: tab.profileID)
        }
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = Popup.readsGesture
        let leaving = try server.url("/blocked-opener")
        let destination = try server.url("/held", host: "localhost")
        let scope = try XCTUnwrap(SitePermissions.Scope(url: leaving, profileID: tab.profileID))
        SitePermissions.set(scope: scope, type: .popups, answer: false)
        server.heldPaths.insert("/held")
        let page = """
        <script>location.href = '\(destination.absoluteString)'
        setTimeout(() => { window.open('/popup'); document.title = 'Popup attempted' }, 300)</script>
        """
        tab.web.loadHTMLString(page, baseURL: leaving)
        try await compatibilityWait { self.tab.title == "Popup attempted" }
        XCTAssertEqual(tab.web.url, destination, "the outgoing document is running behind a provisional destination")
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(blocked, 0, "the outgoing document's Block remains silent while another origin loads")
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

    func testHeldCrossSiteNavigationRejectsEarlyAndRetiredURLUpdates() async throws {
        let old = try await load("/old")
        let shown = try server.url("/old")
        let destination = try server.url("/held", host: "localhost")
        server.heldPaths.insert("/held")
        tab.go(destination)
        try await compatibilityWait {
            self.server.requests.contains { $0.hasPrefix("GET /held ") } && self.tab.web.url == destination
        }
        let location = try await tab.web.evaluateJavaScript("location.href") as? String
        XCTAssertEqual(location, shown.absoluteString, "The provisional destination has no document yet")
        XCTAssertEqual(tab.address, shown.absoluteString)
        for callback in ["start", "commit", "finish"] {
            switch callback {
            case "start": tab.webView(tab.web, didStartProvisionalNavigation: old)
            case "commit": tab.webView(tab.web, didCommit: old)
            default: tab.webView(tab.web, didFinish: old)
            }
            XCTAssertEqual(tab.address, shown.absoluteString, "Retired \(callback) must not publish a provisional URL")
            XCTAssertEqual(tab.currentURL, shown, "Retired \(callback) must not change the saved page")
            XCTAssertTrue(tab.loading)
        }
        server.heldPaths.remove("/held")
        try await compatibilityWait { self.tab.title == "Page /held" && !self.tab.loading }
        XCTAssertEqual(tab.address, destination.absoluteString)
        XCTAssertEqual(tab.currentURL, destination)
    }

    func testFirstHeldLoadSurvivesSessionSnapshotAndPinning() async throws {
        let profile = UUID()
        let space = Space(name: "First navigation fixture", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        var stores = [store]
        defer {
            for owner in stores {
                owner.tabs.forEach { $0.tearDown() }
                owner.dropStashes()
                TabStore.all.removeAll { $0 === owner }
                SharedTabs.release(owner.tabs)
            }
            ExtensionHost.forget(profile)
        }
        let destination = try server.url("/first-held")
        server.heldPaths.insert("/first-held")
        let first = store.newBlankTab(loading: destination)
        XCTAssertEqual(first.currentURL, destination, "An explicit initial request must be restorable before policy runs")
        XCTAssertEqual(first.address, destination.absoluteString, "A tab without a document should identify its requested page")
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /first-held ") } }
        XCTAssertTrue(Session.save())
        let file = ProfileManager.sessionURL(for: profile, in: Store.directory)
        var entries = Session.decode(try Data(contentsOf: file)).flatMap { $0 }
        XCTAssertEqual(entries.map(\.url), [destination.absoluteString])
        first.kind = .pinned
        store.savePins()
        XCTAssertEqual(first.homeURL, destination)
        XCTAssertTrue(Session.save())
        entries = Session.decode(try Data(contentsOf: file)).flatMap { $0 }
        XCTAssertEqual(entries.map(\.url), [destination.absoluteString])
        XCTAssertEqual(entries.first?.home, destination.absoluteString)
        XCTAssertEqual(ProfileManager.shared.spaces(for: profile).first?.pinnedTabURLs, [destination])
        first.tearDown()
        store.dropStashes()
        TabStore.all.removeAll { $0 === store }
        SharedTabs.release(store.tabs)
        let restored = TabStore(profileID: profile, space: space, session: entries)
        stores.append(restored)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.currentURL, destination)
        XCTAssertEqual(restored.tabs.first?.homeURL, destination)
        let restoredFirst = try XCTUnwrap(restored.tabs.first)
        restoredFirst.resume()
        server.heldPaths.remove("/first-held")
        try await compatibilityWait { restoredFirst.title == "Page /first-held" && !restoredFirst.loading }
        XCTAssertEqual(restoredFirst.currentURL, destination)
    }

    func testTypedFirstNavigationShowsRequestedAddress() async throws {
        let destination = try server.url("/typed-first-held")
        server.heldPaths.insert("/typed-first-held")
        tab.editing = true
        tab.go(destination.absoluteString)
        XCTAssertFalse(tab.editing)
        XCTAssertEqual(tab.address, destination.absoluteString)
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /typed-first-held ") } }
        XCTAssertEqual(tab.address, destination.absoluteString)
        server.heldPaths.remove("/typed-first-held")
        try await compatibilityWait { self.tab.title == "Page /typed-first-held" && !self.tab.loading }
        XCTAssertEqual(tab.currentURL, destination)
    }

    func testProgrammaticFirstNavigationPreservesEditingAddress() async throws {
        let destination = try server.url("/editing-first-held")
        server.heldPaths.insert("/editing-first-held")
        tab.address = "unfinished address draft"
        tab.editing = true
        tab.go(destination)
        XCTAssertTrue(tab.editing)
        XCTAssertEqual(tab.address, "unfinished address draft")
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /editing-first-held ") } }
        XCTAssertEqual(tab.address, "unfinished address draft")
        server.heldPaths.remove("/editing-first-held")
        try await compatibilityWait { self.tab.title == "Page /editing-first-held" && !self.tab.loading }
        XCTAssertEqual(tab.currentURL, destination)
        XCTAssertEqual(tab.address, "unfinished address draft", "Commit must not replace an active editing value")
    }

    func testHeldCrossSiteHistoryRedirectKeepsCommittedAddress() async throws {
        // Force history traversal to fetch, rather than restoring a cached document.
        let preferences = tab.web.configuration.preferences
        guard preferences.responds(to: NSSelectorFromString("_setUsesPageCache:")) else {
            throw XCTSkip("WebKit page-cache control unavailable for held history fixture")
        }
        preferences.setValue(false, forKey: "usesPageCache")
        for menuJump in [false, true] {
            let suffix = menuJump ? "menu" : "back"
            let firstPath = "/history-first-\(suffix)"
            let heldPath = "/history-held-\(suffix)"
            server.pages[firstPath] = "<title>History first</title>"
            tab.go(try server.url(firstPath))
            try await compatibilityWait { self.tab.title == "History first" && !self.tab.loading }
            let item = try XCTUnwrap(tab.web.backForwardList.currentItem)
            let shown = try server.url("/history-other-\(suffix)", host: "localhost")
            tab.go(shown)
            try await compatibilityWait { self.tab.web.url == shown && !self.tab.loading && !self.tab.web.isLoading }
            let destination = try server.url(heldPath)
            server.redirects[firstPath] = destination
            server.heldPaths.insert(heldPath)
            if menuJump { _ = tab.web.go(to: item) }
            else { tab.back() }
            XCTAssertEqual(tab.currentURL, shown, "A history command must not publish its destination synchronously")
            try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET \(heldPath) ") } }
            XCTAssertEqual(tab.address, shown.absoluteString)
            XCTAssertEqual(tab.currentURL, shown)
            server.heldPaths.remove(heldPath)
            try await compatibilityWait { self.tab.title == "Page \(heldPath)" && !self.tab.loading }
            XCTAssertEqual(tab.currentURL, destination)
            XCTAssertEqual(tab.address, destination.absoluteString)
        }
    }

    func testOldDocumentHistoryMutationCannotUnlockHeldNavigation() async throws {
        try await load("/live-document")
        let shown = try server.url("/live-document")
        let destination = try server.url("/first-held", host: "localhost")
        server.redirects["/first-held"] = try server.url("/second-held", host: "localhost")
        server.heldPaths = ["/first-held", "/second-held"]
        tab.go(destination)
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /first-held ") } }
        _ = try await tab.web.evaluateJavaScript("history.pushState({}, '', '/mutated#section')")
        server.heldPaths.remove("/first-held")
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /second-held ") } }
        XCTAssertEqual(tab.currentURL?.host, shown.host)
        XCTAssertEqual(URL(string: tab.address)?.host, shown.host)
        tab.stop()
        let actual = try await tab.web.evaluateJavaScript("location.href") as? String
        try await compatibilityWait { self.tab.address == actual }
        XCTAssertEqual(tab.currentURL?.absoluteString, actual)
        XCTAssertEqual(actual, try server.url("/mutated#section").absoluteString)
    }

    func testPageInitiatedCrossSiteNavigationKeepsDisplayedOrigin() async throws {
        try await load("/initiator")
        let shown = try server.url("/initiator")
        let destination = try server.url("/page-held", host: "localhost")
        server.heldPaths.insert("/page-held")
        _ = try await tab.web.evaluateJavaScript("location.href = '\(destination.absoluteString)'; void 0")
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /page-held ") } }
        XCTAssertEqual(tab.address, shown.absoluteString)
        XCTAssertEqual(tab.currentURL, shown)
        server.heldPaths.remove("/page-held")
        try await compatibilityWait { self.tab.title == "Page /page-held" && !self.tab.loading }
        XCTAssertEqual(tab.currentURL, destination)
    }

    func testAllowedActionWithoutStartRecoversSameDocumentAddress() async throws {
        let probe = NavigationActionProbe(tab: tab)
        tab.web.navigationDelegate = probe
        try await load("/no-start")
        let action = try XCTUnwrap(probe.lastAction)
        let generation = tab.readingDocumentGeneration
        // Replay an allowed action without starting another document, as after Stay.
        var answer: WKNavigationActionPolicy?
        tab.webView(tab.web, decidePolicyFor: action) { answer = $0 }
        XCTAssertEqual(answer, .allow)
        _ = try await tab.web.evaluateJavaScript("history.pushState({}, '', '/no-start-route#section')")
        let route = try server.url("/no-start-route#section")
        try await compatibilityWait { self.tab.address == route.absoluteString }
        XCTAssertEqual(tab.currentURL, route)
        XCTAssertEqual(tab.readingDocumentGeneration, generation)
        XCTAssertNil(tab.certificateNavigationURL, "A policy answer alone cannot authorize a certificate prompt")
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

    func testRequestedReplacementOwnsCallbacksBeforeItsProvisionalStart() async throws {
        try await load("/first")
        server.heldPaths.insert("/old-pending")
        let old = try XCTUnwrap(tab.web.load(URLRequest(url: try server.url("/old-pending"))))
        try await compatibilityWait { self.server.requests.contains { $0.hasPrefix("GET /old-pending ") } && self.tab.loading }
        tab.go(try server.url("/replacement"))
        // WKWebView.load has returned B, but B's start callback has not run yet.
        tab.webView(tab.web, didFailProvisionalNavigation: old,
            withError: URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: try server.url("/old-pending")]))
        server.heldPaths.remove("/old-pending")
        try await compatibilityWait { !self.tab.web.isLoading && !self.tab.loading }
        XCTAssertEqual(tab.title, "Page /replacement")
        XCTAssertEqual(tab.address, try server.url("/replacement").absoluteString)
    }

    func testMacOS27PolicyProvidesUpcomingNavigationIdentity() async throws {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { throw XCTSkip("macOS 27 navigation action identity") }
        let probe = NavigationActionProbe(tab: tab)
        tab.web.navigationDelegate = probe
        server.redirects["/identity"] = try server.url("/identity-middle")
        server.redirects["/identity-middle"] = try server.url("/identity-final")
        let navigation = try XCTUnwrap(tab.web.load(URLRequest(url: try server.url("/identity"))))
        try await compatibilityWait { self.tab.title == "Page /identity-final" && !self.tab.loading }
        XCTAssertFalse(probe.mainNavigations.isEmpty)
        XCTAssertTrue(probe.mainNavigations.allSatisfy { $0 === navigation })
        XCTAssertTrue(probe.responseNavigations.contains { $0 === navigation })
        #else
        throw XCTSkip("Requires the macOS 27 SDK")
        #endif
    }

    func testRestoringSimulatedHTTPSFailureDoesNotRegainSecureClaim() async throws {
        let failed = URL(string: "https://unreachable.invalid/restore")!
        tab.show(URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: failed]), in: tab.web)
        try await compatibilityWait { self.tab.title == "Connection refused" && !self.tab.loading }
        let restored = Tab(isPrivate: true, profileID: UUID())
        defer { restored.tearDown() }
        restored.park(url: failed, tab.snapshot)
        restored.resume()
        try await compatibilityWait { !restored.web.isLoading && !restored.loading && restored.title != "New Tab" }
        print("NAVIGATION restored failure: title=\(restored.title), connection=\(SiteControlModel(restored).connection)")
        XCTAssertNotEqual(SiteControlModel(restored).glyph, "lock")
        XCTAssertNotEqual(SiteControlModel(restored).connection, "Connection is secure")
    }

    func testStopRejectsLateStartForRetiredNavigation() async throws {
        let navigation = try await load("/first")
        tab.stop()
        tab.webView(tab.web, didStartProvisionalNavigation: navigation)
        XCTAssertFalse(tab.loading)
    }

    func testStopBeforeQueuedConsentCannotPresentStaleSheet() async throws {
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
        let probe = NavigationActionProbe(tab: tab)
        probe.afterAction = { self.tab.stop() }
        tab.web.navigationDelegate = probe
        tab.reload()
        try await compatibilityWait { !probe.actions.isEmpty }
        try await Task.sleep(for: .milliseconds(250))
        let staleSheet = window.attachedSheet
        if let staleSheet { window.endSheet(staleSheet, returnCode: .abort) }
        XCTAssertNil(staleSheet, "Stop must retire the action before its queued consent task presents")
        XCTAssertEqual(server.submissions.count, 1)
    }

    func testSupersededPolicyActionCannotRestartRetiredRequest() async throws {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { throw XCTSkip("macOS 27 navigation action identity") }
        #else
        throw XCTSkip("Requires the macOS 27 SDK")
        #endif
        let probe = NavigationActionProbe(tab: tab)
        tab.web.navigationDelegate = probe
        try await load("/first")
        let oldAction = try XCTUnwrap(probe.lastAction)
        tab.go(try server.url("/replacement"))
        var answer: WKNavigationActionPolicy?
        tab.webView(tab.web, decidePolicyFor: oldAction) { answer = $0 }
        XCTAssertEqual(answer, .cancel)
        try await compatibilityWait { self.tab.title == "Page /replacement" && !self.tab.loading }
    }

    func testSubframeResponseLoadsWithoutReplacingMainDocumentOwnership() async throws {
        try await load("/main")
        let generation = tab.readingDocumentGeneration
        _ = try await tab.web.evaluateJavaScript("const frame=document.createElement('iframe'); frame.src='/frame'; document.body.append(frame)")
        try await compatibilityWait {
            (try? await self.tab.web.evaluateJavaScript("document.querySelector('iframe').contentDocument.title") as? String) == "Page /frame"
        }
        XCTAssertEqual(tab.address, try server.url("/main").absoluteString)
        XCTAssertEqual(tab.readingDocumentGeneration, generation)
        XCTAssertFalse(tab.loading)
        XCTAssertFalse(tab.history.recent().contains { $0.url == (try? server.url("/frame").absoluteString) })
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
    var mainNavigations: [WKNavigation] = []
    var responseNavigations: [WKNavigation] = []
    var lastAction: WKNavigationAction?
    var afterAction: (() -> Void)?
    init(tab: Tab) { self.tab = tab }
    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let navigation = action.mainFrameNavigation { mainNavigations.append(navigation) }
        #endif
        lastAction = action
        actions.append("type=\(action.navigationType.rawValue) method=\(action.request.httpMethod ?? "nil")")
        tab.webView(web, decidePolicyFor: action, decisionHandler: decisionHandler)
        afterAction?()
    }
    func webView(_ web: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let navigation = response.mainFrameNavigation { responseNavigations.append(navigation) }
        #endif
        tab.webView(web, decidePolicyFor: response, decisionHandler: decisionHandler)
    }
    func webView(_ web: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { tab.webView(web, didReceiveServerRedirectForProvisionalNavigation: navigation) }
    func webView(_ web: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { tab.webView(web, didStartProvisionalNavigation: navigation) }
    func webView(_ web: WKWebView, didCommit navigation: WKNavigation!) { tab.webView(web, didCommit: navigation) }
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { tab.webView(web, didFinish: navigation) }
    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { tab.webView(web, didFailProvisionalNavigation: navigation, withError: error) }
}
