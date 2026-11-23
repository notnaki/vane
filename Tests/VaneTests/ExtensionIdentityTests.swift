import AppKit
import WebKit
import XCTest
@testable import vane

/// `chrome.identity`'s web sign-in: a worker that reads its redirect URL at the top level,
/// as Copyleaks does, and flows that end at that URL, close, or need the user.
@MainActor final class ExtensionIdentityTests: XCTestCase {
    /// SHA-256 of bytes 1…39, the first 16 bytes mapped to a–p: Chrome's ID for this key.
    private static let key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYn"
    private static let id = "jjcfimejjljfpcibdjjobingfbgmfhfi"
    private var profile = UUID()
    private var folder: URL!
    private var originalPolicy: NSApplication.ActivationPolicy!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        originalPolicy = NSApp.activationPolicy()
        profile = UUID()
        folder = Store.directory.appendingPathComponent("extension-identity-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Identity Fixture","description":"Fixture","version":"1.0","key":"\#(Self.key)","permissions":["identity","storage"],"background":{"service_worker":"worker.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("""
            // At the top level, as real workers read it: a missing method fails the background.
            const redirect = chrome.identity.getRedirectURL();
            chrome.runtime.onMessage.addListener((message, sender, respond) => {
                if (message.redirect) {
                    respond([redirect, chrome.identity.getRedirectURL('cb?x=1'), typeof chrome.identity.getAuthToken].join('|'));
                    return;
                }
                chrome.identity.launchWebAuthFlow({url: message.url, interactive: message.interactive})
                    .then(respond, error => respond('error: ' + error.message));
                return true;
            });
            """.utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data("<title>Identity page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
    }

    override func tearDown() async throws {
        ExtensionHost.forget(profile)
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release([profile])
        NSApp.setActivationPolicy(originalPolicy)
    }

    private func wait(_ description: String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testChromeIDAndBridgeRequests() throws {
        XCTAssertEqual(ExtensionIdentityAPI.chromeID(storeID: nil, manifest: ["key": Self.key]), Self.id)
        XCTAssertEqual(ExtensionIdentityAPI.chromeID(storeID: "gplcmncpklkdjiccbknjjkoidpgkcakd", manifest: ["key": Self.key]),
                       "gplcmncpklkdjiccbknjjkoidpgkcakd", "The store's ID is the one its OAuth provider knows")
        XCTAssertNil(ExtensionIdentityAPI.chromeID(storeID: nil, manifest: [:]))
        XCTAssertEqual(ExtensionIdentityAPI.redirectHost(manifest: [:], runtimeID: "ABC-1"), "abc-1.chromiumapp.org")

        let base = URL(string: "webkit-extension://abc/")!
        let request = try XCTUnwrap(try ExtensionIdentityAPI.Request(
            URL(string: "webkit-extension://abc/__vane_identity__?url=https%3A%2F%2Fauth.example%2Fo%3Fa%3D1&interactive=true"), base: base))
        XCTAssertEqual(request.url.absoluteString, "https://auth.example/o?a=1")
        XCTAssertTrue(request.interactive)
        XCTAssertNil(try ExtensionIdentityAPI.Request(URL(string: "webkit-extension://other/__vane_identity__?url=https%3A%2F%2Fa.example"), base: base))
        XCTAssertNil(try ExtensionIdentityAPI.Request(URL(string: "webkit-extension://abc/page.html?url=https%3A%2F%2Fa.example"), base: base))
        for page in ["javascript%3Aalert(1)", "file%3A%2F%2F%2Fetc%2Fpasswd", ""] {
            XCTAssertThrowsError(try ExtensionIdentityAPI.Request(URL(string: "webkit-extension://abc/__vane_identity__?url=" + page), base: base), page)
        }
    }

    func testWorkerReadsRedirectAndCompletesWebAuthFlows() async throws {
        let server = try NavigationHTTPFixture()
        defer { server.stop() }
        try await wait("loopback server") { server.port != nil }
        let done = URL(string: "https://\(Self.id).chromiumapp.org/cb?code=redirected")!
        server.redirects["/silent"] = done
        server.pages["/script"] = "<title>Auth</title><script>setTimeout(() => location.href = 'https://\(Self.id).chromiumapp.org/cb?code=script#state', 200)</script>"
        server.pages["/form"] = """
            <title>Sign in</title><meta name="color-scheme" content="light dark">
            <body style="font: 15px -apple-system; margin: 40px; color: CanvasText; background: Canvas">
            <h2>Fixture sign-in</h2><p>A loopback page standing in for a provider.</p>
            <p><input placeholder="Email" style="width: 100%; padding: 8px"></p>
            <p><button>Continue</button></p></body>
            """

        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first)
            XCTAssertTrue(context.errors.isEmpty, "\(context.errors.map(\.localizedDescription))")
            let notes = (host.entries.first?.compatibility ?? []).filter { $0.hasPrefix("identity") }
            XCTAssertEqual(notes.count, 1, "\(notes)")
            XCTAssertFalse(notes.contains(where: ExtensionDiagnostics.isUnsupported), "Provided, not missing: \(notes)")

            let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
            defer { page.stopLoading() }
            page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            try await wait("extension page") { !page.isLoading && page.title == "Identity page" }
            func ask(_ message: String) async throws -> String? {
                try await page.callAsyncJavaScript("return String(await chrome.runtime.sendMessage(\(message)))",
                                                   arguments: [:], in: nil, contentWorld: .page) as? String
            }
            func flow(_ path: String, interactive: Bool) async throws -> String? {
                try await ask("{url: '\(try server.url(path).absoluteString)', interactive: \(interactive)}")
            }

            // The worker started, and its redirect URL is the one Chrome gives this key.
            let redirect = try await ask("{redirect: true}")
            XCTAssertEqual(redirect, "https://\(Self.id).chromiumapp.org/|https://\(Self.id).chromiumapp.org/cb?x=1|undefined")
            let pageRedirect = try await page.callAsyncJavaScript("return chrome.identity.getRedirectURL()",
                                                                  arguments: [:], in: nil, contentWorld: .page) as? String
            XCTAssertEqual(pageRedirect, "https://\(Self.id).chromiumapp.org/")

            // Without a window: a server redirect completes, a page that stays needs the user.
            let silent = try await flow("/silent", interactive: false)
            XCTAssertEqual(silent, done.absoluteString)
            let stays = try await flow("/form", interactive: false)
            XCTAssertEqual(stays, "error: User interaction required.")
            XCTAssertFalse(NSApp.windows.contains { $0.identifier == ExtensionAuthFlow.windowIdentifier && $0.isVisible })

            // With one: the page's own navigation to the redirect URL ends it, unloaded.
            let scripted = try await flow("/script", interactive: true)
            XCTAssertEqual(scripted, "https://\(Self.id).chromiumapp.org/cb?code=script#state")
            XCTAssertFalse(NSApp.windows.contains { $0.identifier == ExtensionAuthFlow.windowIdentifier && $0.isVisible })

            // Closing the window is the user's refusal.
            let closed = Task { try await flow("/form", interactive: true) }
            var window: NSWindow?
            try await wait("sign-in window") {
                window = NSApp.windows.first { $0.identifier == ExtensionAuthFlow.windowIdentifier && $0.isVisible }
                return (window?.contentView as? WKWebView).map { !$0.isLoading && $0.title == "Sign in" } ?? false
            }
            let shown = try XCTUnwrap(window)
            let web = try XCTUnwrap(shown.contentView as? WKWebView)
            XCTAssertEqual(shown.subtitle, "127.0.0.1", "The page's host, not the extension's word")
            XCTAssertTrue(web.configuration.websiteDataStore === host.controller.configuration.defaultWebsiteDataStore,
                          "The profile's own cookies")
            if let directory = ProcessInfo.processInfo.environment["VANE_AUTH_SCREENSHOT_DIR"] {
                let original = NSApp.appearance
                defer { NSApp.appearance = original }
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .seconds(1))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(shown.windowNumber), directory + "/auth-window-\(name).png"]
                    try capture.run()
                    capture.waitUntilExit()
                }
            }
            shown.performClose(nil)
            let refused = try await closed.value
            XCTAssertEqual(refused, "error: The user did not approve access.")
            try host.remove(folder: folder.path)
        } catch { failure = error }
        ExtensionHost.forget(profile)
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }
}
