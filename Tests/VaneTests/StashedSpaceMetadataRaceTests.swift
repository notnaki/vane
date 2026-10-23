import AppKit
import XCTest
@testable import vane

@MainActor final class StashedSpaceMetadataRaceTests: XCTestCase {
    private func fixture() async throws -> (TabStore, Space, vane.Tab, URL, [String: Parked]) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), url = URL(string: "https://stash-metadata.invalid/page")!
        let hidden = Space(name: "Hidden", profileID: profile, tabURLs: [url], pinnedTabURLs: [], colorHex: "#224466")
        let visible = Space(name: "Visible", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([hidden, visible], for: profile))
        Suspension.SpaceState.registerNewProfile(profileID: profile, in: Store.directory)
        let store = TabStore(profileID: profile, space: visible, session: [])
        let tab = vane.Tab(profileID: profile)
        tab.park(url: url, Parked(title: "Live hidden"))
        store.stashes[hidden.id] = Stash(tabs: [tab], pins: Pins(),
            todayShape: Pins(entries: [.init(row: .tab(tab.id.uuidString))]), splits: [], current: tab.id,
            fingerprint: store.fingerprint(of: hidden.id))
        let original = [url.absoluteString: Parked(title: "Persisted original", state: Data("old opaque state".utf8))]
        let saved = await Suspension.SpaceState.saveAsync(original, space: hidden.id, profileID: profile, in: Store.directory)
        XCTAssertTrue(saved)
        addTeardownBlock { @MainActor in
            store.dropStashes(); SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }; Store.forget(profile)
        }
        return (store, hidden, tab, url, original)
    }

    private func awaitStagedState(_ store: TabStore, hidden: Space, url: URL) async throws {
        let deadline = Date.now.addingTimeInterval(2)
        while Suspension.SpaceState.load(space: hidden.id, profileID: store.profileID, in: Store.directory)[url.absoluteString]?.title != "Live hidden" {
            if Date.now > deadline { throw NSError(domain: "StashStageTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testRenameAndAppearanceSurviveBlockedStashSave() async throws {
        let (store, hidden, _, url, _) = try await fixture()
        let entered = expectation(description: "persistence lane held"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        SessionPersistence.shared.enqueue(file: Store.directory.appendingPathComponent(UUID().uuidString)) {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5); return true
        }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await store.saveStashedSpaceAsync(hidden.id) }
        try await awaitStagedState(store, hidden: hidden, url: url)
        var edited = hidden
        edited.name = "Renamed in another window"
        edited.colorHex = "#aabbcc"; edited.icon = "moon"; edited.appearance = "dark"
        edited.colors = ["#aabbcc", "#ddeeff"]; edited.tint = 0.7; edited.grain = 0.1
        XCTAssertTrue(ProfileManager.shared.updateSpace(edited))
        release.signal()
        let saved = await operation.value
        XCTAssertTrue(saved)
        let latest = try XCTUnwrap(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == hidden.id })
        XCTAssertEqual(latest, edited)
        XCTAssertEqual(store.stashes[hidden.id]?.tabs.map(\.id).count, 1)
    }

    func testLayoutChangeRejectsStaleSaveAndRepairsOriginalSidecar() async throws {
        let (store, hidden, tab, url, original) = try await fixture()
        let entered = expectation(description: "persistence lane held"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        SessionPersistence.shared.enqueue(file: Store.directory.appendingPathComponent(UUID().uuidString)) {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5); return true
        }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await store.saveStashedSpaceAsync(hidden.id) }
        try await awaitStagedState(store, hidden: hidden, url: url)
        var edited = hidden
        edited.layout = TabStore.workspaceLayout(tabs: [tab], pins: Pins(), today: try XCTUnwrap(store.stashes[hidden.id]).todayShape, splits: [], selected: tab.id, profile: store.profileID)
        XCTAssertTrue(ProfileManager.shared.updateSpace(edited))
        release.signal()
        let saved = await operation.value
        XCTAssertFalse(saved)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == hidden.id }, edited)
        XCTAssertEqual(store.stashes[hidden.id]?.tabs.first?.id, tab.id)
        XCTAssertEqual(Suspension.SpaceState.load(space: hidden.id, profileID: store.profileID, in: Store.directory), original)
    }

    func testRejectedStashSavePreservesNewerPeerSidecar() async throws {
        let (store, hidden, tab, url, _) = try await fixture()
        let entered = expectation(description: "persistence lane held"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        SessionPersistence.shared.enqueue(file: Store.directory.appendingPathComponent(UUID().uuidString)) {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5); return true
        }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await store.saveStashedSpaceAsync(hidden.id) }
        try await awaitStagedState(store, hidden: hidden, url: url)
        var edited = hidden
        edited.layout = TabStore.workspaceLayout(tabs: [tab], pins: Pins(), today: try XCTUnwrap(store.stashes[hidden.id]).todayShape, splits: [], selected: tab.id, profile: store.profileID)
        XCTAssertTrue(ProfileManager.shared.updateSpace(edited))
        let newer = [url.absoluteString: Parked(title: "Newer peer", state: Data("new opaque state".utf8))]
        XCTAssertTrue(Suspension.SpaceState.enqueueSave(newer, space: hidden.id, profileID: store.profileID, in: Store.directory))
        release.signal()
        let saved = await operation.value
        XCTAssertFalse(saved)
        let flushed = await SessionPersistence.shared.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == hidden.id }, edited)
        XCTAssertEqual(store.stashes[hidden.id]?.tabs.first?.id, tab.id)
        XCTAssertEqual(Suspension.SpaceState.load(space: hidden.id, profileID: store.profileID, in: Store.directory), newer)
    }
    func testHiddenTabNavigationRejectsStaleCaptureWithoutReleasingPage() async throws {
        let (store, hidden, tab, url, original) = try await fixture()
        let entered = expectation(description: "persistence lane held"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        SessionPersistence.shared.enqueue(file: Store.directory.appendingPathComponent(UUID().uuidString)) {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5); return true
        }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await store.saveStashedSpaceAsync(hidden.id) }
        try await awaitStagedState(store, hidden: hidden, url: url)
        let destination = URL(string: "https://stash-metadata.invalid/new-page")!
        tab.park(url: destination, Parked(title: "Latest hidden page", state: Data("new navigation state".utf8)))
        release.signal()
        let saved = await operation.value
        XCTAssertFalse(saved)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == hidden.id }, hidden)
        XCTAssertTrue(store.stashes[hidden.id]?.tabs.first === tab)
        XCTAssertEqual(tab.currentURL, destination)
        XCTAssertEqual(tab.snapshot.state, Data("new navigation state".utf8))
        XCTAssertEqual(Suspension.SpaceState.load(space: hidden.id, profileID: store.profileID, in: Store.directory), original)
    }

    func testSameAddressNewDocumentRejectsStaleOpaqueStateCapture() async throws {
        let (store, hidden, tab, url, original) = try await fixture()
        let entered = expectation(description: "persistence lane held"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        SessionPersistence.shared.enqueue(file: Store.directory.appendingPathComponent(UUID().uuidString)) {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5); return true
        }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await store.saveStashedSpaceAsync(hidden.id) }
        try await awaitStagedState(store, hidden: hidden, url: url)
        tab.readingDocumentGeneration = UUID()
        release.signal()
        let saved = await operation.value
        XCTAssertFalse(saved)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == hidden.id }, hidden)
        XCTAssertTrue(store.stashes[hidden.id]?.tabs.first === tab)
        XCTAssertEqual(tab.currentURL, url)
        XCTAssertEqual(Suspension.SpaceState.load(space: hidden.id, profileID: store.profileID, in: Store.directory), original)
    }

}
