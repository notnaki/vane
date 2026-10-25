import Security
import XCTest
@testable import vane

/// Every key here is generated for the test and imported into memory only. No user
/// keychain, credential, key export, trust preference or search list is accessed.
@MainActor final class ClientCertificateTests: XCTestCase {
    private func fixture(_ name: String) throws -> ClientCertificates.Candidate {
        try XCTUnwrap(ClientCertificates.Candidate(identity: fixtureIdentity(name)))
    }

    private func fixtureIdentity(_ name: String, usage: String = "clientAuth") throws -> SecIdentity {
        try ClientCertificateFixture.identity(name, usage: usage)
    }

    private func scope(profile: UUID = UUID(), host: String = "example.test", port: Int = 443,
                       scheme: String = "https") -> ClientCertificates.Scope {
        ClientCertificates.Scope(profileID: profile, host: host, port: port, scheme: scheme)!
    }

    func testIssuerQueryKeepsAllAcceptedAuthoritiesAndRequestsAllIdentities() throws {
        let authorities = [Data([0x30, 0x01, 0x01]), Data([0x30, 0x01, 0x02])]
        let query = ClientCertificates.query(issuers: authorities)
        XCTAssertEqual(query[kSecMatchIssuers as String] as? [Data], authorities)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassIdentity as String)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertTrue(query[kSecMatchValidOnDate as String] is NSNull)
        let policy = try XCTUnwrap(query[kSecMatchPolicy as String]) as! SecPolicy
        let properties = SecPolicyCopyProperties(policy) as? [String: Any]
        XCTAssertEqual(properties?[kSecPolicyClient as String] as? Bool, true)
        XCTAssertNil(ClientCertificates.query(issuers: [])[kSecMatchIssuers as String])
        XCTAssertNil(ClientCertificates.query(issuers: nil)[kSecMatchIssuers as String])
    }

    func testUserChoosesAmongMultipleCandidatesAndSessionReusesOnlyThatIdentity() async throws {
        let first = try fixture("first"), second = try fixture("second")
        let session = ClientCertificates.Session()
        let site = scope()
        let selected = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [first, second] }, prompt: { candidates in
                XCTAssertEqual(candidates.count, 2)
                return candidates[1].id
            }, isCurrent: { true })
        XCTAssertEqual(selected?.id, second.id)
        let reused = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [first, second] }, prompt: { _ in XCTFail("Already selected for this site"); return nil },
            isCurrent: { true })
        XCTAssertEqual(reused?.id, second.id)
    }

    func testChoicesDoNotCrossOriginProfilePrivateOrRejectedAttempt() async throws {
        let identity = try fixture("scoped")
        let session = ClientCertificates.Session(), profile = UUID()
        let site = scope(profile: profile)
        _ = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [identity] }, prompt: { _ in identity.id }, isCurrent: { true })
        let sites = [scope(profile: profile, host: "other.test"), scope(profile: profile, port: 8443),
                     scope(profile: UUID()), site, site]
        var prompts = 0
        for (index, target) in sites.enumerated() {
            let result = await session.choose(scope: target, isPrivate: index == 3,
                previousFailureCount: index == 4 ? 1 : 0, load: { [identity] },
                prompt: { _ in prompts += 1; return nil }, isCurrent: { true })
            XCTAssertNil(result)
        }
        XCTAssertEqual(prompts, 5)
        XCTAssertNil(ClientCertificates.Scope(profileID: profile, host: "example.test", port: 80, scheme: "http"))
    }

    func testPrivateSelectionAlwaysPromptsAndDoesNotSeedNormalSession() async throws {
        let identity = try fixture("private")
        let session = ClientCertificates.Session(), site = scope()
        var prompts = 0
        for isPrivate in [true, true, false] {
            let result = await session.choose(scope: site, isPrivate: isPrivate, previousFailureCount: 0,
                load: { [identity] }, prompt: { _ in prompts += 1; return identity.id }, isCurrent: { true })
            XCTAssertEqual(result?.id, identity.id)
        }
        XCTAssertEqual(prompts, 3)
    }

    func testCancelMissingIdentityAndStaleDocumentNeverReturnOrRememberCredential() async throws {
        let identity = try fixture("lifetime")
        let session = ClientCertificates.Session(), site = scope()
        var current = true
        let stale = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [identity] }, prompt: { _ in current = false; return identity.id }, isCurrent: { current })
        XCTAssertNil(stale)
        current = true
        let cancelled = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [identity] }, prompt: { _ in nil }, isCurrent: { current })
        XCTAssertNil(cancelled)
        let missing = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [] }, prompt: { _ in XCTFail("No available identity"); return identity.id },
            isCurrent: { true })
        XCTAssertNil(missing)
        var prompted = false
        _ = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [identity] }, prompt: { _ in prompted = true; return nil }, isCurrent: { true })
        XCTAssertTrue(prompted, "Stale and cancelled selections cannot enter the session cache")
    }
    func testRemovedOrNoLongerMatchingIdentityCannotBeReused() async throws {
        let first = try fixture("previous-issuer"), second = try fixture("new-issuer")
        let session = ClientCertificates.Session(), site = scope()
        _ = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [first] }, prompt: { _ in first.id }, isCurrent: { true })
        var prompted = false
        let result = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { [second] }, prompt: { _ in prompted = true; return second.id }, isCurrent: { true })
        XCTAssertTrue(prompted)
        XCTAssertEqual(result?.id, second.id)
    }

    func testNavigationReplacementWhileLoadingAndCancelledTaskDoNotPrompt() async throws {
        let identity = try fixture("replacement")
        let session = ClientCertificates.Session(), site = scope()
        var current = true
        let result = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
            load: { current = false; return [identity] },
            prompt: { _ in XCTFail("Document replaced during discovery"); return identity.id },
            isCurrent: { current })
        XCTAssertNil(result)
        let task = Task { @MainActor in
            await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
                load: { XCTFail("Cancelled request must not read identities"); return [identity] },
                prompt: { _ in XCTFail("Cancelled request must not prompt"); return identity.id },
                isCurrent: { true })
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    func testForgettingAProfileDropsOnlyItsSessionChoices() async throws {
        let identity = try fixture("forget")
        let session = ClientCertificates.Session(), profile = UUID()
        let first = scope(profile: profile), other = scope()
        for site in [first, other] {
            _ = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
                load: { [identity] }, prompt: { _ in identity.id }, isCurrent: { true })
        }
        session.forget(profileID: profile)
        var prompts = 0
        for site in [first, other] {
            _ = await session.choose(scope: site, isPrivate: false, previousFailureCount: 0,
                load: { [identity] }, prompt: { _ in prompts += 1; return identity.id }, isCurrent: { true })
        }
        XCTAssertEqual(prompts, 1)
    }

    func testCandidateRejectsExpiredFutureAndWrongExtendedKeyUsage() throws {
        let identity = try fixtureIdentity("dates")
        XCTAssertNotNil(ClientCertificates.Candidate(identity: identity))
        XCTAssertNil(ClientCertificates.Candidate(identity: identity, now: .now.addingTimeInterval(3 * 86400)))
        XCTAssertNil(ClientCertificates.Candidate(identity: identity, now: .now.addingTimeInterval(-3 * 86400)))
        let serverOnly = try fixtureIdentity("server-only", usage: "serverAuth")
        XCTAssertNil(ClientCertificates.Candidate(identity: serverOnly))
    }

}
