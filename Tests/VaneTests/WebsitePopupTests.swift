import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WebsitePopupTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
    }

    func testDialogPopupHasNoLittleVaneStoreAndManualClosePreservesOpener() throws {
        let store = TabStore(isPrivate: true, urls: [], isLittle: false, session: [])
        let opener = store.newBlankTab()
        let before = TabStore.all.count
        let config = WKWebViewConfiguration()
        config.websiteDataStore = opener.web.configuration.websiteDataStore
        let web = store.popup(config, placement: .window, opener: opener.id)
        let window = try XCTUnwrap(web.window)
        defer {
            window.close()
            opener.tearDown()
            TabStore.all.removeAll { $0 === store }
        }
        XCTAssertEqual(TabStore.all.count, before, "A website dialog must not register a sidebar/session store")
        XCTAssertNil(LittleArc.store(of: window), "Authentication is not an external-app link")
        XCTAssertNotEqual(window.title, "Little Vane")
        XCTAssertNil(window.toolbar, "The popup must have no Open in Space toolbar")
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
        XCTAssertTrue(opener.existingWeb === opener.web)
    }

    func testWebsitePopupDrawsPasswordChooserAndSaveOffer() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let tab = Tab(popup: config, isPrivate: false, profileID: UUID())
        let controller = WebsitePopupWindow.open(tab, origin: nil, opener: nil)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        func pixels() throws -> Data {
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        try await Task.sleep(for: .milliseconds(200))
        let empty = try pixels()
        tab.passwordChoice = PasswordChoice(host: "accounts.example.com", accounts: ["ada@example.com", "bob@example.com"],
                                           anchor: CGRect(x: 20, y: 20, width: 250, height: 40))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotEqual(try pixels(), empty, "A sign-in popup must draw its account chooser")
        tab.passwordChoice = nil
        try await Task.sleep(for: .milliseconds(350))
        let withoutOffer = try pixels()
        tab.pendingSave = PendingSave(host: "accounts.example.com", account: "ada", password: "fixture")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotEqual(try pixels(), withoutOffer, "A sign-in popup must draw its save offer")
    }

    func testWebsitePopupPasswordChooserHandlesArrowsAndEscape() throws {
        let tab = Tab(popup: WKWebViewConfiguration(), isPrivate: false, profileID: UUID())
        let controller = WebsitePopupWindow.open(tab, origin: nil, opener: nil)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        tab.passwordChoice = PasswordChoice(host: "accounts.example.com", accounts: ["ada", "bob"], anchor: .zero)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        XCTAssertTrue(PasswordChooser.handleKey(down))
        XCTAssertEqual(tab.passwordChoice?.selected, 1)
        XCTAssertTrue(PasswordChooser.dismiss(in: window))
        XCTAssertNil(tab.passwordChoice)
        tab.passwordChoice = PasswordChoice(host: "accounts.example.com", accounts: ["ada", "bob"], anchor: .zero)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        XCTAssertNil(tab.passwordChoice, "Native Escape must dismiss the popup's chooser")
        tab.passwordChoice = PasswordChoice(host: "accounts.example.com", accounts: ["ada", "bob"], anchor: .zero)
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        // Exercise pointer routing without entering AppKit's window-edge tracking loop.
        PasswordChooser.handlePointer(outside)
        XCTAssertNil(tab.passwordChoice, "A click outside the popup's chooser must dismiss it")
    }

    func testPopupSizeUsesSafeDefaultsAndFitsTheScreen() {
        let screen = NSSize(width: 1000, height: 800)
        XCTAssertEqual(WebsitePopupWindow.contentSize(width: 451, height: 600, available: screen),
                       NSSize(width: 451, height: 600))
        XCTAssertEqual(WebsitePopupWindow.contentSize(width: .nan, height: -.infinity, available: screen),
                       NSSize(width: 500, height: 600))
        XCTAssertEqual(WebsitePopupWindow.contentSize(width: -1, height: 0, available: screen),
                       NSSize(width: 500, height: 600))
        XCTAssertEqual(WebsitePopupWindow.contentSize(width: 9000, height: 9000, available: screen),
                       NSSize(width: 920, height: 720))
    }

}

