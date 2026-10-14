import XCTest
import WebKit
@testable import vane

@MainActor private final class FavouriteFixtureLoader: FavouritePreviewLoading {
    var calls = 0
    var cancellations = 0
    var replies = 0
    var wait: Duration = .milliseconds(50)
    var holdReplies = false
    private var pendingReplies: [CheckedContinuation<Void, Never>] = []
    var result: FavouritePreviewResult = .ready(.init(account: "fixture", items: []))
    func load(_ context: FavouritePreviewContext) async -> FavouritePreviewResult {
        calls += 1
        let reply = result
        // Deliberately ignores cancellation: a late WebKit callback must still be refused.
        if holdReplies { await withCheckedContinuation { pendingReplies.append($0) } }
        else { try? await Task.sleep(for: wait) }
        replies += 1
        return reply
    }
    func cancel() { cancellations += 1 }
    func releaseReplies() {
        holdReplies = false
        let replies = pendingReplies
        pendingReplies = []
        replies.forEach { $0.resume() }
    }
}

@MainActor final class FavouritePreviewLifecycleTests: XCTestCase {
    private func settle(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(3)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Fixture did not reach its expected state", file: file, line: line)
    }
    private func context(_ profile: UUID = UUID()) -> FavouritePreviewContext {
        FavouritePreviewContext(profileID: profile, url: URL(string: "https://github.com/")!)!
    }
    func testDismissCannotPublishLateReply() async throws {
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader)
        let owner = UUID()
        coordinator.request(context(), owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        coordinator.dismiss(owner: owner)
        try await settle { loader.replies == 1 }
        XCTAssertNil(coordinator.owner)
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertGreaterThan(loader.cancellations, 0)
    }
    func testInvalidationRetiresContentAndInflightReplyOnlyForOwningProfile() async throws {
        let loader = FavouriteFixtureLoader()
        let previews = FavouritePreviews(loader: loader)
        let a = context(), b = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        previews.invalidate(profileID: b.profileID)
        XCTAssertEqual(previews.owner, owner)
        previews.invalidate(profileID: a.profileID)
        try await settle { loader.replies == 1 }
        XCTAssertNil(previews.owner)
        XCTAssertEqual(previews.state, .loading)
    }
    func testReplacementAndAccountIsolation() async throws {
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader)
        let a = context(), b = context(), first = UUID(), second = UUID()
        coordinator.request(a, owner: first, account: "fixture")
        try await settle { loader.calls == 1 }
        coordinator.request(b, owner: second, account: "other")
        try await settle { loader.replies == 2 && coordinator.state == .unavailable }
        XCTAssertEqual(coordinator.owner, second)
        // The page came back as a different account than the live favourite: fail closed.
        XCTAssertEqual(coordinator.state, .unavailable)
        coordinator.dismiss(owner: second)
    }
    func testRepeatHoverUsesVerifiedAccountCacheAndFailureHasCooldown() async throws {
        let loader = FavouriteFixtureLoader()
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        previews.dismiss(owner: owner)
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1)
        previews.dismiss(owner: owner)
        // An unverified identity must not reuse the previous account's cached data.
        previews.request(a, owner: owner, account: "other")
        try await settle { previews.state == .unavailable }
        XCTAssertEqual(previews.state, .unavailable)
        XCTAssertEqual(loader.calls, 1)
        previews.dismiss(owner: owner)
    }
    func testStaleRefreshFailureAndSignedOutAreDistinct() async throws {
        let loader = FavouriteFixtureLoader()
        var clock = Date(timeIntervalSince1970: 1000)
        let previews = FavouritePreviews(loader: loader, now: { clock })
        let a = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.replies == 1 && previews.state == .ready(.init(account: "fixture", items: [])) }
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(121)
        loader.result = .unavailable
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.replies == 2 && previews.state == .stale(.init(account: "fixture", items: [])) }
        XCTAssertEqual(previews.state, .stale(.init(account: "fixture", items: [])))
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(31)
        loader.result = .signedOut
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state == .signedOut }
        XCTAssertEqual(previews.state, .signedOut)
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(31)
        loader.result = .unavailable
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.replies == 4 && previews.state == .unavailable }
        XCTAssertEqual(previews.state, .unavailable, "Signing out must purge the old account cache")
        previews.dismiss(owner: owner)
    }

    func testClearingBlocksReloadsUntilCompletionAndDisablePurgesCache() async throws {
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        coordinator.beginClearing(profileID: a.profileID)
        coordinator.request(a, owner: owner, account: "fixture")
        XCTAssertEqual(loader.calls, 0)
        XCTAssertEqual(coordinator.state, .unavailable)
        coordinator.endClearing(profileID: a.profileID)
        coordinator.request(a, owner: owner, account: "fixture")
        try await settle { coordinator.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1)
        coordinator.preferencesChanged()
        XCTAssertNil(coordinator.owner)
        coordinator.request(a, owner: owner, account: "fixture")
        try await settle { loader.replies == 2 && coordinator.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 2)
        coordinator.dismiss(owner: owner)
    }

    func testCookieChangesClearContentAndOnlyRestartInflightWorkOnce() async throws {
        let loader = FavouriteFixtureLoader()
        // Session changes must happen while both replies are still in flight,
        // even when a busy runner delays this test beyond the usual 50 ms reply.
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let coordinator = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        coordinator.request(a, owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        coordinator.sessionChanged(profileID: a.profileID)
        try await settle { loader.calls == 2 }
        XCTAssertEqual(coordinator.owner, owner)
        coordinator.sessionChanged(profileID: a.profileID)
        loader.releaseReplies()
        try await settle { loader.replies == 2 }
        XCTAssertEqual(coordinator.state, .unavailable)
        XCTAssertLessThanOrEqual(loader.calls, 2)
        coordinator.dismiss(owner: owner)
    }

    func testRoutineCookieUpdatesDoNotCancelPreviewButSessionChangesDo() async throws {
        _ = NSApplication.shared
        let loader = FavouriteFixtureLoader()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        func cookie(_ name: String, _ value: String, domain: String = ".github.com") -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE"])!
        }
        await store.setCookie(cookie("user_session", "fixture-session"))
        let observer = FavouriteSessionObserver(profileID: a.profileID, previews: previews, store: store)
        defer { observer.detach(); withExtendedLifetime(dataStore) {} }
        await observer.ready()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        let cancellations = loader.cancellations
        await store.setCookie(cookie("_gh_sess", "ordinary-page-update"))
        await store.setCookie(cookie("unrelated", "other-site", domain: ".example.test"))
        // Exercise the same snapshot comparison as cookie-store notifications.
        observer.refresh()
        await observer.ready()
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(loader.cancellations, cancellations)
        XCTAssertEqual(previews.owner, owner)
        await store.setCookie(cookie("user_session", "changed-session"))
        observer.refresh()
        await observer.ready()
        try await settle { loader.calls == 2 }
        loader.releaseReplies()
        previews.dismiss(owner: owner)
    }

}
