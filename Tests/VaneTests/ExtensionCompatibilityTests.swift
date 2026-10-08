import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionCompatibilityTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var views: [WKWebView] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("compat-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Compatibility Fixture","version":"1.0","permissions":["storage"],"options_ui":{"page":"options.html"},"content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"]}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Extension fixture</title><p>Synthetic extension</p>".utf8)
            .write(to: folder.appendingPathComponent("options.html"))
        try Data("document.documentElement.dataset.vaneExtension='executed';".utf8)
            .write(to: folder.appendingPathComponent("content.js"))
    }

    override func tearDown() async throws {
        for view in views { view.stopLoading(); view.removeFromSuperview() }
        views.removeAll()
        let host = ExtensionHost.host(for: profile)
        for context in host.installed { host.remove(context) }
        ExtensionHost.forget(profile)
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        ExtensionConsent.remove(for: folder, profileID: profile)
        try? FileManager.default.removeItem(at: folder)
    }

    func testDeletingProfileRemovesOnlyItsExtensionIdentities() {
        let manager = ProfileManager.shared
        let deleted = manager.create(name: "Extension deletion fixture")
        let retained = manager.create(name: "Extension retained fixture")
        let deletedKey = ProfileManager.defaultsKey("extensionIdentifiers", deleted.id)
        let retainedKey = ProfileManager.defaultsKey("extensionIdentifiers", retained.id)
        defer {
            _ = manager.delete(deleted.id)
            _ = manager.delete(retained.id)
            UserDefaults.vane.removeObject(forKey: deletedKey)
            UserDefaults.vane.removeObject(forKey: retainedKey)
        }
        UserDefaults.vane.set([folder.path: UUID().uuidString], forKey: deletedKey)
        UserDefaults.vane.set([folder.path: UUID().uuidString], forKey: retainedKey)
        XCTAssertTrue(manager.delete(deleted.id))
        XCTAssertNil(UserDefaults.vane.object(forKey: deletedKey))
        XCTAssertNotNil(UserDefaults.vane.object(forKey: retainedKey))
    }

    private func load() async throws -> WKWebExtensionContext {
        let host = ExtensionHost.host(for: profile)
        let accepted = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        return try XCTUnwrap(host.installed.first)
    }

    private func options(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let config = try XCTUnwrap(context.webViewConfiguration)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        views.append(view)
        view.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        let deadline = ContinuousClock.now + .seconds(10)
        while view.isLoading || view.title != "Extension fixture" {
            if ContinuousClock.now >= deadline { throw NSError(domain: "ExtensionLoadTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return view
    }

    func testLocalStorageAndRuntimeIdentitySurviveHostRestore() async throws {
        let first = try await load()
        let firstID = first.uniqueIdentifier
        let view = try await options(first)
        _ = try await view.callAsyncJavaScript("await browser.storage.local.set({fixture:'saved synthetic value'}); return true;",
                                              arguments: [:], in: nil, contentWorld: .page)
        view.stopLoading()
        view.removeFromSuperview()
        ExtensionHost.forget(profile)
        // The approved folder is restored through the production launch path.
        let host = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(10)
        while host.installed.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try XCTUnwrap(host.installed.first)
        let restoredView = try await options(restored)
        let saved = try await restoredView.callAsyncJavaScript("return (await browser.storage.local.get('fixture')).fixture ?? 'missing';",
                                                               arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(restored.uniqueIdentifier, firstID, "runtime.id must remain stable after relaunch")
        XCTAssertEqual(restored.baseURL, first.baseURL, "Extension page origins must remain stable too")
        XCTAssertEqual(saved as? String, "saved synthetic value", "Extension settings must survive host restore")
        host.remove(restored)
        let reinstalled = try await load()
        XCTAssertNotEqual(reinstalled.uniqueIdentifier, firstID, "A new installation cannot regain uninstalled extension data")
        let reinstalledView = try await options(reinstalled)
        let removed = try await reinstalledView.callAsyncJavaScript("return (await browser.storage.local.get('fixture')).fixture ?? 'missing';",
                                                                   arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(removed as? String, "missing")
    }

    func testApprovedContentScriptExecutesOnlyInItsProfileAndMatchingOrigin() async throws {
        _ = try await load()
        let tab = Tab(profileID: profile)
        let other = Tab(profileID: UUID())
        let privateTab = Tab(isPrivate: true)
        defer {
            tab.tearDown(); other.tearDown(); privateTab.tearDown()
            ExtensionHost.forget(other.profileID)
        }
        for candidate in [tab, other, privateTab] {
            candidate.web.loadHTMLString("<title>Content fixture</title>", baseURL: URL(string: "https://example.test/page"))
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while [tab, other, privateTab].contains(where: { $0.web.isLoading || $0.web.title != "Content fixture" }),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let executed = try await tab.web.evaluateJavaScript("document.documentElement.dataset.vaneExtension ?? 'missing'")
        XCTAssertEqual(executed as? String, "executed")
        for candidate in [other, privateTab] {
            let isolated = try await candidate.web.evaluateJavaScript("document.documentElement.dataset.vaneExtension ?? 'missing'")
            XCTAssertEqual(isolated as? String, "missing")
        }
        tab.web.loadHTMLString("<title>Other origin</title>", baseURL: URL(string: "https://other.test/"))
        while tab.web.isLoading || tab.web.title != "Other origin" {
            if ContinuousClock.now >= deadline { throw NSError(domain: "ContentScriptTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let unmatched = try await tab.web.evaluateJavaScript("document.documentElement.dataset.vaneExtension ?? 'missing'")
        XCTAssertEqual(unmatched as? String, "missing")
    }
    func testMV2BackgroundAndMV3WorkerMessagingStorageAndAction() async throws {
        let host = ExtensionHost.host(for: profile)
        for version in [2, 3] {
            var manifest: [String: Any] = ["manifest_version": version, "name": "Background Fixture", "version": "1.0",
                "permissions": ["storage", "tabs"], "options_ui": ["page": "options.html"]]
            manifest[version == 2 ? "browser_action" : "action"] = ["default_popup": "options.html"]
            manifest["background"] = version == 2 ? ["scripts": ["background.js"], "persistent": true] as [String: Any]
                : ["service_worker": "background.js"]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("""
                browser.runtime.onMessage.addListener(async message => {
                    await browser.storage.local.set({background:message.value});
                    await (browser.action ?? browser.browserAction).setBadgeText({text:'OK'});
                    return {value:message.value, count:(await browser.tabs.query({})).length};
                });
                """.utf8).write(to: folder.appendingPathComponent("background.js"))
            let context = try await load()
            let web = try await options(context)
            let reply = try await web.callAsyncJavaScript("return await browser.runtime.sendMessage({value:'MV fixture'});",
                arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(reply?["value"] as? String, "MV fixture")
            XCTAssertEqual(reply?["count"] as? Int, 0)
            let stored = try await web.callAsyncJavaScript("return (await browser.storage.local.get('background')).background;",
                arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(stored as? String, "MV fixture")
            XCTAssertEqual(context.action(for: nil)?.badgeText, "OK")
            XCTAssertTrue(context.action(for: nil)?.presentsPopup == true)
            host.remove(context)
            XCTAssertFalse(context.isLoaded)
            XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        }
    }

}
