import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionPageUITests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var title: String!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        title = "Extension input \(UUID())"
        folder = Store.directory.appendingPathComponent("extension-input-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": title!, "version": "1.0",
            "options_ui": ["page": "input.html"], "action": ["default_popup": "input.html"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Input ready</title><input id=file type=file multiple><p>File picker fixture</p>".utf8)
            .write(to: folder.appendingPathComponent("input.html"))
    }

    override func tearDown() async throws {
        if let profile { ExtensionHost.forget(profile) }
        for window in windows {
            if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        windows.removeAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let profile { try await NativeFixtureProfileCleanup.release([profile]) }
    }

    // Own the AppKit loop inside the test invocation. Acquiring it from async
    // XCTest setUp nests the framework's setup waiter around NSApplication.run.
    private func withLoop(_ body: () async throws -> Void) async throws {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do {
            _ = try await ExtensionHost.host(for: profile).load(folder, installing: true) { _ in true }
            try await body()
        } catch { failure = error }
        ExtensionHost.forget(profile)
        for window in windows {
            if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        windows.removeAll()
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Loop cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func wait(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), description)
        if !condition() { throw NSError(domain: "ExtensionPageUI.\(description)", code: 1) }
    }

    private func options() async throws -> (ExtensionHost, WKWebExtensionContext, WKWebView, NSWindow) {
        let host = ExtensionHost.host(for: profile)
        let context = try XCTUnwrap(host.installed.first)
        try await host.webExtensionController(host.controller, openOptionsPageFor: context)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == title && $0.isVisible })
        windows.append(window)
        let web = try XCTUnwrap(window.contentView as? WKWebView)
        try await LibraryFocusFixture.admitForeground(window)
        try await wait("Options document loaded") { web.title == "Input ready" && !web.isLoading }
        return (host, context, web, window)
    }

    private func picker(_ web: WKWebView, window: NSWindow) async throws -> NSOpenPanel {
        try await LibraryFocusFixture.admitForeground(window)
        XCTAssertTrue(web.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(web.uiDelegate, "Production extension views need a retained file-picker delegate")
        _ = try await web.evaluateJavaScript("document.getElementById('file').click()")
        try await wait("Picker attached to requesting extension view") { window.attachedSheet is NSOpenPanel }
        let panel = try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.allowsMultipleSelection)
        return panel
    }

    func testOptionsPickerCanCancelAndReopen() async throws {
        try await withLoop {
            let (_, _, web, window) = try await options()
            let panel = try await picker(web, window: window)
            panel.cancel(nil)
            try await wait("Cancelled panel retired") { window.attachedSheet == nil }
            let count = try await web.evaluateJavaScript("file.files.length") as? Int
            XCTAssertEqual(count, 0)
            let reopened = try await picker(web, window: window)
            reopened.cancel(nil)
            try await wait("Reopened panel retired") { window.attachedSheet == nil }
        }
    }

    func testNavigationCancelsOptionsPicker() async throws {
        try await withLoop {
            let (_, _, web, window) = try await options()
            let panel = try await picker(web, window: window)
            web.loadHTMLString("<title>Replaced</title><p>New document</p>", baseURL: nil)
            try await wait("Navigation retires picker") { window.attachedSheet == nil && !panel.isVisible }
        }
    }

    func testDisableCancelsOptionsPicker() async throws {
        try await withLoop {
            let (host, _, web, window) = try await options()
            let panel = try await picker(web, window: window)
            try host.disable(folder.path)
            try await wait("Disabled extension retires picker") { !panel.isVisible && !window.isVisible }
        }
    }

    func testClosingOptionsCancelsPicker() async throws {
        try await withLoop {
            let (_, _, web, window) = try await options()
            let panel = try await picker(web, window: window)
            window.close()
            try await wait("Closed options retires picker") { !panel.isVisible }
        }
    }

    func testPopupDismissalCancelsPicker() async throws {
        try await withLoop {
            let host = ExtensionHost.host(for: profile)
            let context = try XCTUnwrap(host.installed.first)
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 350),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            let store = TabStore(profileID: profile, session: [])
            store.window = window
            defer {
                store.window = nil
                let tabs = store.everyTab
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
            }
            let anchor = NSView(frame: CGRect(x: 200, y: 180, width: 30, height: 30))
            window.contentView?.addSubview(anchor)
            try await LibraryFocusFixture.admitForeground(window)
            host.run(context, for: nil, from: anchor)
            let action = try XCTUnwrap(context.action(for: nil))
            try await wait("Actual compact popup presented") { host.actionPopupWindow(context, for: nil)?.isVisible == true }
            let web = try XCTUnwrap(action.popupWebView)
            try await wait("Popup document loaded") { web.title == "Input ready" && !web.isLoading }
            let popupWindow = try XCTUnwrap(web.window)
            let panel = try await picker(web, window: popupWindow)
            popupWindow.close()
            try await wait("Popup dismissal retires picker") {
                !panel.isVisible && popupWindow.attachedSheet == nil && !popupWindow.isVisible
                    && host.actionPopupWindow(context, for: nil) == nil
            }
        }
    }
    func testActualSDKPopupStillOpensBlankTargets() async throws {
        try await withLoop {
            let host = ExtensionHost.host(for: profile)
            let context = try XCTUnwrap(host.installed.first)
            let store = TabStore(profileID: profile, session: [])
            let tab = store.newBlankTab()
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 350),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            store.window = window
            defer {
                store.window = nil
                let tabs = store.everyTab
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
            }
            let parentURL = URL(string: "https://popup-parent.invalid/")!
            let parentWeb = tab.web
            parentWeb.frame = try XCTUnwrap(window.contentView).bounds
            window.contentView = parentWeb
            try await LibraryFocusFixture.admitForeground(window)
            tab.expectNavigation(parentWeb.loadHTMLString("<title>Origin ready</title><p>Local popup owner</p>", baseURL: parentURL))
            try await wait("Live originating document and SDK tab admitted") {
                !parentWeb.isLoading && parentWeb.title == "Origin ready" && parentWeb.url == parentURL
                    && tab.currentURL == parentURL && parentWeb.window === window
            }
            host.sync()
            host.run(context, for: tab, from: parentWeb)
            let action = try XCTUnwrap(host.action(context, for: tab))
            try await wait("SDK popup presented in exact compact owner") {
                guard let owner = host.actionPopupWindow(context, for: tab) else { return false }
                return owner.isVisible && action.popupWebView?.window === owner
            }
            let web = try XCTUnwrap(action.popupWebView)
            try await wait("SDK popup document ready") { web.title == "Input ready" && !web.isLoading }
            let delegate = try XCTUnwrap(web.uiDelegate as? ExtensionPageUI)
            XCTAssertNotNil(delegate.originalUIDelegate, "File selection must preserve the existing popup delegate chain")
            _ = try await web.evaluateJavaScript("""
                const link = document.createElement('a');
                link.href = 'https://popup-forwarding.invalid/'; link.target = '_blank';
                document.body.appendChild(link); link.click();
                """)
            try await wait("SDK blank-target callback creates a profile-owned tab") {
                store.tabs.contains { $0.currentURL?.host == "popup-forwarding.invalid" }
            }
            XCTAssertEqual(store.profileID, profile)
            host.closeActionPopup(context, for: tab)
        }
    }

    private final class OriginalDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
        var policies = 0, starts = 0, commits = 0, terminations = 0, confirms = 0
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            policies += 1
            decisionHandler(.cancel)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { starts += 1 }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { commits += 1 }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminations += 1 }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            confirms += 1
            completionHandler(true)
        }
    }

    func testOriginalPolicyLifecycleAndUnknownUIDelegateMethodsArePreserved() async throws {
        try await withLoop {
            let (_, context, web, _) = try await options()
            let previousUI = web.uiDelegate, previousNavigation = web.navigationDelegate
            defer { web.uiDelegate = previousUI; web.navigationDelegate = previousNavigation }
            let original = OriginalDelegate()
            web.uiDelegate = original; web.navigationDelegate = original
            let proxy = ExtensionPageUI(web: web, context: context, isEnabled: { true })
            web.uiDelegate = proxy; web.navigationDelegate = proxy
            let confirmed = try await web.evaluateJavaScript("confirm('Forwarding fixture')") as? Bool
            XCTAssertEqual(confirmed, true)
            XCTAssertEqual(original.confirms, 1)
            proxy.webView(web, didStartProvisionalNavigation: nil)
            proxy.webView(web, didCommit: nil)
            proxy.webViewWebContentProcessDidTerminate(web)
            XCTAssertEqual(original.starts, 1)
            XCTAssertEqual(original.commits, 1)
            XCTAssertEqual(original.terminations, 1)
            web.loadHTMLString("<title>Must be cancelled</title>", baseURL: nil)
            try await wait("Original navigation policy invoked") { original.policies == 1 }
            XCTAssertEqual(web.title, "Input ready")
            proxy.invalidate()
            XCTAssertTrue(web.uiDelegate === original)
            XCTAssertTrue(web.navigationDelegate === original)
        }
    }

    private final class EmptyNavigationDelegate: NSObject, WKNavigationDelegate {}

    func testOriginalDelegateWithoutPolicyStillAllowsNavigation() async throws {
        try await withLoop {
            let (_, context, web, _) = try await options()
            let previousUI = web.uiDelegate, previousNavigation = web.navigationDelegate
            defer { web.uiDelegate = previousUI; web.navigationDelegate = previousNavigation }
            let original = EmptyNavigationDelegate()
            web.navigationDelegate = original
            let proxy = ExtensionPageUI(web: web, context: context, isEnabled: { true })
            web.uiDelegate = proxy; web.navigationDelegate = proxy
            var destination = URLComponents(url: try XCTUnwrap(context.optionsPageURL), resolvingAgainstBaseURL: false)!
            destination.query = "fallback=1"
            let url = try XCTUnwrap(destination.url)
            web.load(URLRequest(url: url))
            try await wait("Missing original policy selector uses the fallback") {
                web.url == url && !web.isLoading && web.title == "Input ready"
            }
            proxy.invalidate()
            XCTAssertTrue(web.navigationDelegate === original)
        }
    }

}
