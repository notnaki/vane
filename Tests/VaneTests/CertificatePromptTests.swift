import XCTest
@testable import vane

@MainActor final class CertificatePromptTests: XCTestCase {
    func testBackgroundSentryFailureCannotInterruptKognity() {
        XCTAssertFalse(CertificateTrust.shouldPrompt(
            host: "o4506983207337984.ingest.us.sentry.io", port: 443,
            navigationURL: URL(string: "https://app.kognity.com/study")))
    }

    func testOnlyTheExactHTTPSNavigationOriginCanPrompt() {
        let destination = URL(string: "https://EXAMPLE.com:8443/article")!
        XCTAssertTrue(CertificateTrust.shouldPrompt(host: "example.com", port: 8443,
                                                    navigationURL: destination))
        XCTAssertFalse(CertificateTrust.shouldPrompt(host: "example.com", port: 443,
                                                     navigationURL: destination))
        XCTAssertFalse(CertificateTrust.shouldPrompt(host: "cdn.example.com", port: 8443,
                                                     navigationURL: destination))
        XCTAssertFalse(CertificateTrust.shouldPrompt(host: "example.com.evil.test", port: 8443,
                                                     navigationURL: destination))
    }

    func testCommittedOrMissingNavigationCannotPrompt() {
        XCTAssertFalse(CertificateTrust.shouldPrompt(host: "example.com", port: 443,
                                                     navigationURL: nil))
        XCTAssertFalse(CertificateTrust.shouldPrompt(host: "example.com", port: 443,
                                                     navigationURL: URL(string: "http://example.com")))
        XCTAssertFalse(CertificateTrust.shouldPrompt(host: "example.com", port: 443,
                                                     navigationURL: URL(string: "about:blank")))
    }

    func testDefaultHTTPSPortAndCaseInsensitiveHostStillPrompt() {
        XCTAssertTrue(CertificateTrust.shouldPrompt(host: "EXAMPLE.COM", port: 443,
            navigationURL: URL(string: "https://example.com")))
        XCTAssertTrue(CertificateTrust.shouldPrompt(host: "example.com", port: 0,
            navigationURL: URL(string: "https://example.com:443")))
    }
}
