import Combine
import XCTest
@testable import vane

/// Gate a real file read after it has produced its immutable snapshot. A late old
/// request can then finish after a newer one without scheduler-dependent sleeps.
private final class LibraryCatalogReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let blockedCall: Int
    private var count = 0
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var mainThread = false

    init(blockedCall: Int = 1) { self.blockedCall = blockedCall }
    var calls: Int { lock.withLock { count } }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    func load(directory: URL, profiles: [UUID]) -> [LibrarySpaceCatalog.Entry] {
        let rows = LibrarySpaceCatalog.read(directory: directory, profiles: profiles)
        let block = lock.withLock {
            count += 1; mainThread = mainThread || Thread.isMainThread
            guard count == blockedCall else { return false }
            entered = true; waiter?.resume(); waiter = nil
            return true
        }
        // A main-thread regression should assert, never deadlock the suite.
        if block && !Thread.isMainThread { release.wait() }
        return rows
    }
    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if entered { continuation.resume() } else { waiter = continuation }
            }
        }
    }
    func resume() { release.signal() }
}

@MainActor final class LibrarySpaceCatalogTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-library-spaces-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }
    private func defaults(_ shape: Pins, kind: TabKind, space: Space) throws {
        let key = TabStore.shapeKey(kind, space: space.id, profileID: space.profileID)
        let previous = UserDefaults.vane.data(forKey: key)
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        addTeardownBlock {
            if let previous { UserDefaults.vane.set(previous, forKey: key) }
            else { UserDefaults.vane.removeObject(forKey: key) }
        }
    }

    // Fails if the worker is moved onto MainActor or repeated redraws launch reads.
    func testBlockedLoadingLeavesMainActorAvailableAndCoalescesRepeatedPreparation() async throws {
        let manager = try manager()
        let space = manager.createSpace(name: "Home", in: manager.active.id)
        let gate = LibraryCatalogReadGate(); defer { gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        let pending = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        XCTAssertFalse(gate.ranOnMain)
        for _ in 0..<20 {
            catalog.prepare(manager: manager)
            XCTAssertTrue(catalog.spaces(manager: manager).isEmpty)
            XCTAssertNil(catalog.entry(for: space, manager: manager), "Saved rows must not appear before their protection shape is known")
        }
        XCTAssertEqual(gate.calls, 1)
        gate.resume(); await pending?.value
        XCTAssertEqual(catalog.spaces(manager: manager), [space])
        XCTAssertNotNil(catalog.entry(for: space, manager: manager))
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(gate.calls, 1)
    }

    // Fails if a late request overwrites a newer revision, or refresh empties card identities.
    func testRevisionRefreshRetainsCardMetadataButWithholdsSavedRowsUntilCurrentProtectionArrives() async throws {
        let manager = try manager()
        var home = manager.createSpace(name: "Original", in: manager.active.id)
        let gate = LibraryCatalogReadGate(blockedCall: 2); defer { gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        await catalog.prepare(manager: manager)?.value
        XCTAssertNotNil(catalog.entry(for: home, manager: manager))
        home.name = "Current"; XCTAssertTrue(manager.updateSpace(home))
        let old = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        XCTAssertEqual(catalog.spaces(manager: manager).map(\.id), [home.id])
        XCTAssertEqual(catalog.spaces(manager: manager).first?.name, "Original")
        XCTAssertNil(catalog.entry(for: home, manager: manager), "A previous unlocked shape cannot authorize rows after a new revision")
        home.name = "Newest"; XCTAssertTrue(manager.updateSpace(home))
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.spaces(manager: manager), [home])
        gate.resume(); await old?.value
        XCTAssertEqual(catalog.spaces(manager: manager), [home])
        XCTAssertNotNil(catalog.entry(for: home, manager: manager))
    }

    // Fails if retained snapshots resurrect removed profiles or previews leak ownership/persist.
    func testRemovedProfilesDisappearImmediatelyAndPreviewRemainsAnInMemoryOverlay() async throws {
        let manager = try manager()
        let home = manager.createSpace(name: "Home", in: manager.active.id)
        let other = manager.create(name: "Other")
        let work = manager.createSpace(name: "Work", in: other.id)
        let catalog = LibrarySpaceCatalog()
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.spaces(manager: manager).map(\.id), [home.id, work.id])
        var preview = home; preview.name = "Unsaved preview"
        XCTAssertEqual(catalog.spaces(manager: manager, preview: preview).first?.name, "Unsaved preview")
        XCTAssertEqual(manager.spaces(for: home.profileID), [home])
        var foreign = preview; foreign.profileID = other.id
        XCTAssertEqual(catalog.spaces(manager: manager, preview: foreign).first, home)
        XCTAssertTrue(manager.delete(other.id))
        XCTAssertEqual(catalog.spaces(manager: manager), [home], "Read access must filter removed profiles before another worker finishes")
        XCTAssertNil(catalog.entry(for: work, manager: manager))
    }

    // Fails if reopening reuses stale disk metadata with an unchanged in-process revision.
    func testForceRefreshReadsExternalChangesAndCancellationCannotPublishLateRows() async throws {
        let manager = try manager()
        var home = manager.createSpace(name: "Home", in: manager.active.id)
        let gate = LibraryCatalogReadGate(blockedCall: 2); defer { gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        await catalog.prepare(manager: manager)?.value
        let revision = manager.spacesRevision
        home.name = "Changed on disk"
        try JSONEncoder().encode([home]).write(to: ProfileManager.spacesURL(for: home.profileID, in: manager.directory))
        let pending = catalog.prepare(manager: manager, force: true)
        await gate.waitForEntry()
        XCTAssertEqual(catalog.spaces(manager: manager).first?.name, "Home")
        XCTAssertNil(catalog.entry(for: home, manager: manager))
        catalog.cancel()
        gate.resume(); await pending?.value
        XCTAssertEqual(catalog.spaces(manager: manager).first?.name, "Home")
        XCTAssertNil(catalog.entry(for: home, manager: manager))
        await catalog.prepare(manager: manager, force: true)?.value
        XCTAssertEqual(manager.spacesRevision, revision)
        XCTAssertEqual(catalog.spaces(manager: manager), [home])
        XCTAssertEqual(gate.calls, 3)
    }

    // Fails if manager identity is omitted from the request/snapshot guard.
    func testReplacementManagerRejectsOldCompletionEvenWithTheSameProfileIDs() async throws {
        let first = try manager(), second = try manager()
        _ = first.createSpace(name: "First", in: first.active.id)
        let home = second.createSpace(name: "Second", in: second.active.id)
        XCTAssertEqual(first.profiles.map(\.id), second.profiles.map(\.id))
        let gate = LibraryCatalogReadGate(); defer { gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: first)
        await gate.waitForEntry()
        await catalog.prepare(manager: second)?.value
        gate.resume(); await old?.value
        XCTAssertEqual(catalog.spaces(manager: second), [home])
        XCTAssertTrue(catalog.spaces(manager: first).isEmpty)
    }

    // Fails if a retained card or an already-open editor can overwrite a later mutation.
    func testRetainedCardCannotEditOrCommitAfterExternalRevisionOrDeletion() async throws {
        let manager = try manager()
        var home = manager.createSpace(name: "Original", in: manager.active.id)
        let gate = LibraryCatalogReadGate(blockedCall: 2); defer { gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        await catalog.prepare(manager: manager)?.value
        let session = try XCTUnwrap(catalog.beginEditing(for: home, manager: manager))
        home.name = "Changed elsewhere"; XCTAssertTrue(manager.updateSpace(home))
        let pending = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        XCTAssertEqual(catalog.spaces(manager: manager).first?.name, "Original")
        XCTAssertNil(catalog.beginEditing(for: home, manager: manager), "Display retention must not grant edit permission")
        XCTAssertFalse(session.isCurrent)
        var invoked = false
        XCTAssertFalse(session.perform {
            invoked = true
            _ = manager.updateSpace(session.space)
        }, "Popover disappearance must not commit its old copy")
        XCTAssertFalse(invoked)
        XCTAssertEqual(manager.spaces(for: home.profileID), [home])
        XCTAssertTrue(manager.deleteSpace(home.id, in: home.profileID))
        XCTAssertFalse(session.perform { _ = manager.updateSpace(session.space) })
        XCTAssertTrue(manager.spaces(for: home.profileID).isEmpty, "Revoked editing cannot recreate a deleted Space")
        gate.resume(); await pending?.value
        await catalog.prepare(manager: manager)?.value
        XCTAssertTrue(catalog.spaces(manager: manager).isEmpty)
    }

    // Fails if normal successive theme commits revoke their own editor, or reopening fails to revoke it.
    func testAnEditorsOwnCommitRenewsItsRevisionButOpeningEpochAndProfileChangesRevokeIt() async throws {
        let manager = try manager()
        let home = manager.createSpace(name: "Home", in: manager.active.id)
        let gate = LibraryCatalogReadGate(blockedCall: 2); defer { gate.resume() }
        let catalog = LibrarySpaceCatalog(load: gate.load)
        await catalog.prepare(manager: manager)?.value
        let session = try XCTUnwrap(catalog.beginEditing(for: home, manager: manager))
        var edited = home; edited.name = "First edit"
        XCTAssertTrue(session.perform { XCTAssertTrue(manager.updateSpace(edited)) })
        XCTAssertTrue(session.isCurrent)
        let refresh = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        XCTAssertTrue(session.isCurrent, "Refreshing the editor's own committed revision must not discard its interaction")
        edited.name = "Second edit"
        XCTAssertTrue(session.perform { XCTAssertTrue(manager.updateSpace(edited)) })
        XCTAssertTrue(session.isCurrent)
        gate.resume(); await refresh?.value
        await catalog.prepare(manager: manager)?.value
        let fresh = try XCTUnwrap(catalog.beginEditing(for: home, manager: manager))
        XCTAssertEqual(fresh.space.name, "Second edit", "A retained argument must resolve the current entry before editing")
        catalog.cancel()
        XCTAssertTrue(fresh.isCurrent, "Normal dismissal must allow the current editor's intentional disappearance save")
        var dismissal = fresh.space; dismissal.name = "Saved on dismissal"
        XCTAssertTrue(fresh.perform { XCTAssertTrue(manager.updateSpace(dismissal)) })
        XCTAssertNil(catalog.beginEditing(for: home, manager: manager), "Cancellation does not admit another editor from retained metadata")
        let reopen = catalog.prepare(manager: manager, force: true)
        XCTAssertFalse(fresh.isCurrent)
        XCTAssertFalse(fresh.perform { _ = manager.updateSpace(home) })
        await reopen?.value
        let next = try XCTUnwrap(catalog.beginEditing(for: home, manager: manager))
        _ = manager.create(name: "Other profile")
        XCTAssertFalse(next.isCurrent)
        XCTAssertFalse(next.perform { _ = manager.updateSpace(home) })
        XCTAssertEqual(manager.spaces(for: home.profileID).first?.name, "Saved on dismissal")
    }

    // Fails if layout validation/ownership filtering or defaults-backed lock filtering is skipped.
    func testWorkerUsesValidatedLayoutForBothShapesAndFallsBackToDefaultsWithoutDisclosingLockedToday() async throws {
        let manager = try manager()
        let url = URL(string: "https://today.example/")!, pinURL = URL(string: "https://pin.example/")!
        let todayID = UUID(), pinID = UUID()
        let locked = Folder(name: "Protected", requiresAuthentication: true)
        var space = Space(name: "Layout", profileID: manager.active.id, tabURLs: [url], pinnedTabURLs: [pinURL])
        let pinShape = Pins(entries: [.init(row: .tab(pinID.uuidString), parent: nil)])
        let todayShape = Pins(entries: [.init(row: .folder(locked), parent: nil),
            .init(row: .tab(todayID.uuidString), parent: locked.id)])
        space.layout = SpaceLayout(tabs: [
            .init(id: pinID, url: pinURL, kind: .pinned, title: "Pinned"),
            .init(id: todayID, url: url, kind: .today, title: "Today")],
            pins: pinShape, today: todayShape, splits: [], selected: todayID)
        XCTAssertTrue(manager.updateSpace(space))
        // Conflicting defaults must lose to a valid matching embedded layout.
        try defaults(Pins(), kind: .pinned, space: space)
        try defaults(Pins(), kind: .today, space: space)
        let catalog = LibrarySpaceCatalog()
        await catalog.prepare(manager: manager)?.value
        let entry = try XCTUnwrap(catalog.entry(for: space, manager: manager))
        XCTAssertEqual(entry.pinned?.tabs, [pinURL.absoluteString])
        XCTAssertEqual(entry.today?.tabs, [url.absoluteString])
        XCTAssertTrue(entry.visibleToday.isEmpty)
        // Invalid layout follows the exact existing fallback, rather than trusting its IDs.
        space.layout?.today.entries[1].parent = UUID()
        XCTAssertTrue(space.layout!.matches(space), "The URL-list guard must pass so validation itself rejects this malformed parent")
        XCTAssertThrowsError(try space.layout!.validate())
        let fallbackPinned = Pins(entries: [.init(row: .tab(pinURL.absoluteString), parent: nil)])
        let fallbackToday = Pins(entries: [.init(row: .folder(locked), parent: nil),
            .init(row: .tab(url.absoluteString), parent: locked.id)])
        try defaults(fallbackPinned, kind: .pinned, space: space)
        try defaults(fallbackToday, kind: .today, space: space)
        // Direct bytes preserve the invalid-layout fallback fixture without saveSpaces reconciliation.
        try JSONEncoder().encode([space]).write(to: ProfileManager.spacesURL(for: space.profileID, in: manager.directory))
        await catalog.prepare(manager: manager, force: true)?.value
        let fallback = try XCTUnwrap(catalog.entry(for: space, manager: manager))
        XCTAssertEqual(fallback.pinned, fallbackPinned)
        XCTAssertEqual(fallback.today, fallbackToday)
        XCTAssertTrue(fallback.visibleToday.isEmpty)
        // A foreign entry in the wrong profile file must never become a card.
        var foreign = space; foreign.profileID = UUID()
        try JSONEncoder().encode([space, foreign]).write(to: ProfileManager.spacesURL(for: space.profileID, in: manager.directory))
        await catalog.prepare(manager: manager, force: true)?.value
        XCTAssertEqual(catalog.spaces(manager: manager).map(\.id), [space.id])
    }
}
