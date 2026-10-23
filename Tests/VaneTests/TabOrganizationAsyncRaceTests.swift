import AppKit
import Combine
import XCTest
@testable import vane

@MainActor final class TabOrganizationAsyncRaceTests: XCTestCase {
    private func fixture() -> (TabStore, Space, Space) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let a = Space(name: "First", profileID: profile)
        let b = Space(name: "Other", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([a, b], for: profile))
        Suspension.SpaceState.registerNewProfile(profileID: profile, in: Store.directory)
        let store = TabStore(profileID: profile, space: a, session: [])
        addTeardownBlock { @MainActor in
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
            Store.forget(profile)
        }
        return (store, a, b)
    }
    private func tab(_ path: String, in store: TabStore) -> vane.Tab {
        let tab = store.newBlankTab(focus: false, as: .today)
        tab.restore(url: URL(string: "https://organizer-race.example/" + path)!, home: nil, parked: Parked(title: path))
        return tab
    }
    func testUnrelatedSpaceEditsAndInventoryChangesSurviveBlockedCommit() async throws {
        let (store, _, other) = fixture()
        let doomed = tab("archive", in: store)
        let deleted = Space(name: "Remove during save", profileID: store.profileID)
        XCTAssertTrue(ProfileManager.shared.updateSpace(deleted))
        let model = TabOrganization(store: store)
        model.selection = [doomed.id]
        let entered = expectation(description: "worker blocked"), release = DispatchSemaphore(value: 0)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SessionPersistence.shared.enqueue(file: marker) { entered.fulfill(); release.wait(); return true }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await model.archiveSelectedAsync() }
        while !model.working { await Task.yield() }
        var edited = other
        edited.name = "Renamed while worker waits"
        let added = Space(name: "Added", profileID: store.profileID)
        XCTAssertTrue(ProfileManager.shared.updateSpace(edited))
        XCTAssertTrue(ProfileManager.shared.updateSpace(added))
        XCTAssertTrue(ProfileManager.shared.deleteSpace(deleted.id, in: store.profileID))
        release.signal()
        let committed = await operation.value
        XCTAssertTrue(committed)
        let saved = ProfileManager.shared.spaces(for: store.profileID)
        XCTAssertEqual(saved.first { $0.id == other.id }?.name, edited.name)
        XCTAssertTrue(saved.contains { $0.id == added.id })
        XCTAssertFalse(saved.contains { $0.id == deleted.id })
    }
    func testAffectedSpaceMetadataChangeRejectsStaleCommit() async throws {
        let (store, first, _) = fixture()
        let doomed = tab("archive", in: store)
        let model = TabOrganization(store: store)
        model.selection = [doomed.id]
        let entered = expectation(description: "worker blocked"), release = DispatchSemaphore(value: 0)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SessionPersistence.shared.enqueue(file: marker) { entered.fulfill(); release.wait(); return true }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await model.archiveSelectedAsync() }
        while !model.working { await Task.yield() }
        var edited = ProfileManager.shared.spaces(for: store.profileID).first { $0.id == first.id }!
        edited.name = "Renamed during save"
        XCTAssertTrue(ProfileManager.shared.updateSpace(edited))
        release.signal()
        let committed = await operation.value
        XCTAssertFalse(committed)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == first.id }?.name, edited.name)
        XCTAssertTrue(store.tabs.contains { $0 === doomed })
    }

    func testRejectedClosedSpaceEditRestoresExactSidecarAndSession() async throws {
        let (store, _, closed) = fixture()
        let page = URL(string: "https://organizer-race.example/closed")!
        var saved = closed; saved.tabURLs = [page]
        XCTAssertTrue(ProfileManager.shared.updateSpace(saved))
        let parked = [page.absoluteString: Parked(title: "Closed page", state: Data("opaque navigation state".utf8))]
        let stateSaved = await Suspension.SpaceState.saveAsync(parked, space: closed.id,
            profileID: store.profileID, in: Store.directory)
        XCTAssertTrue(stateSaved)
        let sessionFile = ProfileManager.sessionURL(for: store.profileID, in: Store.directory)
        let session = try XCTUnwrap(Session.encode([[Session.Entry(url: page.absoluteString,
            title: "Closed page", state: Data("opaque navigation state".utf8).base64EncodedString())]],
            spaces: [closed.id.uuidString]))
        try session.write(to: sessionFile, options: .atomic)
        let sidecarFile = Suspension.SpaceState.url(for: store.profileID, in: Store.directory)
        let sidecar = try Data(contentsOf: sidecarFile)
        let model = TabOrganization(store: store)
        model.selection = [try XCTUnwrap(model.rows.first { $0.spaceID == closed.id }).id]
        let entered = expectation(description: "closed Space staging blocked"), release = DispatchSemaphore(value: 0)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        SessionPersistence.shared.enqueue(file: marker) { entered.fulfill(); release.wait(); return true }
        await fulfillment(of: [entered], timeout: 2)
        let operation = Task { await model.archiveSelectedAsync() }
        while !model.working { await Task.yield() }
        saved.name = "Renamed closed Space"
        XCTAssertTrue(ProfileManager.shared.updateSpace(saved))
        release.signal()
        let committed = await operation.value
        XCTAssertFalse(committed)
        XCTAssertEqual(try Data(contentsOf: sidecarFile), sidecar)
        XCTAssertEqual(try Data(contentsOf: sessionFile), session)
        XCTAssertEqual(Suspension.SpaceState.load(space: closed.id, profileID: store.profileID, in: Store.directory), parked)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == closed.id }?.name, saved.name)
    }

    func testUndoRejectsNewTabAddedAfterPublicationBeforeFinalFlush() async throws {
        let (store, _, _) = fixture()
        let doomed = tab("archive", in: store)
        let model = TabOrganization(store: store)
        model.selection = [doomed.id]
        let blocked = expectation(description: "post-publication worker blocked")
        let release = DispatchSemaphore(value: 0)
        // The publication emits the strip change synchronously, before final capture/flush.
        var token: AnyCancellable?
        var armed = true
        token = store.$tabs.sink { tabs in
            guard armed, !tabs.contains(where: { $0 === doomed }) else { return }
            armed = false
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            SessionPersistence.shared.enqueue(file: marker) { blocked.fulfill(); release.wait(); return true }
        }
        let operation = Task { await model.archiveSelectedAsync() }
        await fulfillment(of: [blocked], timeout: 2)
        let newcomer = tab("newcomer", in: store)
        release.signal()
        let committed = await operation.value
        XCTAssertTrue(committed)
        let undone = await model.undoAsync()
        XCTAssertFalse(undone)
        XCTAssertTrue(store.tabs.contains { $0 === newcomer })
        withExtendedLifetime(token) {}
    }
}
