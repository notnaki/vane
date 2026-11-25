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
        XCTAssertNil(ExtensionChromiumGaps.Request(URL(string: "webkit-extension://other/__vane_gaps__?op=groups"), base: base))
        XCTAssertNil(ExtensionChromiumGaps.Request(URL(string: "webkit-extension://abc/page.html?op=groups"), base: base))
        XCTAssertNil(ExtensionChromiumGaps.Request(URL(string: "webkit-extension://abc/__vane_gaps__"), base: base))
        XCTAssertEqual(ExtensionChromiumGaps.reply(.success(3)), #"[vane-gaps] {"value":3}"#)
        XCTAssertEqual(ExtensionChromiumGaps.reply(.failure(ExtensionHost.Failure("No."))), #"[vane-gaps] {"error":"No."}"#)
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
}
