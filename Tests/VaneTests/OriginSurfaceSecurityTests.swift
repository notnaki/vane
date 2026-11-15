import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class OriginSurfaceSecurityTests: XCTestCase {
    override func setUp() { TestEnvironment.prepare() }

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
