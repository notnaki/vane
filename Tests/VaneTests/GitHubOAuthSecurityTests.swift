import Foundation
import XCTest
@testable import vane

final class GitHubOAuthSecurityTests: XCTestCase {
    func testAuthorizationRequiresS256ProofKey() throws {
        let url = try XCTUnwrap(GitHubOAuth.authorize(state: "fixture-state", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        let challenge = try XCTUnwrap(items.first { $0.name == "code_challenge" }?.value)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 Appendix B S256 vector")
        XCTAssertNil(items.first { $0.name == "code_verifier" })
    }

    func testTokenExchangeCarriesTheOriginalVerifierAndRejectsInvalidProofKeys() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let request = try XCTUnwrap(GitHubOAuth.exchange(code: "fixture-code", secret: "fixture-secret", verifier: verifier))
        let body = try XCTUnwrap(request.httpBody)
        let items = try XCTUnwrap(URLComponents(string: "https://fixture.test/?" + String(decoding: body, as: UTF8.self))?.queryItems)
        XCTAssertEqual(items.first { $0.name == "code_verifier" }?.value, verifier)
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "fixture-code")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/oauth/access_token")
        for invalid in ["", "short", String(repeating: "A", count: 129), String(repeating: "+", count: 43), verifier + "\n"] {
            XCTAssertNil(GitHubOAuth.authorize(state: "fixture-state", verifier: invalid))
            XCTAssertNil(GitHubOAuth.exchange(code: "fixture-code", secret: "fixture-secret", verifier: invalid))
        }
    }

    func testEachAttemptUsesAnIndependentRandomProofKey() throws {
        let first = try XCTUnwrap(GitHubOAuth.newVerifier())
        let second = try XCTUnwrap(GitHubOAuth.newVerifier())
        XCTAssertEqual(first.count, 43)
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(GitHubOAuth.challenge(for: first))
        XCTAssertNotEqual(GitHubOAuth.challenge(for: first), GitHubOAuth.challenge(for: second))
    }
}
