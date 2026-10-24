import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionUserAgentTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var previousUserAgent: Any?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        previousUserAgent = UserDefaults.vane.object(forKey: "userAgent")
        UserDefaults.vane.removeObject(forKey: "userAgent")
        profile = UUID()
        folder = Store.directory.appendingPathComponent("user-agent-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let host = ExtensionHost.host(for: profile)
        for context in host.installed { host.remove(context) }
        ExtensionHost.forget(profile)
        UserDefaults.vane.set(previousUserAgent, forKey: "userAgent")
        Settings.apply()
        try? FileManager.default.removeItem(at: folder)
    }

    private func install(version: Int) async throws -> WKWebExtensionContext {
        var manifest: [String: Any] = ["manifest_version": version, "name": "User Agent Fixture",
            "version": "1.0", "permissions": ["storage"]]
        manifest[version == 2 ? "browser_action" : "action"] = ["default_popup": "popup.html"]
        manifest["background"] = version == 2
            ? ["scripts": ["background.js"], "persistent": true] as [String: Any]
            : ["service_worker": "background.js"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("""
            const startupUserAgent = navigator.userAgent;
            browser.runtime.onMessage.addListener(async () => ({startup: startupUserAgent, current: navigator.userAgent}));
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("<title>UA fixture</title><script src='popup.js'></script>".utf8)
            .write(to: folder.appendingPathComponent("popup.html"))
        try Data("""
            window.startupUserAgent = navigator.userAgent;
            browser.runtime.sendMessage('identity').then(reply => { window.backgroundIdentity = reply; });
            """.utf8).write(to: folder.appendingPathComponent("popup.js"))
        let host = ExtensionHost.host(for: profile)
        let accepted = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        return try XCTUnwrap(host.installed.first)
    }

    private func popup(_ context: WKWebExtensionContext) async throws -> (WKWebExtension.Action, WKWebView) {
        let action = try XCTUnwrap(context.action(for: nil))
        let web = try XCTUnwrap(action.popupWebView)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !web.isLoading,
               (try? await web.evaluateJavaScript("typeof window.backgroundIdentity === 'object'")) as? Bool == true {
                return (action, web)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ExtensionUserAgentTests.PopupTimeout", code: 1)
    }

    private func assertIdentity(in web: WKWebView, expected: String, startup: String? = nil,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let identity = try await web.evaluateJavaScript("({popup:window.startupUserAgent, background:window.backgroundIdentity.startup, current:window.backgroundIdentity.current})") as? [String: String]
        XCTAssertEqual(identity?["popup"], expected, "Popup startup", file: file, line: line)
        XCTAssertEqual(identity?["background"], startup ?? expected, "Background startup", file: file, line: line)
        XCTAssertEqual(identity?["current"], expected, "Background current", file: file, line: line)
    }

    func testDefaultSafariIdentityReachesBackgroundAndPopupBeforeTheirScriptsRun() async throws {
        for version in [2, 3] {
            let context = try await install(version: version)
            let (action, web) = try await popup(context)
            try await assertIdentity(in: web, expected: safariUA)
            let ua = try await web.evaluateJavaScript("navigator.userAgent") as? String
            XCTAssertEqual(ua?.components(separatedBy: " Safari/").count, 2, "Safari must appear once")
            XCTAssertEqual(ua?.components(separatedBy: " Version/").count, 2, "Version must appear once")
            action.closePopup()
            ExtensionHost.host(for: profile).remove(context)
        }
    }

    func testDevelopChangeUpdatesLiveBackgroundAndRecreatedPopupWithoutChangingAccess() async throws {
        let context = try await install(version: 2)
        let host = ExtensionHost.host(for: profile)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 440, y: 250, width: 28, height: 28))
        try XCTUnwrap(window.contentView).addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        host.run(context, for: nil, from: anchor)
        let (action, web) = try await popup(context)
        try await waitForPresentation(action)
        try await assertIdentity(in: web, expected: safariUA)
        let controller = host.controller
        let granted = context.grantedPermissions
        let sites = context.grantedPermissionMatchPatterns
        let custom = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.0; rv:135.0) Gecko/20100101 Firefox/135.0"
        Settings.userAgent = custom
        let live = try await web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(live, custom)
        Settings.userAgent = safariUA
        let defaultLive = try await web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(defaultLive, safariUA)
        Settings.userAgent = custom
        try await closePresentedPopup(action)
        let (recreatedAction, recreated) = try await popup(context)
        XCTAssertFalse(recreated === web, "Recreation must inspect a fresh popup, not cached startup values")
        try await assertIdentity(in: recreated, expected: custom, startup: safariUA)
        XCTAssertTrue(ExtensionHost.host(for: profile).controller === controller)
        XCTAssertTrue(context.isLoaded)
        XCTAssertEqual(context.grantedPermissions, granted)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, sites)
        recreatedAction.closePopup()
    }

    private func waitForPresentation(_ action: WKWebExtension.Action) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while action.popupPopover?.isShown != true {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "ExtensionUserAgentTests.PresentationTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func closePresentedPopup(_ action: WKWebExtension.Action) async throws {
        let popover = try XCTUnwrap(action.popupPopover)
        XCTAssertTrue(popover.isShown)
        let closed = XCTNSNotificationExpectation(name: NSPopover.didCloseNotification, object: popover)
        action.closePopup()
        await fulfillment(of: [closed], timeout: 5)
    }

    func testExplicitCustomIdentitySurvivesHostRestoration() async throws {
        let custom = "Vane Identity Fixture/1.0 (no Safari token)"
        Settings.userAgent = custom
        let context = try await install(version: 2)
        let identity = context.uniqueIdentifier
        let (action, web) = try await popup(context)
        try await assertIdentity(in: web, expected: custom)
        action.closePopup()
        ExtensionHost.forget(profile)
        let restoredHost = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(10)
        while restoredHost.installed.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try XCTUnwrap(restoredHost.installed.first)
        XCTAssertEqual(restored.uniqueIdentifier, identity)
        let (restoredAction, restoredWeb) = try await popup(restored)
        try await assertIdentity(in: restoredWeb, expected: custom)
        restoredAction.closePopup()
    }
}