@MainActor final class WebsitePopupWebKitTests: XCTestCase {
    var server: NavigationHTTPFixture!
    var store: TabStore!
    var opener: Tab!
    var host: NSWindow!
    var child: Tab?
    var childWindow: NSWindow?
    var supplied: WKWebViewConfiguration?
    var placement: Popup.Placement?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
    }

    override func tearDown() async throws {
        childWindow?.close()
        child?.tearDown()
        host?.close()
        store?.tabs.forEach { $0.tearDown() }
        if let store { TabStore.all.removeAll { $0 === store } }
        server.stop()
        child = nil; childWindow = nil; opener = nil; store = nil; host = nil; server = nil
    }

    func prepare(isPrivate: Bool, html: String) async throws {
        store = TabStore(isPrivate: isPrivate, urls: [], profileID: UUID(), session: [])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = "PopupFixture"
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        opener = Tab(popup: config, isPrivate: isPrivate, profileID: store.profileID)
        store.adoptBeside(opener, opener: nil, focus: true)
        host = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = opener.web
        store.window = host
        host.makeKeyAndOrderFront(nil)
        let route = try XCTUnwrap(opener.onPopup)
        opener.onPopup = { [unowned self] configuration, placement, features in
            self.supplied = configuration
            self.placement = placement
            let web = route(configuration, placement, features)
            self.child = web?.uiDelegate as? Tab
            self.childWindow = web?.window
            return web
        }
        server.pages["/opener"] = """
        <title>Originating page</title><style>body{margin:0}button,a{display:block;width:200px;height:50px}</style>
        <script>window.received='';addEventListener('message',e=>{if(e.origin===location.origin) received=e.data});</script>
        \(html)
        """
        opener.go(try server.url("/opener"))
        try await compatibilityWait { self.opener.title == "Originating page" && !self.opener.loading }
    }

    func clickFirstControl() async throws {
        _ = try await opener.web.evaluateJavaScript("document.querySelector('button,a').click(); void 0")
        try await compatibilityWait { self.child != nil }
    }

    func testBlankPopupDocumentWriteMessagingAndScriptClose() async throws {
        try await prepare(isPrivate: false, html: """
        <button onclick="window.child=window.open('about:blank','auth','width=451,height=600'); child.document.write('<title>Written popup</title><p>Ready</p>'); child.document.close()">Sign in</button>
        """)
        let count = TabStore.all.count
        try await clickFirstControl()
        let child = try XCTUnwrap(child)
        let window = try XCTUnwrap(childWindow)
        XCTAssertEqual(placement, .window)
        XCTAssertTrue(WebsitePopupWindow.owns(window))
        XCTAssertEqual(TabStore.all.count, count)
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
        XCTAssertEqual(child.profileID, store.profileID)
        XCTAssertNotEqual(child.profileID, ProfileManager.shared.active.id)
        XCTAssertTrue(child.web.configuration.websiteDataStore === supplied?.websiteDataStore)
        XCTAssertEqual(child.web.configuration.applicationNameForUserAgent, supplied?.applicationNameForUserAgent)
        XCTAssertFalse(child.web.configuration.userContentController === opener.web.configuration.userContentController)
        try await compatibilityWait { child.title == "Written popup" }
        let related = try await child.web.evaluateJavaScript("opener === window.opener && opener.child === window") as? Bool
        XCTAssertEqual(related, true)
        _ = try await child.web.evaluateJavaScript("opener.postMessage('complete', location.origin); window.close(); void 0")
        try await compatibilityWait { !window.isVisible && child.existingWeb == nil }
        try await compatibilityWait { try await self.opener.web.evaluateJavaScript("received") as? String == "complete" }
        XCTAssertEqual(opener.web.url, try server.url("/opener"))
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
    }

    func testPrivatePopupCrossOriginRedirectSharesCookiesAndManualCancelCanRetry() async throws {
        server.redirects["/authorize"] = try server.url("/provider", host: "localhost")
        server.pages["/provider"] = "<title>Provider challenge</title>Challenge"
        server.redirects["/approve"] = try server.url("/callback")
        server.pages["/callback"] = """
        <title>Callback</title><script>
        document.cookie='session=synthetic; path=/; SameSite=Lax';
        opener.postMessage(document.cookie.includes('openerCookie=yes') ? 'complete' : 'missing-cookie',location.origin);
        window.close();
        </script>
        """
        try await prepare(isPrivate: true, html: """
        <button onclick="window.child=window.open('/authorize','auth','width=451,height=600')">Sign in</button>
        """)
        _ = try await opener.web.evaluateJavaScript("document.cookie='openerCookie=yes; path=/'")
        try await clickFirstControl()
        let first = try XCTUnwrap(child)
        let firstWindow = try XCTUnwrap(childWindow)
        try await compatibilityWait { first.title == "Provider challenge" }
        XCTAssertEqual(placement, .window)
        XCTAssertTrue(first.isPrivate)
        XCTAssertEqual(first.profileID, Profile.incognito.id)
        XCTAssertTrue(first.web.configuration.websiteDataStore === opener.web.configuration.websiteDataStore)
        XCTAssertFalse(first.web.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(try XCTUnwrap(firstWindow.contentView).frame.width, 451, accuracy: 1)
        try await compatibilityWait { firstWindow.title.contains("localhost") }
        firstWindow.performClose(nil)
        XCTAssertNil(first.existingWeb)
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
        try await compatibilityWait { try await self.opener.web.evaluateJavaScript("window.child.closed") as? Bool == true }
        child = nil
        try await clickFirstControl()
        let second = try XCTUnwrap(child)
        let window = try XCTUnwrap(childWindow)
        try await compatibilityWait { second.title == "Provider challenge" }
        _ = try await second.web.evaluateJavaScript("location.href='/approve'; void 0")
        try await compatibilityWait { !window.isVisible && second.existingWeb == nil }
        try await compatibilityWait { try await self.opener.web.evaluateJavaScript("received === 'complete' && document.cookie.includes('session=synthetic')") as? Bool == true }
        XCTAssertEqual(opener.web.url, try server.url("/opener"))
        let other = Tab(isPrivate: true)
        defer { other.tearDown() }
        XCTAssertFalse(other.web.configuration.websiteDataStore === opener.web.configuration.websiteDataStore)
        XCTAssertFalse(opener.history.recent().contains { $0.url == (try? server.url("/provider", host: "localhost").absoluteString) })
    }

    func testPopupLoginInputKeepsOptionTextShortcuts() async throws {
        server.pages["/input"] = "<title>Login input</title><input id='account'>"
        try await prepare(isPrivate: false, html: """
        <button onclick="window.child=window.open('/input','auth','width=451,height=600')">Sign in</button>
        """)
        try await clickFirstControl()
        let child = try XCTUnwrap(child)
        let window = try XCTUnwrap(childWindow)
        try await compatibilityWait { child.title == "Login input" }
        _ = try await child.web.evaluateJavaScript("document.getElementById('account').focus(); void 0")
        window.makeFirstResponder(child.web)
        try await compatibilityWait { child.editableFocused }
        try XCTUnwrap(Keybindings.withScratchDefaults("website-popup-option") {
            XCTAssertTrue(Keybindings.keepsKeyForResponder(Keybinding("d", .option), in: window),
                          "Option-D must type in the provider's login field")
        })
    }

    func testNestedDialogOutlivesItsParentAndClosesIndependently() async throws {
        try await prepare(isPrivate: false, html: """
        <button onclick="window.child=window.open('/parent','auth','width=451,height=600')">Sign in</button>
        """)
        try await clickFirstControl()
        let parent = try XCTUnwrap(child)
        let parentWindow = try XCTUnwrap(childWindow)
        try await compatibilityWait { parent.title == "Page /parent" }
        var nested: Tab?
        let route = try XCTUnwrap(parent.onPopup)
        parent.onPopup = { configuration, placement, features in
            let web = route(configuration, placement, features)
            nested = web?.uiDelegate as? Tab
            return web
        }
        _ = try await parent.web.evaluateJavaScript("window.child=window.open('/nested','nested','width=400,height=500'); void 0")
        try await compatibilityWait { nested?.title == "Page /nested" }
        let grandchild = try XCTUnwrap(nested)
        let window = try XCTUnwrap(grandchild.web.window)
        defer { window.close(); grandchild.tearDown() }
        XCTAssertTrue(WebsitePopupWindow.owns(window))
        parentWindow.performClose(nil)
        XCTAssertNil(parent.existingWeb)
        XCTAssertNotNil(grandchild.existingWeb)
        _ = try await grandchild.web.evaluateJavaScript("window.close(); void 0")
        try await compatibilityWait { !window.isVisible && grandchild.existingWeb == nil }
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
        XCTAssertEqual(opener.web.url, try server.url("/opener"))
    }

    func testOrdinaryBlankTargetRemainsAnAdjacentTab() async throws {
        try await prepare(isPrivate: false, html: "<a href='/destination' target='_blank'>Ordinary link</a>")
        let count = TabStore.all.count
        try await clickFirstControl()
        let child = try XCTUnwrap(child)
        try await compatibilityWait { child.title == "Page /destination" }
        XCTAssertEqual(placement, .tab(focus: true))
        XCTAssertEqual(store.tabs.map(\.id), [opener.id, child.id])
        XCTAssertEqual(TabStore.all.count, count)
        XCTAssertFalse(WebsitePopupWindow.owns(child.web.window))
        XCTAssertEqual(opener.web.url, try server.url("/opener"))
    }
}
