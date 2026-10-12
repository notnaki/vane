import XCTest
@testable import vane

@MainActor private final class FavouriteFixtureLoader: FavouritePreviewLoading {
    var calls = 0
    var cancellations = 0
    var wait: Duration = .milliseconds(50)
    var result: FavouritePreviewResult = .ready(.init(account: "fixture", items: []))
    func load(_ context: FavouritePreviewContext) async -> FavouritePreviewResult {
        calls += 1
        let reply = result
        // Deliberately ignores cancellation: a late WebKit callback must still be refused.
        try? await Task.sleep(for: wait)
        return reply
    }
    func cancel() { cancellations += 1 }
}

@MainActor final class FavouritePreviewLifecycleTests: XCTestCase {
    private func context(_ profile: UUID = UUID()) -> FavouritePreviewContext {
        FavouritePreviewContext(profileID: profile, url: URL(string: "https://github.com/")!)!
    }
    func testDismissCannotPublishLateReply() async throws {
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader)
        let owner = UUID()
        coordinator.request(context(), owner: owner, account: "fixture")
        await Task.yield()
        coordinator.dismiss(owner: owner)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(coordinator.owner)
        XCTAssertEqual(coordinator.state, .loading)
        XCTAssertGreaterThan(loader.cancellations, 0)
    }
    func testInvalidationRetiresContentAndInflightReplyOnlyForOwningProfile() async throws {
        let loader = FavouriteFixtureLoader()
        let previews = FavouritePreviews(loader: loader)
        let a = context(), b = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        await Task.yield()
        previews.invalidate(profileID: b.profileID)
        XCTAssertEqual(previews.owner, owner)
        previews.invalidate(profileID: a.profileID)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertNil(previews.owner)
        XCTAssertEqual(previews.state, .loading)
    }
    func testReplacementAndAccountIsolation() async throws {
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader)
        let a = context(), b = context(), first = UUID(), second = UUID()
        coordinator.request(a, owner: first, account: "fixture")
        await Task.yield()
        coordinator.request(b, owner: second, account: "other")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(coordinator.owner, second)
        // The page came back as a different account than the live favourite: fail closed.
        XCTAssertEqual(coordinator.state, .unavailable)
        coordinator.dismiss(owner: second)
    }
    func testRepeatHoverUsesVerifiedAccountCacheAndFailureHasCooldown() async throws {
        let loader = FavouriteFixtureLoader()
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(90))
        previews.dismiss(owner: owner)
        previews.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(loader.calls, 1)
        previews.dismiss(owner: owner)
        // An unverified identity must not reuse the previous account's cached data.
        previews.request(a, owner: owner, account: "other")
        try await Task.sleep(for: .milliseconds(20))
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
        try await Task.sleep(for: .milliseconds(90))
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(121)
        loader.result = .unavailable
        previews.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(previews.state, .stale(.init(account: "fixture", items: [])))
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(31)
        loader.result = .signedOut
        previews.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(previews.state, .signedOut)
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(31)
        loader.result = .unavailable
        previews.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(previews.state, .unavailable, "Signing out must purge the old account cache")
        previews.dismiss(owner: owner)
    }

    func testClearingBlocksReloadsUntilCompletionAndDisablePurgesCache() async throws {
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        coordinator.beginClearing(profileID: a.profileID)
        coordinator.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(loader.calls, 0)
        XCTAssertEqual(coordinator.state, .unavailable)
        coordinator.endClearing(profileID: a.profileID)
        coordinator.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(loader.calls, 1)
        coordinator.preferencesChanged()
        XCTAssertNil(coordinator.owner)
        coordinator.request(a, owner: owner, account: "fixture")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(loader.calls, 2)
        coordinator.dismiss(owner: owner)
    }

}
