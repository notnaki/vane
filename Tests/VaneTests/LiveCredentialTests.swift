import XCTest
@testable import vane

/// Only the Keychain boundary is replaced. The real response handler, credential cache
/// and connection routing run without accessing the user's credentials or GitHub.
@MainActor private final class CredentialFixture {
    var stored: (login: String, token: String)? = ("fixture", "nonsecret-fixture")
    var unavailable: OSStatus?
    var deletions = 0
    let profile = UUID()

    func instance() -> LiveFolders {
        LiveFolders(profileID: profile, readCredential: { [self] in
            if let unavailable { return .unavailable(unavailable) }
            guard let stored else { return .missing }
            return .found(account: stored.login, password: stored.token)
        }, deleteCredential: { [self] account in
            guard stored?.login == account else { return false }
            deletions += 1
            stored = nil
            return true
        })
    }
}

@MainActor final class LiveCredentialTests: XCTestCase {
    func testGitHubRejectionRetainsCredentialAndOffersReconnect() {
        TestEnvironment.prepare()
        let fixture = CredentialFixture()
        let live = fixture.instance()
        let folder = UUID()
        live.receive(.failure(.unauthorised), for: folder, token: "nonsecret-fixture")

        XCTAssertEqual(fixture.deletions, 0)
        XCTAssertEqual(fixture.stored?.token, "nonsecret-fixture")
        XCTAssertEqual(live.signIn?.token, "nonsecret-fixture", "Refresh can retry the retained token")
        XCTAssertTrue(live.needsReconnect)
        XCTAssertNil(live.connectedLogin, "The editor must allow reconnection without deleting the token")
        XCTAssertEqual(LiveFolders.route(signedIn: live.connectedLogin != nil, hasSecret: true), .connect)
        XCTAssertEqual(LiveFolders.route(signedIn: live.connectedLogin != nil, hasSecret: false), .sheet)
        XCTAssertTrue(live.failing.contains(folder))

        let relaunched = fixture.instance()
        XCTAssertEqual(relaunched.signIn?.token, "nonsecret-fixture", "A fresh instance can still recover the credential")
    }

    func testSuccessfulRetryRecoversWithoutSigningInAgain() {
        TestEnvironment.prepare()
        let fixture = CredentialFixture()
        let live = fixture.instance()
        let folder = UUID()
        live.receive(.failure(.unauthorised), for: folder, token: "nonsecret-fixture")
        live.receive(.success([]), for: folder, token: "nonsecret-fixture")
        XCTAssertFalse(live.needsReconnect)
        XCTAssertEqual(live.connectedLogin, "fixture")
        XCTAssertFalse(live.failing.contains(folder))
        XCTAssertEqual(fixture.deletions, 0)
    }

    func testOtherFailuresNeitherDeleteNorRequireReconnect() {
        TestEnvironment.prepare()
        for trouble in [GitHub.Trouble.forbidden, .rateLimited, .badQuery, .refused(401), .refused(500), .offline] {
            let fixture = CredentialFixture()
            let live = fixture.instance()
            live.receive(.failure(trouble), for: UUID(), token: "nonsecret-fixture")
            XCTAssertEqual(fixture.deletions, 0, "\(trouble)")
            XCTAssertFalse(live.needsReconnect, "\(trouble)")
            XCTAssertEqual(live.connectedLogin, "fixture", "\(trouble)")
        }
    }

    func testLateOldResponseCannotChangeReplacementConnection() {
        TestEnvironment.prepare()
        let fixture = CredentialFixture()
        fixture.stored = ("replacement", "new-fixture")
        let live = fixture.instance()
        let folder = UUID()
        live.receive(.failure(.unauthorised), for: folder, token: "old-fixture")
        XCTAssertFalse(live.needsReconnect)
        XCTAssertFalse(live.failing.contains(folder))
        XCTAssertEqual(live.connectedLogin, "replacement")
        live.receive(.failure(.unauthorised), for: folder, token: "new-fixture")
        live.receive(.success([]), for: folder, token: "old-fixture")
        XCTAssertTrue(live.needsReconnect, "An old success must not clear the new token's rejection")
        XCTAssertTrue(live.failing.contains(folder))
        XCTAssertEqual(fixture.deletions, 0)
    }

    func testKeychainFailureDoesNotEraseSavedCredential() {
        TestEnvironment.prepare()
        let fixture = CredentialFixture()
        fixture.unavailable = -25308
        let live = fixture.instance()
        live.receive(.failure(.unauthorised), for: UUID(), token: "nonsecret-fixture")
        XCTAssertEqual(fixture.deletions, 0)
        XCTAssertEqual(fixture.stored?.token, "nonsecret-fixture")
        XCTAssertFalse(live.needsReconnect, "An unreadable token cannot be identified as the rejected one")
        fixture.unavailable = nil
        XCTAssertEqual(live.connectedLogin, "fixture")
    }

    func testExplicitSignOutStillDeletesCredential() {
        TestEnvironment.prepare()
        let fixture = CredentialFixture()
        let live = fixture.instance()
        live.receive(.failure(.unauthorised), for: UUID(), token: "nonsecret-fixture")
        live.signOut()
        XCTAssertEqual(fixture.deletions, 1)
        XCTAssertNil(fixture.stored)
        XCTAssertNil(live.signIn)
        XCTAssertFalse(live.needsReconnect)
    }

    func testResponseAfterExplicitSignOutDoesNotRestoreConnection() {
        TestEnvironment.prepare()
        let fixture = CredentialFixture()
        let live = fixture.instance()
        _ = live.signIn
        live.signOut()
        live.receive(.success([]), for: UUID(), token: "nonsecret-fixture")
        XCTAssertNil(live.connectedLogin)
        XCTAssertNil(fixture.stored)
        XCTAssertFalse(live.needsReconnect)
    }

    func testChangedPersistedTokenClearsRejectionAndSurvivesLateResponses() {
        var cache = LiveCredentialCache(login: "fixture", token: "old-fixture")
        cache.record(trouble: .unauthorised, token: "old-fixture")
        XCTAssertTrue(cache.needsReconnect)
        let new = cache.replacement(after: "old-fixture") {
            .found(account: "replacement", password: "new-fixture")
        }
        XCTAssertEqual(new?.token, "new-fixture")
        XCTAssertFalse(cache.needsReconnect)
        cache.record(trouble: .unauthorised, token: "old-fixture")
        XCTAssertFalse(cache.needsReconnect)
        cache.record(trouble: .unauthorised, token: "new-fixture")
        cache.record(trouble: nil, token: "old-fixture")
        XCTAssertTrue(cache.needsReconnect)
    }
}
