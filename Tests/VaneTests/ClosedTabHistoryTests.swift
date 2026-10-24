import AppKit
import XCTest
@testable import vane

@MainActor final class ClosedTabHistoryTests: XCTestCase {
    private var stores: [TabStore] = []
    private var server: CompatibilityServer!
    private var oldHTTPS = false
    private final class WeakTab {
        weak var value: Tab?
        init(_ value: Tab?) { self.value = value }
    }
    @MainActor private final class FaviconFetchGate {
        var started = false
        private var reply: CheckedContinuation<Data?, Never>?
        private var finished = false

        func fetch() async -> Data? {
            guard !finished else { return nil }
            return await withCheckedContinuation { reply in
                self.reply = reply
                started = true
            }
        }

        func finish() { finished = true; reply?.resume(returning: nil); reply = nil }
    }

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        oldHTTPS = HTTPSOnly.enabled
        HTTPSOnly.enabled = false
        while ClosedTabs.pop() != nil {}
        server = try CompatibilityServer()
        try await compatibilityWait { self.server.port != nil }
    }

    override func tearDown() async throws {
        while ClosedTabs.pop() != nil {}
        for store in stores {
            let tabs = store.everyTab
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            ExtensionHost.forget(store.profileID)
        }
        stores = []
        server.stop()
        server = nil
        HTTPSOnly.enabled = oldHTTPS
    }

    private func store(profile: UUID = UUID(), isPrivate: Bool = false) -> TabStore {
        let made = TabStore(isPrivate: isPrivate, profileID: profile, session: [])
        stores.append(made)
        return made
    }

    private func load(_ path: String, in tab: Tab) async throws {
        tab.navigate(to: try server.url(path))
        try await settled(path, in: tab)
    }

    private func settled(_ path: String, in tab: Tab) async throws {
        let url = try server.url(path)
        try await compatibilityWait {
            !tab.web.isLoading && !tab.loading && tab.web.url == url
                && tab.web.title == "Page \(path)"
        }
    }

    private func reopen(in store: TabStore) throws -> Tab {
        let closed = try XCTUnwrap(ClosedTabs.pop())
        return try XCTUnwrap(closed.reopen(in: store))
    }

    func testCloseReopenPreservesBackAndForwardHistory() async throws {
        let store = store()
        var original: Tab? = store.newBlankTab()
        let retired = WeakTab(original)
        for path in ["/a", "/b", "/c"] { try await load(path, in: original!) }
        let originalID = original!.id
        store.close(originalID)
        XCTAssertNil(original?.existingWeb, "Closing must release the live page")
        original = nil
        XCTAssertNil(retired.value, "The closed-tab stack cannot retain live tabs")
        let reopened = try reopen(in: store)
        XCTAssertNotEqual(reopened.id, originalID)
        XCTAssertEqual(reopened.kind, .today)
        try await settled("/c", in: reopened)
        XCTAssertEqual(reopened.web.backForwardList.backList.map { $0.url.path }, ["/a", "/b"])
        XCTAssertTrue(reopened.canGoBack, "Reopened C must enable the Back control")
        reopened.back()
        try await settled("/b", in: reopened)
        reopened.back()
        try await settled("/a", in: reopened)
        XCTAssertTrue(reopened.canGoForward, "History traversal must enable the Forward control")
        reopened.forward()
        try await settled("/b", in: reopened)
        reopened.forward()
        try await settled("/c", in: reopened)
    }

    func testClosingFromMiddleOfHistoryPreservesForwardBranch() async throws {
        let store = store()
        let original = store.newBlankTab()
        for path in ["/a", "/b", "/c"] { try await load(path, in: original) }
        _ = try XCTUnwrap(original.web.goBack())
        try await settled("/b", in: original)
        store.close(original.id)
        let reopened = try reopen(in: store)
        try await settled("/b", in: reopened)
        XCTAssertEqual(reopened.web.backForwardList.backList.map { $0.url.path }, ["/a"])
        XCTAssertEqual(reopened.web.backForwardList.forwardList.map { $0.url.path }, ["/c"])
        _ = try XCTUnwrap(reopened.web.goForward())
        try await settled("/c", in: reopened)
    }

    func testPendingFaviconFetchDoesNotRetainClosedTab() async throws {
        let store = store()
        var original: Tab? = store.newBlankTab()
        let retired = WeakTab(original)
        try await load("/pending-icon", in: original!)
        let gate = FaviconFetchGate()
        let cache = Favicons(profileID: store.profileID, fetch: { _ in await gate.fetch() })
        defer { gate.finish() }
        cache.load(for: original!)
        try await compatibilityWait { gate.started }
        store.close(original!.id)
        XCTAssertNil(original?.existingWeb, "Closing must release the live page")
        original = nil
        XCTAssertNil(retired.value, "An unfinished icon request cannot retain a closed tab")
        withExtendedLifetime(cache) {}
    }

    func testClosingSuspendedTabPreservesHistoryWithoutWakingIt() async throws {
        let store = store(), original = store.newBlankTab()
        for path in ["/a", "/b", "/c"] { try await load(path, in: original) }
        original.suspend()
        XCTAssertNil(original.existingWeb)
        store.close(original.id)
        XCTAssertNil(original.existingWeb)
        let reopened = try reopen(in: store)
        try await settled("/c", in: reopened)
        XCTAssertEqual(reopened.web.backForwardList.backList.map { $0.url.path }, ["/a", "/b"])
    }

    func testClosedStackKeepsOnlyNewest32EntriesInReverseCloseOrder() throws {
        let store = store()
        for n in 0..<35 {
            let tab = store.newBlankTab(focus: false)
            tab.park(url: try server.url("/\(n)"), Parked(title: "Page \(n)"))
            store.close(tab.id)
        }
        var paths: [String] = []
        while let entry = ClosedTabs.pop() { paths.append(entry.url.path) }
        XCTAssertEqual(paths, (3..<35).reversed().map { "/\($0)" })
    }

    func testPrivateScriptAndPinnedClosesLeaveNoReopenEntry() throws {
        for (privateTab, script, kind) in [(true, false, TabKind.today), (false, true, .today), (false, false, .pinned)] {
            let store = store(isPrivate: privateTab)
            let tab = store.newBlankTab(focus: false, as: kind)
            tab.park(url: try server.url("/secret"), Parked(title: "Secret"))
            store.close(tab.id, byScript: script)
            XCTAssertNil(ClosedTabs.pop())
        }
    }

    func testRecoveryBlockedTabReopensAsExplicitURLLoad() async throws {
        let store = store()
        let tab = store.newBlankTab(focus: false)
        tab.park(url: try server.url("/recovery"), Parked(title: "Recovery", needsRecovery: true))
        store.close(tab.id)
        let reopened = try reopen(in: store)
        XCTAssertFalse(reopened.needsRecovery)
        try await settled("/recovery", in: reopened)
    }

    func testCorruptStateFallsBackToURL() async throws {
        let store = store()
        let tab = store.newBlankTab(focus: false)
        tab.park(url: try server.url("/corrupt"), Parked(title: "Corrupt", state: Data("invalid-state".utf8)))
        store.close(tab.id)
        let reopened = try reopen(in: store)
        try await settled("/corrupt", in: reopened)
        XCTAssertFalse(reopened.web.canGoBack)
    }

    func testDifferentProfileReopensOnlyURLWithoutImportingHistory() async throws {
        let source = store(), destination = store()
        let tab = source.newBlankTab()
        for path in ["/origin-only", "/current"] { try await load(path, in: tab) }
        source.close(tab.id)
        let reopened = try reopen(in: destination)
        try await settled("/current", in: reopened)
        XCTAssertEqual(reopened.profileID, destination.profileID)
        XCTAssertFalse(reopened.web.canGoBack, "Session state belongs to its original profile")
    }

    func testPrivateDestinationReopensOnlyURLWithoutImportingHistory() async throws {
        let source = store(), destination = store(isPrivate: true)
        let tab = source.newBlankTab()
        for path in ["/regular-only", "/current"] { try await load(path, in: tab) }
        source.close(tab.id)
        let reopened = try reopen(in: destination)
        try await settled("/current", in: reopened)
        XCTAssertTrue(reopened.isPrivate)
        XCTAssertFalse(reopened.web.canGoBack)
    }

    func testUnavailableStateReopensURLInDestinationContext() async throws {
        let source = store(), destination = store()
        let tab = source.newBlankTab(focus: false)
        tab.park(url: try server.url("/fallback"), Parked(title: "Fallback"))
        source.close(tab.id)
        let reopened = try reopen(in: destination)
        XCTAssertEqual(reopened.profileID, destination.profileID)
        XCTAssertEqual(reopened.sharedSpaceID, destination.currentSpaceID)
        try await settled("/fallback", in: reopened)
        XCTAssertFalse(reopened.web.canGoBack)
    }
}
