import Foundation
import XCTest
@testable import vane

@MainActor final class SearchURLTests: XCTestCase {
    func testInvalidHostGuessesFallBackToSearch() throws {
        let suite = "vane.search-url-tests.\(UUID().uuidString)"
        let previous = Search.defaults
        Search.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            Search.defaults = previous
            UserDefaults.dropScratchSuite(suite)
        }

        for input in [
            "[SwiftUI] list selection", "[SwiftUI]", "[foo:bar]", "[::1] notes",
            "[::1]:not-a-port", "[::1]suffix", "[::1]:", "[::1]:123456",
            "[::1]:65536", "[::1]:+80", "example.com:１２", "example.com:65536",
        ] {
            let result = Search.url(for: input)
            XCTAssertNotNil(result, input)
            let components = result.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            XCTAssertEqual(components?.host, "www.google.com", input)
            XCTAssertEqual(components?.path, "/search", input)
            XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "q", value: input)], input)
        }
    }

    func testValidHostsKeepTheirPortsPathsAndQueries() {
        for (input, expected) in [
            ("[::1]", "http://[::1]"),
            ("[::1]:8080/a?b=1#section", "http://[::1]:8080/a?b=1#section"),
            ("[2001:db8::1]/path", "http://[2001:db8::1]/path"),
            ("[::ffff:192.0.2.1]:8080", "http://[::ffff:192.0.2.1]:8080"),
            ("[fe80::1%en0]:8080/path", "http://[fe80::1%25en0]:8080/path"),
            ("[fe80::1%25en0]/path", "http://[fe80::1%25en0]/path"),
            ("[::1]:000080/a?q=b", "http://[::1]:000080/a?q=b"),
            ("[::1]:65535/path", "http://[::1]:65535/path"),
            ("localhost:3000", "http://localhost:3000"),
            ("127.0.0.1:8080/path", "http://127.0.0.1:8080/path"),
            ("example.com:000080/a", "https://example.com:000080/a"),
        ] {
            XCTAssertEqual(Search.url(for: input)?.absoluteString, expected, input)
        }
    }

    func testJavaScriptInputIsRejectedBeforeNavigation() {
        TestEnvironment.prepare()
        for input in ["javascript:alert(1)", "JaVaScRiPt:alert(1)",
                      "  javascript:void(document.title='probe')\n", "javascript://example.com/%0Aalert(1)",
                      "java\tscript:alert(1)", "java\nscript:alert(1)"] {
            XCTAssertNil(Search.url(for: input), input)
        }
        XCTAssertEqual(Search.url(for: "?javascript:alert(1)")?.host, "www.google.com",
                       "An explicit search for script text remains a search")
    }

    func testCustomEnginesRejectUnsafeTemplatesOnAddAndAtSearchTime() throws {
        TestEnvironment.prepare()
        let suite = "vane.search-template-tests.\(UUID())"
        let previous = Search.defaults
        let scratch = try XCTUnwrap(UserDefaults(suiteName: suite))
        Search.defaults = scratch
        defer {
            Search.defaults = previous
            UserDefaults.dropScratchSuite(suite)
        }
        for template in [
            "javascript:void(document.title='probe');//https://example.invalid/%s",
            "file:///tmp/%s", "data:text/html,%s", "ftp://example.com/%s",
            "https:///search?q=%s", "https://?q=%s", "https://user:pass@example.com/%s",
            "https://user@example.com/%s", "https://:pass@example.com/%s", "https://@example.com/%s",
            "https://example.com/search",
        ] {
            let engine = SearchEngine(id: "unsafe", name: "Unsafe", queryTemplate: template)
            Search.add(engine)
            XCTAssertTrue(Search.custom.isEmpty, template)
            XCTAssertNil(Search.search("probe", using: engine), template)
            XCTAssertNil(engine.home, template)
            // Simulate templates persisted by an earlier version, bypassing add validation.
            Search.custom = [engine]
            Search.current = engine
            XCTAssertEqual(Search.current.id, Search.defaultEngine.id, template)
            XCTAssertNotEqual(Search.search("probe")?.scheme, "javascript", template)
            XCTAssertNil(Bangs.resolve("!unsafe probe"), template)
            XCTAssertNil(Bangs.resolve("!unsafe"), template)
            Search.custom = []
        }
        if case .accepted = Bangs.add(.init(bang: "private", "Private", "https://user:pass@intranet.example/?q=%s")) {
            XCTFail("A bang must not carry credentials the search would then drop")
        }
        for template in ["https://search.example/find/%s?ui=1", "http://localhost:8080/?q=%s",
                         "https://example.com/?q=%s&other=%s"] {
            let engine = SearchEngine(id: "valid", name: "Valid", queryTemplate: template)
            Search.add(engine)
            XCTAssertEqual(Search.custom, [engine])
            let url = try XCTUnwrap(Search.search("a&b#c", using: engine))
            XCTAssertTrue(url.absoluteString.contains("a%26b%23c"))
            XCTAssertNotNil(engine.home)
            Search.custom = []
        }
    }

    func testDirectJavaScriptURLDoesNotCreateOrNavigateAWebView() {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true)
        tab.go(URL(string: "javascript:void(0)")!)
        XCTAssertFalse(tab.hasEverLoaded)
        XCTAssertNil(tab.existingWeb)
    }
}
