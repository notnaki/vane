import XCTest
import WebKit
import ObjectiveC
@testable import vane

// Intercept only this store's first real cookie reply. Foreground adoption runs
// after WebKit reads the empty store, before the session observer receives it.
@MainActor private final class FavouriteCookiePreflightGate {
    static var current: FavouriteCookiePreflightGate?
    weak var store: WKHTTPCookieStore?
    var beforeDelivery: (@MainActor ([HTTPCookie]) -> Void)?
    var deliveries = 0
}

extension WKHTTPCookieStore {
    @objc(vane_preflightGetAllCookies:)
    fileprivate dynamic func vane_preflightGetAllCookies(_ completion: @escaping @MainActor ([HTTPCookie]) -> Void) {
        guard let gate = FavouriteCookiePreflightGate.current, self === gate.store,
              let beforeDelivery = gate.beforeDelivery else {
            vane_preflightGetAllCookies(completion); return
        }
        gate.beforeDelivery = nil
        vane_preflightGetAllCookies { cookies in
            gate.deliveries += 1
            beforeDelivery(cookies)
            completion(cookies)
        }
    }
}

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
    func testBackgroundWarmupCachesWithoutPublishingAndNeverInterruptsVisiblePreview() async throws {
        let loader = FavouriteFixtureLoader()
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        await previews.warm(a)
        XCTAssertEqual(loader.calls, 1)
        XCTAssertNil(previews.owner)
        XCTAssertEqual(previews.state, .loading)
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1, "Opening a warmed result should not load another page")
        await previews.warm(context())
        XCTAssertEqual(previews.owner, owner)
        XCTAssertEqual(loader.calls, 1, "Background work must not replace an open preview")
        previews.dismiss(owner: owner)
    }

    func testOpeningInFlightWarmupAdoptsItWithoutReloading() async throws {
        let loader = FavouriteFixtureLoader()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        let warming = Task { await previews.warm(a) }
        try await settle { loader.calls == 1 }
        previews.request(a, owner: owner)
        loader.releaseReplies()
        await warming.value
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(previews.owner, owner)
        previews.dismiss(owner: owner)
    }

    func testBackgroundBudgetAndPolicyAreRecheckedBetweenServices() async throws {
        let loader = FavouriteFixtureLoader()
        let previews = FavouritePreviews(loader: loader)
        let warmer = FavouritePreviewWarmup(previews: previews)
        let candidates = (0..<6).map { _ in FavouritePreviewWarmup.Candidate(context: context()) }
        await warmer.refresh(candidates, allowed: { false })
        XCTAssertEqual(loader.calls, 0)
        await warmer.refresh(candidates, allowed: { true })
        XCTAssertEqual(loader.calls, 3, "Only three services may consume the background budget")
        await warmer.refresh(Array(candidates.suffix(3)), allowed: { loader.calls < 4 })
        XCTAssertEqual(loader.calls, 4, "A policy change stops the remaining background batch")
        XCTAssertNil(previews.owner)
    }

    func testCancellingBackgroundWorkCannotCancelAdoptedForegroundRequest() async throws {
        let loader = FavouriteFixtureLoader()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        let warming = Task { await previews.warm(a) }
        try await settle { loader.calls == 1 }
        previews.request(a, owner: owner)
        let cancellations = loader.cancellations
        previews.cancelWarmup()
        XCTAssertEqual(loader.cancellations, cancellations)
        loader.releaseReplies()
        await warming.value
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        previews.dismiss(owner: owner)
    }

    func testForegroundAdoptionDuringUnsignedCookiePreflightStillCompletes() async throws {
        TestEnvironment.prepare()
        let loader = FavouriteFixtureLoader(), owner = UUID()
        let a = context(ProfileManager.shared.active.id)
        let dataStore = WKWebsiteDataStore.nonPersistent(), gate = FavouriteCookiePreflightGate()
        let store = dataStore.httpCookieStore
        let original = try XCTUnwrap(class_getInstanceMethod(WKHTTPCookieStore.self, NSSelectorFromString("getAllCookies:")))
        let gated = try XCTUnwrap(class_getInstanceMethod(WKHTTPCookieStore.self, #selector(WKHTTPCookieStore.vane_preflightGetAllCookies(_:))))
        gate.store = store; FavouriteCookiePreflightGate.current = gate
        method_exchangeImplementations(original, gated)
        defer {
            gate.beforeDelivery = nil; FavouriteCookiePreflightGate.current = nil
            method_exchangeImplementations(original, gated)
            withExtendedLifetime(dataStore) {}
        }
        func diagnostic(_ previews: FavouritePreviews) -> String {
            let fields = Mirror(reflecting: previews).children
            let names = ["generation", "loading", "preparing", "foregroundIntent", "initialSessionPending", "preparedState"]
            return "state=\(previews.state), owner=\(String(describing: previews.owner)), loader=\(loader.calls)/\(loader.replies), "
                + fields.compactMap { field in
                    guard let name = field.label, names.contains(name) else { return nil }
                    return "\(name)=\(field.value)"
                }.joined(separator: ", ")
        }
        let previews = FavouritePreviews(loader: loader, observeSessions: true,
            sessionObserverFactory: { id, coordinator in
                gate.beforeDelivery = { cookies in
                    XCTAssertTrue(cookies.isEmpty, "The held preflight must be WebKit's actual empty-cookie result")
                    XCTAssertEqual(loader.calls, 0, "Adopt before extraction or hidden-page loading begins")
                    XCTAssertNil(coordinator.owner)
                    print("COOKIE PREFLIGHT before adoption: cookies=\(cookies.count), \(diagnostic(coordinator))")
                    coordinator.request(a, owner: owner)
                    XCTAssertEqual(coordinator.owner, owner)
                    print("COOKIE PREFLIGHT after adoption: \(diagnostic(coordinator))")
                }
                return FavouriteSessionObserver(profileID: id, previews: coordinator, store: store)
            })
        defer { previews.dismiss(owner: owner) }
        await previews.warm(a)
        try await settle { previews.owner == owner && previews.state == .ready(.init(account: "fixture", items: [])) }
        print("COOKIE PREFLIGHT final: deliveries=\(gate.deliveries), \(diagnostic(previews))")
        XCTAssertEqual(gate.deliveries, 1)
        XCTAssertEqual(loader.calls, 1)
        XCTAssertEqual(loader.replies, 1)
        XCTAssertEqual(previews.owner, owner)
        guard previews.state == .ready(.init(account: "fixture", items: [])) else { return }
        previews.dismiss(owner: owner)
        previews.request(a, owner: owner)
        try await settle { previews.state == .unavailable }
        XCTAssertEqual(loader.calls, 1, "A fresh unsigned result must not become authenticated cache replay")
    }

    func testQuickReturnAfterCookiePreflightAdoptionKeepsForegroundOwner() async throws {
        TestEnvironment.prepare()
        let loader = FavouriteFixtureLoader(), owner = UUID()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let a = context(ProfileManager.shared.active.id)
        let store = WKWebsiteDataStore.nonPersistent().httpCookieStore
        let previews = FavouritePreviews(loader: loader, observeSessions: true,
            sessionObserverFactory: { id, coordinator in
                Task { @MainActor in coordinator.request(a, owner: owner) }
                return FavouriteSessionObserver(profileID: id, previews: coordinator, store: store)
            })
        let warming = Task { await previews.warm(a) }
        try await settle { loader.calls == 1 }
        XCTAssertEqual(previews.owner, owner)
        previews.dismiss(owner: owner)
        previews.request(a, owner: owner)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loader.calls, 1, "A quick return must reattach to the adopted load")
        loader.releaseReplies()
        await warming.value
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        previews.dismiss(owner: owner)
    }

    func testFinalSessionProofRejectsChangedAccountEvenWithoutCookieNotification() async throws {
        TestEnvironment.prepare()
        let loader = FavouriteFixtureLoader(), owner = UUID()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let a = context(ProfileManager.shared.active.id)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        defer { withExtendedLifetime(dataStore) {} }
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "user_session", .value: value, .secure: "TRUE"])!
        }
        func fingerprint() async -> FavouriteSessionFingerprint {
            let cookies = await withCheckedContinuation { continuation in
                store.getAllCookies { continuation.resume(returning: $0) }
            }
            return FavouriteSessionFingerprint(cookies)
        }
        await store.setCookie(cookie("original-session"))
        let original = await fingerprint()
        XCTAssertTrue(original.hasAuthentication(for: .github))
        let previews = FavouritePreviews(loader: loader, observeSessions: true,
            sessionObserverFactory: { id, coordinator in
                let observer = FavouriteSessionObserver(profileID: id, previews: coordinator, store: store)
                // Isolate final cookie proof from automatic notification invalidation.
                // The post-load comparison must protect data independently of callbacks.
                observer.previews = nil
                return observer
            })
        previews.request(a, owner: owner)
        try await settle { loader.calls == 1 }
        await store.setCookie(cookie("replacement-session"))
        let replacement = await fingerprint()
        XCTAssertNotEqual(original, replacement)
        loader.releaseReplies()
        try await settle { loader.replies == 1 && previews.state != .loading }
        XCTAssertEqual(previews.state, .unavailable, "An extracted account must not publish after its session changes")
        previews.dismiss(owner: owner)
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state != .loading }
        XCTAssertEqual(previews.state, .unavailable, "The rejected account must not have entered the cache")
        previews.dismiss(owner: owner)
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

    func testRepeatHoverWithoutLivePageReusesVerifiedSessionAndRetiresItOnChange() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "user_session", .value: value, .secure: "TRUE"])!
        }
        await store.setCookie(cookie("fixture-session"))
        var clock = Date(timeIntervalSince1970: 1000)
        let loader = FavouriteFixtureLoader()
        var observer: FavouriteSessionObserver?
        let previews = FavouritePreviews(loader: loader, observeSessions: true, now: { clock }, sessionObserverFactory: { profile, previews in
            let value = FavouriteSessionObserver(profileID: profile, previews: previews, store: store)
            observer = value
            return value
        })
        let a = context(ProfileManager.shared.active.id), owner = UUID()
        defer { previews.dismiss(owner: owner); observer?.detach(); withExtendedLifetime(dataStore) {} }
        previews.request(a, owner: owner)
        try await settle { loader.replies == 1 && previews.state == .ready(.init(account: "fixture", items: [])) }
        previews.dismiss(owner: owner)
        clock = clock.addingTimeInterval(31)
        previews.request(a, owner: owner)
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1, "Repeat hover should not reload the service website")
        previews.dismiss(owner: owner)
        await store.setCookie(cookie("replacement-session"))
        observer?.refresh()
        await observer?.ready()
        clock = clock.addingTimeInterval(31)
        previews.request(a, owner: owner)
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 2, "A changed session must load and verify again")
    }

    func testAlreadyLoadedListDoesNotStartAnotherWebsiteLoad() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let host = PreviewHostWindow(content: web)
        defer { web.stopLoading(); host.contentView = nil; host.close() }
        web.loadHTMLString("""
        <meta name="user-login" content="fixture">
        <div class="js-issue-row"><a class="Link--primary" href="/fixture/repo/pull/42">Fixture PR</a></div>
        """, baseURL: URL(string: "https://github.com/pulls?q=is:open%20is:pr%20involves:@me")!)
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let loader = FavouriteFixtureLoader()
        let coordinator = FavouritePreviews(loader: loader), owner = UUID()
        defer { coordinator.dismiss(owner: owner) }
        coordinator.request(context(), owner: owner, source: web)
        try await settle {
            guard case .ready(let value) = coordinator.state else { return false }
            return value.items.first?.title == "Fixture PR"
        }
        XCTAssertEqual(loader.calls, 0)
    }

    func testQuickReturnReusesTheSameInflightRequest() async throws {
        let loader = FavouriteFixtureLoader()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        let cancellations = loader.cancellations
        previews.dismiss(owner: owner)
        previews.request(a, owner: owner, account: "fixture")
        XCTAssertEqual(loader.cancellations, cancellations)
        loader.releaseReplies()
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1)
        previews.dismiss(owner: owner)
    }

    func testClosedRequestFillsCacheWithoutPublishingIntoDismissedCard() async throws {
        let loader = FavouriteFixtureLoader()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        previews.dismiss(owner: owner)
        loader.releaseReplies()
        try await settle { loader.replies == 1 }
        XCTAssertNil(previews.owner)
        XCTAssertEqual(previews.state, .loading)
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 1)
        previews.dismiss(owner: owner)
    }

    func testInvalidationRetiresClosedWarmCompletionBeforeItCanCache() async throws {
        let loader = FavouriteFixtureLoader()
        loader.holdReplies = true
        defer { loader.releaseReplies() }
        let previews = FavouritePreviews(loader: loader), a = context(), owner = UUID()
        previews.request(a, owner: owner, account: "fixture")
        try await settle { loader.calls == 1 }
        previews.dismiss(owner: owner)
        previews.invalidate(profileID: a.profileID)
        loader.releaseReplies()
        try await settle { loader.replies == 1 }
        previews.request(a, owner: owner, account: "fixture")
        try await settle { previews.state == .ready(.init(account: "fixture", items: [])) }
        XCTAssertEqual(loader.calls, 2, "Invalidated in-flight data must never repopulate the cache")
        previews.dismiss(owner: owner)
    }

}
