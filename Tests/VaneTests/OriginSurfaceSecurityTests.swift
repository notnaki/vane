import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class OriginSurfaceSecurityTests: XCTestCase {
    override func setUp() { TestEnvironment.prepare() }

    func testLivePreviewRejectsCrossOriginActionsAndRedirectResponses() throws {
        let delegate = EaselLiveView.Delegate(profileID: UUID())
        delegate.source = URL(string: "https://source.invalid/capture")!
        XCTAssertEqual(delegate.policy(url: URL(string: "https://source.invalid:443/next")!, mainFrame: true), .allow)
        for raw in ["https://attacker.invalid/", "https://source.invalid.attacker.invalid/", "https://source.invalid:8443/", "http://source.invalid/"] {
            let destination = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(delegate.policy(url: destination, mainFrame: true), .cancel, raw)
            XCTAssertEqual(delegate.responsePolicy(url: destination, mainFrame: true, displayable: true), .cancel,
                           "Redirect response must enforce the saved origin: " + raw)
        }
        XCTAssertEqual(delegate.policy(url: URL(string: "https://embedded.invalid/")!, mainFrame: false), .allow)
        delegate.source = nil
        XCTAssertEqual(delegate.policy(url: URL(string: "https://source.invalid/")!, mainFrame: true), .cancel)
    }

    func testLivePreviewAllowsOnlyItsOwnHTTPSUpgrade() throws {
        let suite = "vane.live-security.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = HTTPSOnly.defaults; HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; UserDefaults.dropScratchSuite(suite) }
        let delegate = EaselLiveView.Delegate(profileID: UUID())
        delegate.source = URL(string: "http://source.invalid/capture")!
        XCTAssertEqual(delegate.policy(url: delegate.source!, mainFrame: true), .upgrade(URL(string: "https://source.invalid/capture")!))
        XCTAssertTrue(delegate.allowsMainFrame(URL(string: "https://source.invalid/redirect")!))
        XCTAssertEqual(delegate.responsePolicy(url: delegate.source, mainFrame: true, displayable: true), .cancel)
        XCTAssertEqual(delegate.responsePolicy(url: URL(string: "https://source.invalid/redirect"), mainFrame: true, displayable: true), .allow)
        XCTAssertFalse(delegate.allowsMainFrame(URL(string: "https://other.invalid/")!))
        HTTPSOnly.enabled = false
        XCTAssertFalse(delegate.allowsMainFrame(URL(string: "https://source.invalid/")!))
    }

    func testPeekIdentityShowsCurrentOriginPortAndSecurityAcrossNavigation() throws {
        let first = Peek.identity(url: URL(string: "https://source.invalid/path"), secureContent: true, trusted: true, failed: false)
        XCTAssertEqual(first.origin, "https://source.invalid")
        XCTAssertEqual(first.glyph, "lock")
        let redirected = Peek.identity(url: URL(string: "http://attacker.invalid:8080/login?next=source.invalid"), secureContent: true, trusted: true, failed: false)
        XCTAssertEqual(redirected.origin, "http://attacker.invalid:8080")
        XCTAssertEqual(redirected.glyph, "lock.slash")
        XCTAssertTrue(redirected.connection.contains("not encrypted"))
        XCTAssertEqual(redirected.fullURL, "http://attacker.invalid:8080/login?next=source.invalid")
        let accepted = Peek.identity(url: URL(string: "https://source.invalid/"), secureContent: true, trusted: false, failed: false)
        XCTAssertEqual(accepted.glyph, "exclamationmark.triangle")
        XCTAssertTrue(accepted.connection.contains("certificate problem"))
        let mixed = Peek.identity(url: URL(string: "https://source.invalid/"), secureContent: false, trusted: true, failed: false)
        XCTAssertTrue(mixed.connection.contains("part of this page"))
        let failed = Peek.identity(url: URL(string: "https://source.invalid/"), secureContent: true, trusted: true, failed: true)
        XCTAssertEqual(failed.glyph, "globe")
        XCTAssertEqual(failed.connection, "This page did not load")
    }

    func testPeekOriginCannotBeDisguisedByURLCredentialsOrPath() {
        let identity = Peek.identity(url: URL(string: "https://trusted.invalid@attacker.invalid/trusted.invalid"), secureContent: true, trusted: true, failed: false)
        XCTAssertEqual(identity.origin, "https://attacker.invalid")
    }
}
