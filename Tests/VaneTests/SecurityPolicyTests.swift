import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SecurityPolicyTests: XCTestCase {
    func testHTTPLoginRequiresTheMainDocumentOriginForBasicAndDigest() {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] {
            let space = URLProtectionSpace(host: "example.test", port: 443, protocol: "https",
                                           realm: "Fixture", authenticationMethod: method)
            for (raw, allowed) in [("https://EXAMPLE.test/path", true), ("https://example.test:443/", true),
                                   ("http://example.test/", false), ("https://example.test:8443/", false),
                                   ("https://sub.example.test/", false), ("https://other.test/", false)] {
                XCTAssertEqual(CertificateTrust.shouldOfferLogin(space, navigationURL: URL(string: raw)), allowed, raw)
            }
            XCTAssertFalse(CertificateTrust.shouldOfferLogin(space, navigationURL: nil))
            let proxy = URLProtectionSpace(proxyHost: "example.test", port: 443, type: NSURLProtectionSpaceHTTPSProxy,
                                           realm: nil, authenticationMethod: method)
            XCTAssertFalse(CertificateTrust.shouldOfferLogin(proxy, navigationURL: URL(string: "https://example.test")))
        }
        let plain = URLProtectionSpace(host: "example.test", port: 80, protocol: "http", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertTrue(CertificateTrust.shouldOfferLogin(plain, navigationURL: URL(string: "http://example.test")))
    }

    func testFileLinksRequireAFileSourceForEveryModifierRoute() {
        let file = URL(fileURLWithPath: "/tmp/fixture.html")
        for source in [URL(string: "https://example.test"), URL(string: "about:blank"), nil] {
            XCTAssertFalse(LinkInteraction.allows(file, from: source))
        }
        XCTAssertTrue(LinkInteraction.allows(file, from: file))
        let context = LinkInteraction.Context(kind: .today, source: URL(string: "https://example.test")!)
        for flags: NSEvent.ModifierFlags in [.command, [.command, .option], [.command, .shift]] {
            XCTAssertEqual(LinkInteraction.route(to: file, context: context, modifiers: flags), .navigate)
        }
        XCTAssertEqual(LinkInteraction.route(to: file, context: context, modifiers: [], button: TabActions.middleButton), .navigate)
        XCTAssertEqual(LinkInteraction.route(to: file, context: .init(kind: .today, source: file), modifiers: .command), .tab(focus: false))
    }

    func testVerifiedSignerAppearsInInstallAndUpdatePrompts() {
        for installing in [true, false] {
            let review = ExtensionConsent.Review(name: "Manifest name", requested: .init(permissions: [], sites: []),
                previous: nil, installing: installing, updating: !installing,
                verifiedSigner: "Verified Team ID: ABCDE12345\nCertificate: Developer ID Application: Fixture")
            let alert = ExtensionConsent.makePrompt(review)
            XCTAssertTrue(alert.informativeText.contains("ABCDE12345"))
            XCTAssertTrue(alert.informativeText.contains("Developer ID Application: Fixture"))
        }
    }

    func testGitHubRedirectDelegateOnlyFollowsHTTPSAPIHost() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://api.github.com/user")!
        let task = session.dataTask(with: origin) // Never resumed; no network or credentials.
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        for (raw, allowed) in [("https://api.github.com/next", true), ("https://elsewhere.test/", false),
                               ("https://api.github.com.elsewhere.test/", false), ("http://api.github.com/", false)] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: raw)))
            let redirected: URLRequest? = await withCheckedContinuation { continuation in
                GitHub.Redirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertEqual(redirected != nil, allowed, raw)
        }
    }

    func testDRMRunLoopReturnExitsWithoutATrap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Vane/DRMCheck.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("fatalError("))
        XCTAssertEqual(source.components(separatedBy: "NSApplication.shared.run()\n        exit(2)").count - 1, 2)
    }
}
