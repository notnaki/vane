import JavaScriptCore
import WebKit
import XCTest
@testable import vane

/// The host half of Vane's Chromium stand-ins: bridge requests, tab groups, and the
/// `chrome` alias on pages an extension lets message it.
@MainActor final class ExtensionChromiumGapsTests: XCTestCase {
    func testBridgeRequestsBelongToTheOwningExtensionOnly() throws {
        let base = URL(string: "webkit-extension://abc/")!
        let request = try XCTUnwrap(ExtensionChromiumGaps.Request(
            URL(string: "webkit-extension://abc/__vane_gaps__?op=group&args=%7B%22tabIds%22%3A%5B4%5D%7D"), base: base))
        XCTAssertEqual(request.operation, "group")
        XCTAssertEqual(request.arguments["tabIds"] as? [Int], [4])
        // As `URLSearchParams` writes it: a space is `+`, a plus `%2B`.
        let spaced = try XCTUnwrap(ExtensionChromiumGaps.Request(
            URL(string: "webkit-extension://abc/__vane_gaps__?op=ws.send&args=%7B%22data%22%3A%22a+b%2Bc%22%7D"), base: base))
        XCTAssertEqual(spaced.operation, "ws.send")
        XCTAssertEqual(spaced.arguments["data"] as? String, "a b+c")
        XCTAssertNil(ExtensionChromiumGaps.Request(URL(string: "webkit-extension://other/__vane_gaps__?op=groups"), base: base))
        XCTAssertNil(ExtensionChromiumGaps.Request(URL(string: "webkit-extension://abc/page.html?op=groups"), base: base))
        XCTAssertNil(ExtensionChromiumGaps.Request(URL(string: "webkit-extension://abc/__vane_gaps__"), base: base))
        XCTAssertEqual(ExtensionChromiumGaps.reply(.success(3)), #"[vane-gaps] {"value":3}"#)
        XCTAssertEqual(ExtensionChromiumGaps.reply(.failure(ExtensionHost.Failure("No."))), #"[vane-gaps] {"error":"No."}"#)
    }

    /// `hasDocument` waits for the load; a crashed WebContent process drops the document; the
    /// main frame never leaves the extension (PM-8014 races Bitwarden's `withDocument` on these).
    func testOffscreenDocumentIsThereOnlyOnceLoadedAndGoesWithItsProcess() async throws {
        let base = URL(string: "about:blank")!
        let document = OffscreenDocument(WKWebView(frame: .zero, configuration: WKWebViewConfiguration()), base: base)
        var terminated = 0
        document.terminated = { terminated += 1 }
        let loading = Task { await document.load(base) }
        XCTAssertFalse(document.loaded, "a document still loading must not count as there")
        let loaded = await loading.value
        XCTAssertTrue(loaded)
        XCTAssertTrue(document.loaded)
        XCTAssertIdentical(document.web.navigationDelegate, document, "the delegate must outlive the first load")
        document.webViewWebContentProcessDidTerminate(document.web)
        XCTAssertEqual(terminated, 1)

        let leaving = OffscreenDocument(WKWebView(frame: .zero, configuration: WKWebViewConfiguration()), base: base)
        let left = await leaving.load(URL(string: "https://example.invalid/")!)
        XCTAssertFalse(left)
        XCTAssertFalse(leaving.loaded)
    }

    func testACredentialedFetchCarriesOnlyItsOwnSitesCookies() throws {
        func cookie(_ name: String, _ domain: String, _ path: String = "/", secure: Bool = false) -> HTTPCookie {
            var fields: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: domain, .path: path]
            if secure { fields[.secure] = "TRUE" }
            return HTTPCookie(properties: fields)!
        }
        let all = [cookie("site", ".claude.ai"), cookie("api", "claude.ai", "/api"), cookie("other", "evil.example"),
                   cookie("safe", "claude.ai", secure: true)]
        func names(_ url: String) -> Set<String> { Set(ExtensionHost.cookies(all, for: URL(string: url)!).map(\.name)) }
        XCTAssertEqual(names("https://claude.ai/api/x"), ["site", "api", "safe"])
        XCTAssertEqual(names("https://claude.ai/apix"), ["site", "safe"], "A path matches on a / boundary")
        XCTAssertEqual(Set(ExtensionHost.cookies([cookie("slash", "claude.ai", "/api/")], for: URL(string: "https://claude.ai/api/")!).map(\.name)),
                       ["slash"], "A trailing slash is part of the path")
        XCTAssertEqual(names("http://claude.ai/"), ["site"], "A secure cookie goes over https only")
        XCTAssertEqual(names("https://evil.example/"), ["other"], "A redirect's next hop gets only its own cookies")
    }

    func testChromeAliasOnlyOnPagesAnExtensionListsForMessaging() throws {
        XCTAssertNil(ExtensionChromiumGaps.webPageScript([("a", ["name": "No pages"])]))
        let script = try XCTUnwrap(ExtensionChromiumGaps.webPageScript([
            ("fcoeoabgfenejglbffodgkkbkcdhcgfn", ["externally_connectable": ["matches": ["https://claude.ai/*", "https://*.claude.ai/*"]]]),
            ("b", ["name": "No pages"])
        ]))
        XCTAssertTrue(script.contains("globalThis.browser"))
        XCTAssertTrue(script.contains("fcoeoabgfenejglbffodgkkbkcdhcgfn"))
        XCTAssertTrue(script.contains("Receiving end does not exist"), "an extension that isn't installed fails, as in Chrome")
        func matches(_ pattern: String, _ url: String) throws -> Bool {
            let regex = try NSRegularExpression(pattern: XCTUnwrap(ExtensionChromiumGaps.pageRegex(pattern)))
            return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        XCTAssertTrue(try matches("https://claude.ai/*", "https://claude.ai/oauth/authorize?x=1"))
        XCTAssertTrue(try matches("https://*.claude.ai/*", "https://claude.ai/new"))
        XCTAssertTrue(try matches("https://*.claude.ai/*", "https://a.b.claude.ai/"))
        XCTAssertTrue(try matches("*://example.com/app*", "http://example.com:8080/app/1"))
        XCTAssertNil(ExtensionChromiumGaps.webPageScript([("a", ["externally_connectable": ["matches": ["*://*/*"]]])]), "never every site")
        XCTAssertFalse(try matches("https://*.claude.ai/*", "https://evilclaude.ai/"))
        XCTAssertFalse(try matches("https://claude.ai/*", "https://claude.ai.evil.test/"))
        XCTAssertFalse(try matches("https://claude.ai/*", "http://claude.ai/"))
        XCTAssertFalse(try matches("https://example.com/app*", "https://example.com/other"))
        for invalid in ["<all_urls>", "ftp://a.example/*", "https://a.*.example/*", "https://", "https://*/*", "*://*/*", "*://*.com/*"] {
            XCTAssertNil(ExtensionChromiumGaps.pageRegex(invalid), invalid)
        }
    }

    func testDevToolsPageAndOffscreenGetChromesMissingMembers() throws {
        // The stand-in script, run against WebKit's devtools shape: panels.create, themeName,
        // inspectedWindow and network.onNavigated are WebKit's; the rest are Vane's.
        let js = try XCTUnwrap(JSContext())
        js.exceptionHandler = { _, error in XCTFail("\(error?.toString() ?? "")") }
        js.evaluateScript("""
            const event = () => ({addListener() {}, removeListener() {}, hasListener: () => false});
            globalThis.chrome = {
              runtime: {getManifest: () => ({manifest_version: 3, permissions: ['offscreen']}), getURL: path => 'webkit-extension://abc' + path, id: 'abc'},
              tabs: {create: () => Promise.reject(new Error('unused'))},
              devtools: {panels: {create() {}, themeName: 'dark', onThemeChanged: event()}, network: {onNavigated: event()},
                         inspectedWindow: {eval() {}, reload() {}, tabId: 4}}
            };
            """)
        js.evaluateScript(ExtensionChromiumGaps.script)
        let answer = js.evaluateScript("""
            [typeof chrome.devtools.panels.elements.onSelectionChanged.addListener, typeof chrome.devtools.panels.sources.onSelectionChanged.addListener,
             typeof chrome.devtools.panels.elements.createSidebarPane, typeof chrome.devtools.network.onRequestFinished.addListener,
             typeof chrome.devtools.network.getHAR, chrome.devtools.panels.themeName, chrome.offscreen.Reason.CLIPBOARD,
             typeof chrome.offscreen.createDocument, typeof chrome.offscreen.closeDocument].join(',')
            """)?.toString()
        XCTAssertEqual(answer, "function,function,undefined,function,undefined,dark,CLIPBOARD,function,function")
    }
}
