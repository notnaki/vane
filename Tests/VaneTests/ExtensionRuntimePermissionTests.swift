import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionRuntimePermissionTests: XCTestCase {
    private var profile: UUID!
    private var ownedProfiles = Set<UUID>()
    private var folder: URL!
    private var view: WKWebView?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        ownedProfiles.insert(profile)
        folder = Store.directory.appendingPathComponent("runtime-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Runtime Fixture","version":"1.0","optional_permissions":["cookies"],"optional_host_permissions":["https://example.test/*"],"options_ui":{"page":"options.html"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Runtime fixture</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
    }

    override func tearDown() async throws {
        view?.stopLoading(); view = nil
        func removeInstallations() {
            let host = ExtensionHost.host(for: profile)
            for context in host.installed { host.remove(context) }
            ExtensionHost.forget(profile)
        }
        removeInstallations()
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        try? FileManager.default.removeItem(at: folder)
        let released = ownedProfiles
        ownedProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(released)
    }

    private func load() async throws -> (ExtensionHost, WKWebExtensionContext) {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        return (host, try XCTUnwrap(host.installed.first))
    }

    /// Drive the real AppKit prompt while WebKit awaits the delegate's reply.
    private func answer(_ response: NSApplication.ModalResponse,
                        during operation: () async throws -> Void) async throws {
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApplication.shared.modalWindow != nil { NSApplication.shared.stopModal(withCode: response) }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        try await operation()
    }

    func testRuntimePermissionReturnDefaultsToDeny() async throws {
        let (host, context) = try await load()
        var observedDefault: String?
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else { return }
                observedDefault = window.defaultButtonCell?.title
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let (permissions, _) = await host.webExtensionController(host.controller,
            promptForPermissions: [WKWebExtension.Permission(rawValue: "cookies")], in: nil, for: context)
        XCTAssertEqual(observedDefault, "Deny", "Return must never approve access while the user is typing")
        XCTAssertTrue(permissions.isEmpty)
    }

    func testTabNavigationRejectsInternalOAuthAndExecutableSchemesBeforeCreatingAWebView() async throws {
        let (_, context) = try await load()
        let store = TabStore(profileID: profile, session: [])
        let tab = store.newBlankTab()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        store.window = window
        defer {
            window.orderOut(nil); window.contentView = nil; window.close(); store.window = nil
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        let adapter = ExtTab(tab, in: store)
        for raw in ["vane://oauth/github?code=fixture&state=fixture", "javascript:void(0)", "file:///nonexistent-vane-security-fixture"] {
            var result: Error?
            adapter.loadURL(try XCTUnwrap(URL(string: raw)), for: context) { result = $0 }
            XCTAssertNotNil(result, raw)
            XCTAssertNil(tab.existingWeb, "Rejected URLs must have no navigation side effects")
            XCTAssertNil(tab.currentURL)
        }
    }

    func testRetainedAdapterCannotReadOrNavigateExtensionRestrictedAuthorizationTab() async throws {
        let (host, context) = try await load()
        let store = TabStore(profileID: profile, session: [])
        let tab = store.newBlankTab()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        store.window = window
        defer {
            window.orderOut(nil); window.contentView = nil; window.close(); store.window = nil
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        let adapter = host.adapter(for: tab, in: store)
        let authorization = URL(string: "https://github.com/login/oauth/authorize?state=private-fixture")!
        tab.park(url: authorization, Parked(title: "GitHub sign-in"))
        tab.extensionAccessRestricted = true
        host.sync()
        XCTAssertNil(adapter.url(for: context))
        XCTAssertNil(adapter.title(for: context))
        XCTAssertNil(adapter.webView(for: context))
        XCTAssertFalse(adapter.shouldGrantPermissionsOnUserGesture(for: context))
        XCTAssertTrue(host.visible(in: tab).isEmpty)
        XCTAssertFalse(ExtWindow(store).tabs(for: context).contains { ($0 as AnyObject) === adapter })
        XCTAssertNil(ExtWindow(store).activeTab(for: context))
        var result: Error?
        adapter.loadURL(URL(string: "https://attacker.example/redirect-to-callback")!, for: context) { result = $0 }
        XCTAssertNotNil(result, "HTTPS navigation can redirect to the internal callback and must also be refused")
        XCTAssertEqual(tab.currentURL, authorization)
        XCTAssertNil(tab.existingWeb)
    }

    func testNavigationPolicyPreservesWebURLsAndOnlyTheOwningExtension() async throws {
        let (_, context) = try await load()
        for raw in ["http://example.test/", "https://example.test/", "about:blank", "about:srcdoc", "blob:https://example.test/fixture"] {
            XCTAssertTrue(ExtensionHost.permitsNavigation(to: try XCTUnwrap(URL(string: raw)), for: context), raw)
        }
        XCTAssertTrue(ExtensionHost.permitsNavigation(to: context.baseURL.appendingPathComponent("options.html"), for: context))
        for raw in ["webkit-extension://another-extension/options.html", "vane://oauth/github", "javascript:void(0)", "file:///fixture", "custom-app://fixture"] {
            XCTAssertFalse(ExtensionHost.permitsNavigation(to: try XCTUnwrap(URL(string: raw)), for: context), raw)
        }
    }

    func testAuthorizationTabAndItsPopupUseNoExtensionControllerOrAdapters() async throws {
        let (host, context) = try await load()
        let store = TabStore(profileID: profile, session: [])
        let ordinary = store.newBlankTab()
        let authorization = store.newBlankTab(extensionAccessRestricted: true)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        store.window = window
        defer {
            window.orderOut(nil); window.contentView = nil; window.close(); store.window = nil
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        XCTAssertNil(authorization.existingWeb)
        let configuration = authorization.web.configuration
        XCTAssertNil(configuration.webExtensionController, "The first web view must exclude extensions before any document loads")
        XCTAssertTrue(ordinary.web.configuration.webExtensionController === host.controller)
        XCTAssertEqual(configuration.websiteDataStore.identifier, ordinary.web.configuration.websiteDataStore.identifier,
                       "Sign-in keeps the profile cookie store for SSO")
        let popupWeb = store.popup(configuration, placement: .tab(focus: false), opener: authorization.id)
        let popup = try XCTUnwrap(store.tabs.first { $0.existingWeb === popupWeb })
        XCTAssertTrue(popup.extensionAccessRestricted, "Authentication popups inherit the protected opener's extension boundary")
        XCTAssertNil(popupWeb.configuration.webExtensionController)
        XCTAssertEqual(popupWeb.configuration.websiteDataStore.identifier, configuration.websiteDataStore.identifier)
        let popupAdapter = host.adapter(for: popup, in: store)
        popup.park(url: URL(string: "https://github.com/login/oauth/authorize?state=popup-private-fixture")!, Parked(title: "Private authorization"))
        XCTAssertNil(popupAdapter.url(for: context))
        XCTAssertNil(popupAdapter.title(for: context))
        XCTAssertNil(popupAdapter.webView(for: context))
        let visible = ExtWindow(store).tabs(for: context)
        XCTAssertEqual(visible.count, 1)
        XCTAssertTrue((visible.first as? ExtTab)?.tab === ordinary)
    }

    func testAllThreeRuntimeHooksGrantOrRejectOnlyTheRequest() async throws {
        let (host, context) = try await load()
        let cookie = WKWebExtension.Permission(rawValue: "cookies")
        let url = URL(string: "https://example.test/page")!
        let pattern = try XCTUnwrap(WKWebExtension.MatchPattern(string: "https://example.test/*"))
        for allowed in [false, true] {
            try await answer(allowed ? .alertFirstButtonReturn : .alertSecondButtonReturn) {
                let (permissions, date) = await host.webExtensionController(host.controller, promptForPermissions: [cookie], in: nil, for: context)
                XCTAssertEqual(permissions, allowed ? [cookie] : [])
                XCTAssertNil(date)
                let (urls, _) = await host.webExtensionController(host.controller, promptForPermissionToAccess: [url], in: nil, for: context)
                XCTAssertEqual(urls, allowed ? [url] : [])
                let (patterns, _) = await host.webExtensionController(host.controller, promptForPermissionMatchPatterns: [pattern], in: nil, for: context)
                XCTAssertEqual(patterns, allowed ? [pattern] : [])
            }
        }
        XCTAssertTrue(ExtensionConsent.saved(for: folder, profileID: profile)!.isEmpty,
                      "Runtime approval must not silently expand saved manifest consent")
        host.remove(context)
        let (permissions, _) = await host.webExtensionController(host.controller, promptForPermissions: [cookie], in: nil, for: context)
        XCTAssertTrue(permissions.isEmpty, "An unloaded context cannot request access")
    }

    func testRemovalDuringRuntimePromptRejectsThePendingGrant() async throws {
        let (host, context) = try await load()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSApplication.shared.modalWindow != nil else { return }
                host.remove(context)
                NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let (permissions, _) = await host.webExtensionController(host.controller,
            promptForPermissions: [WKWebExtension.Permission(rawValue: "cookies")], in: nil, for: context)
        XCTAssertTrue(permissions.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
    }

    func testRuntimeGrantsExpireAndDoNotSurviveRestore() async throws {
        let (host, context) = try await load()
        let cookie = WKWebExtension.Permission(rawValue: "cookies")
        let pattern = try XCTUnwrap(WKWebExtension.MatchPattern(string: "https://example.test/*"))
        context.setPermissionStatus(.grantedExplicitly, for: cookie, expirationDate: Date().addingTimeInterval(-1))
        context.setPermissionStatus(.grantedExplicitly, for: pattern, expirationDate: Date().addingTimeInterval(-1))
        XCTAssertFalse(context.hasPermission(cookie))
        XCTAssertFalse(context.hasAccess(to: URL(string: "https://example.test/page")!))
        context.setPermissionStatus(.grantedExplicitly, for: cookie)
        context.setPermissionStatus(.grantedExplicitly, for: pattern)
        XCTAssertTrue(context.hasPermission(cookie))
        ExtensionHost.forget(profile)
        let restoredHost = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(10)
        while restoredHost.installed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let restored = try XCTUnwrap(restoredHost.installed.first)
        XCTAssertFalse(restored.hasPermission(cookie))
        XCTAssertFalse(restored.hasAccess(to: URL(string: "https://example.test/page")!))
        XCTAssertFalse(host.controller.extensionContexts.contains(context))
    }
    private func options(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: try XCTUnwrap(context.webViewConfiguration))
        view = web
        web.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        let deadline = ContinuousClock.now + .seconds(10)
        while web.isLoading || web.title != "Runtime fixture" {
            if ContinuousClock.now >= deadline { throw ExtensionHost.Failure("Timed out loading runtime fixture") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return web
    }

    func testJavaScriptRuntimeRequestRejectionGrantRevocationAndExpiration() async throws {
        let (host, context) = try await load()
        let web = try await options(context)
        for allowed in [false, true] {
            try await answer(allowed ? .alertFirstButtonReturn : .alertSecondButtonReturn) {
                let result = try await web.callAsyncJavaScript(
                    "return await browser.permissions.request({permissions:['cookies'], origins:['https://example.test/*']});",
                    arguments: [:], in: nil, contentWorld: .page)
                XCTAssertEqual(result as? Bool, allowed)
            }
            let contains = try await web.callAsyncJavaScript(
                "return await browser.permissions.contains({permissions:['cookies'], origins:['https://example.test/*']});",
                arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(contains as? Bool, allowed)
        }
        host.revokeRuntimeAccess(context)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(context.hasPermission(WKWebExtension.Permission(rawValue: "cookies")))
        let revoked = try await web.callAsyncJavaScript(
            "return await browser.permissions.contains({permissions:['cookies'], origins:['https://example.test/*']});",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(revoked as? Bool, false)
        let cookie = WKWebExtension.Permission(rawValue: "cookies")
        context.setPermissionStatus(.grantedExplicitly, for: cookie, expirationDate: Date().addingTimeInterval(-1))
        XCTAssertFalse(context.hasPermission(cookie))
        try await Task.sleep(for: .milliseconds(50))
        let expired = try await web.callAsyncJavaScript("return await browser.permissions.contains({permissions:['cookies']});",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(expired as? Bool, false)
        XCTAssertTrue(ExtensionConsent.saved(for: folder, profileID: profile)!.isEmpty)
    }

    func testUnsupportedHostCapabilitiesAreDisclosedAndCannotBeGranted() async throws {
        try Data(#"{"manifest_version":3,"name":"Unsupported Fixture","version":"1.0","permissions":["downloads","nativeMessaging","contextMenus"],"options_ui":{"page":"options.html"},"commands":{"fixture":{"suggested_key":{"default":"Ctrl+Shift+Y"},"description":"Fixture shortcut"}}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { review in
            XCTAssertTrue(review.limitations.contains { $0.contains("downloads") })
            XCTAssertTrue(review.limitations.contains { $0.contains("nativeMessaging") })
            XCTAssertFalse(review.limitations.contains { $0.contains("contextMenus") })
            XCTAssertFalse(review.limitations.contains { $0.contains("sidebar tab menus") })
            XCTAssertFalse(review.limitations.contains { $0.contains("commands") })
            return true
        }
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertFalse(context.hasPermission(WKWebExtension.Permission(rawValue: "nativeMessaging")))
        let web = try await options(context)
        let hidden = try await web.evaluateJavaScript("typeof browser.runtime.sendNativeMessage + ':' + typeof browser.contextMenus")
        XCTAssertEqual(hidden as? String, "undefined:object")
        let (granted, _) = await host.webExtensionController(host.controller,
            promptForPermissions: [WKWebExtension.Permission(rawValue: "nativeMessaging")], in: nil, for: context)
        XCTAssertTrue(granted.isEmpty)
    }

}
