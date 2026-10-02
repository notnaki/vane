import XCTest
@testable import vane

@MainActor private final class RenewalFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-renewal-\(UUID())")
    var stored: GitHubCredential? = GitHubCredential(accessToken: "old-fixture", refreshToken: "refresh-fixture", expiresAt: .distantPast)
    var writes = 0
    var calls = 0
    var unavailable = false
    var canWrite = true
    var reply: Result<GitHubCredential, GitHub.Trouble> = .success(GitHubCredential(accessToken: "new-fixture", refreshToken: "new-refresh", expiresAt: .distantFuture))
    var duringRequest: (() -> Void)?
    var lockURL: URL { directory.appendingPathComponent("refresh.lock") }
    func read() -> Passwords.CredentialRead {
        if unavailable { return .unavailable(-25308) }
        return stored.map { .found(account: "fixture", password: $0.stored) } ?? .missing
    }
    func write(_ login: String, _ value: String) -> Bool {
        guard canWrite else { return false }
        writes += 1
        stored = GitHubCredential.restore(value)
        return true
    }
    func send(_ request: URLRequest) async -> Result<GitHubCredential, GitHub.Trouble> {
        calls += 1
        duringRequest?()
        duringRequest = nil
        try? await Task.sleep(for: .milliseconds(30))
        return reply
    }
    func coordinator(secret: String? = "fixture-secret") -> GitHubTokenRenewal {
        GitHubTokenRenewal(lockURL: lockURL, read: { [self] in read() }, write: { [self] in write($0, $1) }, secret: { secret }, send: { [self] in await send($0) })
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor final class GitHubRenewalTests: XCTestCase {
    private func assertFailure(_ coordinator: GitHubTokenRenewal, _ expected: GitHub.Trouble) async {
        let result = await coordinator.token(after: "old-fixture")
        XCTAssertEqual(result.failure, expected)
    }
    func testGrantKeepsExpiryAndRefreshTokenAcrossStoredRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let grant = try XCTUnwrap(GitHubOAuth.grant(Data(#"{"access_token":"access-fixture","refresh_token":"refresh-fixture","expires_in":28800,"refresh_token_expires_in":15897600}"#.utf8), now: now))
        XCTAssertEqual(grant.expiresAt, now.addingTimeInterval(28800))
        XCTAssertEqual(grant.refreshExpiresAt, now.addingTimeInterval(15897600))
        XCTAssertEqual(GitHubCredential.restore(grant.stored), grant)
        XCTAssertFalse(grant.needsRenewal(at: now))
        XCTAssertTrue(grant.needsRenewal(at: now.addingTimeInterval(28750)))
    }

    func testLegacyPATAndNonexpiringOAuthStillWork() throws {
        let legacy = try XCTUnwrap(GitHubCredential.restore("not-a-token-fixture"))
        XCTAssertEqual(legacy.accessToken, "not-a-token-fixture")
        XCTAssertNil(legacy.refreshToken)
        XCTAssertFalse(legacy.needsRenewal(at: .distantFuture))
        XCTAssertNotNil(GitHubOAuth.grant(Data(#"{"access_token":"oauth-fixture"}"#.utf8)))
        XCTAssertNil(GitHubCredential.restore("vane-github-oauth-v1:broken"))
    }

    func testIncompleteOrErrorGrantsAreRejected() {
        for json in [#"{"error":"bad_refresh_token"}"#, #"{"access_token":""}"#, #"{"access_token":"fixture","expires_in":28800}"#, #"{"access_token":"fixture","refresh_token":"","expires_in":28800}"#, #"{"access_token":"fixture","refresh_token":"refresh","expires_in":-1}"#] {
            XCTAssertNil(GitHubOAuth.grant(Data(json.utf8)), json)
        }
    }

    func testRefreshRequestUsesFormBodyAndEscapesSecrets() throws {
        let request = try XCTUnwrap(GitHubOAuth.refresh(refreshToken: "refresh+ &fixture", secret: "secret+&fixture"))
        XCTAssertEqual(request.url?.absoluteString, GitHubOAuth.tokenURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.url?.query)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=refresh%2B%20%26fixture"))
        XCTAssertTrue(body.contains("client_secret=secret%2B%26fixture"))
    }

    func testRenewalPersistsRotatedPairBeforeReturningAccessToken() async throws {
        let fixture = RenewalFixture()
        let result = await fixture.coordinator().token(after: "old-fixture")
        let session = try result.get()
        XCTAssertEqual(session.token, "new-fixture")
        XCTAssertEqual(fixture.stored?.refreshToken, "new-refresh")
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertEqual(fixture.writes, 1)
        var cache = LiveCredentialCache()
        XCTAssertEqual(cache.read { fixture.read() }?.token, "new-fixture", "A relaunched app sends the access token, not its stored envelope")
    }

    func testConcurrentFoldersShareOneRenewal() async throws {
        let fixture = RenewalFixture()
        let coordinator = fixture.coordinator()
        async let first = coordinator.token(after: "old-fixture")
        async let second = coordinator.token(after: "old-fixture")
        let answers = await [first, second]
        for answer in answers { XCTAssertEqual(try answer.get().token, "new-fixture") }
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertEqual(fixture.writes, 1)
    }

    func testSeparateCoordinatorsRecheckCredentialAfterFileLock() async throws {
        let fixture = RenewalFixture()
        let first = fixture.coordinator()
        let second = fixture.coordinator()
        async let a = first.token(after: "old-fixture", force: true)
        async let b = second.token(after: "old-fixture", force: true)
        let answers = await [a, b]
        for answer in answers { XCTAssertEqual(try answer.get().token, "new-fixture") }
        XCTAssertEqual(fixture.calls, 1, "Only one process may spend a one-use refresh token")
    }

    func testOfflineRenewalRetainsPairAndCanRetry() async throws {
        let fixture = RenewalFixture()
        fixture.reply = .failure(.offline)
        let coordinator = fixture.coordinator()
        await assertFailure(coordinator, .offline)
        XCTAssertEqual(fixture.stored?.refreshToken, "refresh-fixture")
        XCTAssertEqual(fixture.writes, 0)
        fixture.reply = .success(GitHubCredential(accessToken: "recovered", refreshToken: "rotated", expiresAt: .distantFuture))
        let recovered = try await coordinator.token(after: "old-fixture").get()
        XCTAssertEqual(recovered.token, "recovered")
    }

    func testFailedKeychainWriteDoesNotUseUnpersistedAccessToken() async {
        let fixture = RenewalFixture()
        fixture.canWrite = false
        await assertFailure(fixture.coordinator(), .offline)
        XCTAssertEqual(fixture.stored?.accessToken, "old-fixture")
        XCTAssertEqual(fixture.writes, 0)
    }

    func testKeychainWriteRetriesRotatedPairWithoutSpendingOldRefreshToken() async throws {
        let fixture = RenewalFixture()
        fixture.canWrite = false
        let coordinator = fixture.coordinator()
        await assertFailure(coordinator, .offline)
        fixture.canWrite = true
        let next = try await coordinator.token(after: "old-fixture").get()
        XCTAssertEqual(next.token, "new-fixture")
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertEqual(fixture.stored?.refreshToken, "new-refresh")
    }

    private func live(_ fixture: RenewalFixture,
                      fetch: @escaping (GitHubQuery, String) async -> Result<[GitHub.PR], GitHub.Trouble>) -> LiveFolders {
        TestEnvironment.prepare()
        return LiveFolders(profileID: UUID(), readCredential: { fixture.read() },
                           deleteCredential: { _ in fixture.stored = nil; return true },
                           storeCredential: { fixture.write($0, $1) },
                           oauthSecret: { "fixture-secret" },
                           sendRefresh: { await fixture.send($0) }, fetchPullRequests: fetch)
    }

    func testRealFolderFetchRenewsBeforeSendingExpiredToken() async {
        let fixture = RenewalFixture()
        var sent: [String] = []
        let live = live(fixture) { _, token in sent.append(token); return .success([]) }
        let old = live.signIn!.token
        let response = await live.fetchAuthorized(GitHubQuery(), token: old)
        live.receive(response.answer, for: UUID(), token: response.token)
        XCTAssertEqual(sent, ["new-fixture"])
        XCTAssertEqual(live.connectedLogin, "fixture")
        XCTAssertFalse(live.needsReconnect)
        XCTAssertEqual(fixture.calls, 1)
    }

    func testEarly401RenewsAndRetriesExactlyOnce() async {
        let fixture = RenewalFixture()
        fixture.stored?.expiresAt = .distantFuture
        var sent: [String] = []
        let live = live(fixture) { _, token in
            sent.append(token)
            return token == "old-fixture" ? .failure(.unauthorised) : .success([])
        }
        let response = await live.fetchAuthorized(GitHubQuery(), token: live.signIn!.token)
        live.receive(response.answer, for: UUID(), token: response.token)
        XCTAssertEqual(sent, ["old-fixture", "new-fixture"])
        XCTAssertEqual(fixture.calls, 1)
        XCTAssertFalse(live.needsReconnect)
    }

    func testSignOutDuringRenewalCompletesAndLateResponseCannotReconnect() async throws {
        let fixture = RenewalFixture()
        let live = live(fixture) { _, _ in .success([]) }
        let old = live.signIn!.token
        fixture.duringRequest = { [unowned live] in live.signOut() }
        let response = await live.fetchAuthorized(GitHubQuery(), token: old)
        live.receive(response.answer, for: UUID(), token: response.token)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(fixture.stored)
        XCTAssertNil(live.connectedLogin)
        XCTAssertFalse(live.needsReconnect)
    }

    func testCredentialRemovedDuringRequestCannotBeResurrected() async {
        let fixture = RenewalFixture()
        fixture.duringRequest = { fixture.stored = nil }
        await assertFailure(fixture.coordinator(), .offline)
        XCTAssertNil(fixture.stored)
        XCTAssertEqual(fixture.writes, 0)
    }

    func testReplacementDuringRequestWinsOverRotatedOldToken() async throws {
        let fixture = RenewalFixture()
        fixture.duringRequest = { fixture.stored = GitHubCredential(accessToken: "replacement") }
        let replacement = try await fixture.coordinator().token(after: "old-fixture").get()
        XCTAssertEqual(replacement.token, "replacement")
        XCTAssertEqual(fixture.writes, 0)
    }

    func testExpiredRefreshTokenAndMissingSecretRetainCredential() async {
        let fixture = RenewalFixture()
        fixture.stored?.refreshExpiresAt = .distantPast
        await assertFailure(fixture.coordinator(), .unauthorised)
        fixture.stored?.refreshExpiresAt = nil
        await assertFailure(fixture.coordinator(secret: nil), .unauthorised)
        XCTAssertEqual(fixture.calls, 0)
        XCTAssertEqual(fixture.stored?.accessToken, "old-fixture")
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let value) = self { return value }; return nil }
}
