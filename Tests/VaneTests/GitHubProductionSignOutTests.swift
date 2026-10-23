import Foundation
import XCTest
@testable import vane

private final class SignOutCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var grant: GitHubCredential? = .init(accessToken: "old-fixture", refreshToken: "old-refresh", expiresAt: .distantPast)
    private var deletions = 0
    var value: GitHubCredential? { lock.withLock { grant } }
    var deleteCount: Int { lock.withLock { deletions } }
    func read() -> Passwords.CredentialRead {
        lock.withLock { grant.map { .found(account: "fixture", password: $0.stored) } ?? .missing }
    }
    func write(_ value: GitHubCredential) { lock.withLock { grant = value } }
    func delete() -> Bool { lock.withLock { grant = nil; deletions += 1; return true } }
}

@MainActor final class GitHubProductionSignOutTests: XCTestCase {
    private func live(_ store: SignOutCredentialStore,
                      send: @escaping GitHubTokenRenewal.Send) -> LiveFolders {
        let profile = UUID()
        var access = IntegrationTokens.Access()
        access.read = { candidate in XCTAssertEqual(candidate, profile); return store.read() }
        access.delete = { account, candidate in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(candidate, profile)
            XCTAssertEqual(account, "fixture")
            return store.delete()
        }
        // Deliberately omit deleteCredential: this exercises systemDeleteCredential and
        // the production async conditional deletion/lane, with only service IO isolated.
        return LiveFolders(profileID: profile, readCredential: { store.read() },
            storeCredential: { _, value in
                guard let grant = GitHubCredential.restore(value) else { return false }
                store.write(grant)
                return true
            }, credentialAccess: access, oauthSecret: { "fixture secret" }, sendRefresh: send,
            fetchPullRequests: { _, _ in .success([]) })
    }

    func testProductionSignOutDeletesRenewalSuccessorAfterWaitingForLock() async throws {
        TestEnvironment.prepare()
        let store = SignOutCredentialStore()
        var live: LiveFolders!
        defer { live = nil }
        live = self.live(store) { _ in
            live.signOut()
            try? await Task.sleep(for: .milliseconds(30))
            return .success(.init(accessToken: "renewed-fixture", refreshToken: "renewed-refresh", expiresAt: .distantFuture))
        }
        let old = try XCTUnwrap(live.signIn?.token)
        _ = await live.fetchAuthorized(GitHubQuery(), token: old)
        let deadline = ContinuousClock.now + .seconds(3)
        while store.value != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.value)
        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertNil(live.connectedLogin)
    }

    func testProductionSignOutPreservesReplacementSignInForSameAccount() async throws {
        TestEnvironment.prepare()
        let store = SignOutCredentialStore()
        var live: LiveFolders!
        let replacement = GitHubCredential(accessToken: "replacement-fixture", refreshToken: "replacement-refresh", expiresAt: .distantFuture)
        defer { live = nil }
        live = self.live(store) { _ in
            live.signOut()
            store.write(replacement)
            try? await Task.sleep(for: .milliseconds(30))
            return .success(.init(accessToken: "unrelated-renewal", refreshToken: "unrelated-refresh", expiresAt: .distantFuture))
        }
        let old = try XCTUnwrap(live.signIn?.token)
        _ = await live.fetchAuthorized(GitHubQuery(), token: old)
        // Allow the async waiter to acquire the released lock and inspect the replacement.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.value, replacement)
        XCTAssertEqual(store.deleteCount, 0)
    }
}
