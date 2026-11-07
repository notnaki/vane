import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SuspensionMembershipTests: XCTestCase {
    private var stores: [TabStore] = []
    private var tabs: [vane.Tab] = []
    private var profiles = Set<UUID>()
    private var previousSuspension: Bool?

    override func tearDown() async throws {
        if let previousSuspension { Prefs.suspendTabs = previousSuspension }
        for tab in tabs { tab.tearDown() }
        let owned = Set(stores.map(ObjectIdentifier.init))
        TabStore.all.removeAll { owned.contains(ObjectIdentifier($0)) }
        stores.removeAll(); tabs.removeAll()
        try await NativeFixtureProfileCleanup.release(profiles)
        profiles.removeAll()
    }

    private func store(isPrivate: Bool = true, profile: UUID = UUID()) -> TabStore {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: isPrivate, profileID: profile, session: [])
        store.sharingReady = false
        stores.append(store)
        return store
    }

    private func tab(id: UUID = UUID(), isPrivate: Bool = true, profile: UUID = UUID()) -> vane.Tab {
        let tab = vane.Tab(id: id, isPrivate: isPrivate, profileID: profile)
        tabs.append(tab)
        return tab
    }

    private func stash(_ tabs: [vane.Tab]) -> Stash {
        Stash(tabs: tabs, pins: Pins(), todayShape: Pins(), splits: [], current: nil, fingerprint: "")
    }

    func testMembershipDeduplicatesObjectsWithoutConflatingRestoredIDs() {
        let first = store(), second = store()
        let shared = tab(), restored = tab(id: shared.id), hidden = tab()
        first.tabs = [shared]
        first.stashes[UUID()] = stash([hidden, shared])
        second.tabs = [shared, restored]
        let membership = Suspension.Membership(stores: [first, second])
        XCTAssertEqual(membership.tabs.count, 3)
        XCTAssertTrue(membership.tabs[0] === shared)
        XCTAssertTrue(membership.contains(shared))
        XCTAssertTrue(membership.contains(restored))
        XCTAssertTrue(membership.contains(hidden))
        XCTAssertFalse(membership.contains(tab(id: shared.id)))
    }

    func testActiveSplitUsesTheExactObjectsInEachVisibleStrip() throws {
        let visible = store(), hidden = store()
        let selected = tab(), neighbour = tab(), sameID = tab(id: neighbour.id)
        // Set selection before installing blank rows, so this fixture creates no pages.
        visible.current = selected.id
        visible.splits = [try XCTUnwrap(Split(tabs: [selected.id, neighbour.id]))]
        visible.tabs = [selected, neighbour]
        hidden.stashes[UUID()] = stash([sameID])
        let membership = Suspension.Membership(stores: [visible, hidden])
        XCTAssertTrue(membership.isActive(selected))
        XCTAssertTrue(membership.isActive(neighbour))
        XCTAssertFalse(membership.isActive(sameID))
        XCTAssertTrue(membership.isStashed(sameID))
    }

    func testVisibleSharedPinWinsOverStashAndSnapshotsDoNotFollowLaterChanges() {
        let first = store(), second = store()
        let pin = tab(); pin.kind = .pinned
        first.stashes[UUID()] = stash([pin])
        second.tabs = [pin]
        let visible = Suspension.Membership(stores: [first, second])
        XCTAssertFalse(visible.isStashed(pin))
        second.tabs = []
        let hidden = Suspension.Membership(stores: [first, second])
        XCTAssertTrue(hidden.isStashed(pin))
        XCTAssertFalse(visible.isStashed(pin), "A synchronous sweep must use one consistent ownership snapshot")
        first.stashes = [:]
        XCTAssertTrue(hidden.contains(pin))
        XCTAssertFalse(Suspension.Membership(stores: [first, second]).contains(pin))
    }

    func testMembershipTraversesStoresOnceRegardlessOfTabQueries() {
        let owners = [store(), store(), store()]
        for owner in owners { owner.tabs = (0..<128).map { _ in tab() } }
        var visits = 0
        let counted = AnySequence<TabStore> {
            var iterator = owners.makeIterator()
            return AnyIterator {
                let next = iterator.next()
                if next != nil { visits += 1 }
                return next
            }
        }
        let membership = Suspension.Membership(stores: counted)
        XCTAssertEqual(membership.tabs.count, 384)
        XCTAssertEqual(visits, 3)
        for _ in 0..<4 {
            for tab in membership.tabs {
                XCTAssertTrue(membership.contains(tab))
                XCTAssertFalse(membership.isActive(tab))
                XCTAssertFalse(membership.isStashed(tab))
            }
        }
        XCTAssertEqual(visits, 3, "Per-tab facts must not revisit the owners collection")
    }

    private func backgroundPage(stashedPin: Bool = false) async throws -> (TabStore, vane.Tab) {
        let profile = UUID()
        let owner = store(isPrivate: false, profile: profile)
        profiles.insert(profile)
        WebKitStartup.prepare()
        let page = tab(isPrivate: false, profile: profile)
        page.web.loadSimulatedRequest(URLRequest(url: URL(string: "https://suspension-membership.example.test/")!),
                                      responseHTML: "<title>Membership fixture</title><textarea></textarea>")
        try await compatibilityWait { !page.web.isLoading && page.web.title == "Membership fixture" }
        if stashedPin {
            page.kind = .pinned
            owner.stashes[UUID()] = stash([page])
        } else { owner.tabs = [page] }
        page.lastActive = .distantPast
        previousSuspension = Prefs.suspendTabs
        Prefs.suspendTabs = true
        return (owner, page)
    }

    func testRestoredObjectWithSameIDCannotKeepRemovedPageEligibleAfterAwait() async throws {
        let (owner, page) = try await backgroundPage()
        let restored = tab(id: page.id, isPrivate: false, profile: owner.profileID)
        var probed = false
        await Suspension.suspendIfEligible(page, underPressure: true, draftCheck: { _ in
            probed = true
            owner.tabs = [restored]
            return false
        })
        XCTAssertTrue(probed)
        XCTAssertFalse(page.suspended)
        XCTAssertNotNil(page.existingWeb)
    }

    func testStashedPinMadeVisibleDuringProbeKeepsItsPage() async throws {
        let (_, page) = try await backgroundPage(stashedPin: true)
        let visible = store(isPrivate: false, profile: page.profileID)
        var probed = false
        await Suspension.suspendIfEligible(page, underPressure: true, draftCheck: { _ in
            probed = true
            visible.tabs = [page]
            return false
        })
        XCTAssertTrue(probed)
        XCTAssertFalse(page.suspended, "Fresh visible-strip ownership restores the pinned exemption")
    }

    func testNewSplitNeighbourAndOwnershipChangeDuringProbeKeepTheirPages() async throws {
        let (owner, page) = try await backgroundPage()
        let neighbour = tab()
        await Suspension.suspendIfEligible(page, underPressure: true, draftCheck: { _ in
            owner.current = neighbour.id
            owner.tabs = [page, neighbour]
            owner.splits = [try! XCTUnwrap(Split(tabs: [page.id, neighbour.id]))]
            return false
        })
        XCTAssertFalse(page.suspended, "The pane beside a newly selected tab remains visible")
        owner.current = nil; owner.splits = []
        page.lastActive = .distantPast
        await Suspension.suspendIfEligible(page, underPressure: true, draftCheck: { _ in
            page.presentationOwner = UUID()
            return false
        })
        XCTAssertFalse(page.suspended, "A completed probe cannot retire another presentation owner")
    }
}
