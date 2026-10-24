import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionUserAgentTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var previousUserAgent: Any?

    private func trace(_ stage: String) {
        let message = "[ExtensionUserAgentTests pid=\(ProcessInfo.processInfo.processIdentifier) main=\(Thread.isMainThread)] \(stage)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        previousUserAgent = UserDefaults.vane.object(forKey: "userAgent")
        UserDefaults.vane.removeObject(forKey: "userAgent")
        profile = UUID()
        folder = Store.directory.appendingPathComponent("user-agent-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        trace("setUp complete")
    }

    override func tearDown() async throws {
        trace("tearDown: removing contexts")
        let host = ExtensionHost.host(for: profile)
        for context in host.installed { host.remove(context) }
        trace("tearDown: forgetting host")
        ExtensionHost.forget(profile)
        UserDefaults.vane.set(previousUserAgent, forKey: "userAgent")
        trace("tearDown: restoring settings")
        Settings.apply()
        try? FileManager.default.removeItem(at: folder)
        trace("tearDown complete")
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
        trace("Develop: begin install")
        let context = try await install(version: 2)
        trace("Develop: installed")
        let host = ExtensionHost.host(for: profile)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 440, y: 250, width: 28, height: 28))
        try XCTUnwrap(window.contentView).addSubview(anchor)
        trace("Develop: window created")
        window.makeKeyAndOrderFront(nil)
        trace("Develop: window ordered")
        defer {
            trace("Develop: closing owner window")
            window.close()
            trace("Develop: owner window closed")
        }

        trace("Develop: before host.run")
        host.run(context, for: nil, from: anchor)
        trace("Develop: host.run returned")
        let (action, web) = try await popup(context)
        trace("Develop: popup scripts ready frame=\(web.frame)")
        try await waitForPresentation(action)
        trace("Develop: presented frame=\(web.frame) content=\(String(describing: action.popupPopover?.contentSize))")
        try await assertIdentity(in: web, expected: safariUA)
        let controller = host.controller
        let granted = context.grantedPermissions
        let sites = context.grantedPermissionMatchPatterns
        let custom = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.0; rv:135.0) Gecko/20100101 Firefox/135.0"
        trace("Develop: initial identity checked; switching to Firefox")
        Settings.userAgent = custom
        trace("Develop: switched to Firefox")
        let live = try await web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(live, custom)
        Settings.userAgent = safariUA
        let defaultLive = try await web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(defaultLive, safariUA)
        Settings.userAgent = custom
        trace("Develop: live UA transitions checked; closing popup")
        try await closePresentedPopup(action)
        trace("Develop: popup closed; recreating")
        let (recreatedAction, recreated) = try await popup(context)
        trace("Develop: recreated popup scripts ready")
        XCTAssertFalse(recreated === web, "Recreation must inspect a fresh popup, not cached startup values")
        try await assertIdentity(in: recreated, expected: custom, startup: safariUA)
        XCTAssertTrue(ExtensionHost.host(for: profile).controller === controller)
        XCTAssertTrue(context.isLoaded)
        XCTAssertEqual(context.grantedPermissions, granted)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, sites)
        trace("Develop: assertions evaluated; closing recreated popup")
        recreatedAction.closePopup()
        trace("Develop: recreated popup close returned")
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
        trace("Develop: creating close notification expectation")
        let closed = XCTNSNotificationExpectation(name: NSPopover.didCloseNotification, object: popover)
        trace("Develop: before action.closePopup")
        action.closePopup()
        trace("Develop: action.closePopup returned; waiting for didClose")
        await fulfillment(of: [closed], timeout: 5)
        trace("Develop: didClose notification wait returned")
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
