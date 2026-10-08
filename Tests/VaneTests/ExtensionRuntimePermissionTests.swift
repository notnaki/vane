import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionRuntimePermissionTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var view: WKWebView?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("runtime-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Runtime Fixture","version":"1.0","optional_permissions":["cookies"],"optional_host_permissions":["https://example.test/*"],"options_ui":{"page":"options.html"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Runtime fixture</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
    }

    override func tearDown() async throws {
        view?.stopLoading(); view = nil
        let host = ExtensionHost.host(for: profile)
        for context in host.installed { host.remove(context) }
        ExtensionHost.forget(profile)
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        try? FileManager.default.removeItem(at: folder)
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
            XCTAssertTrue(review.limitations.contains { $0.contains("contextMenus") })
            XCTAssertTrue(review.limitations.contains { $0.contains("commands") })
            return true
        }
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertFalse(context.hasPermission(WKWebExtension.Permission(rawValue: "nativeMessaging")))
        let web = try await options(context)
        let hidden = try await web.evaluateJavaScript("typeof browser.runtime.sendNativeMessage + ':' + typeof browser.contextMenus")
        XCTAssertEqual(hidden as? String, "undefined:undefined")
        let (granted, _) = await host.webExtensionController(host.controller,
            promptForPermissions: [WKWebExtension.Permission(rawValue: "nativeMessaging")], in: nil, for: context)
        XCTAssertTrue(granted.isEmpty)
    }

}
