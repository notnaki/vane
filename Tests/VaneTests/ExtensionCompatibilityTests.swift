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
        ExtensionHost.forget(profile)
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        ExtensionConsent.remove(for: folder, profileID: profile)
        try? FileManager.default.removeItem(at: folder)
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
        defer { tab.tearDown(); other.tearDown(); privateTab.tearDown() }
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
}
