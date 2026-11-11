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
}
