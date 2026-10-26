import XCTest
@testable import vane

/// Blocks the first real file snapshot after decoding, so a newer request can
/// complete first without relying on arbitrary sleeps or changing persistence.
private final class PaletteCatalogReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var count = 0
    private var mainThread = false

    var calls: Int { lock.withLock { count } }
    var ranOnMain: Bool { lock.withLock { mainThread } }

    func load(directory: URL, profiles: [UUID]) -> [Space] {
        let snapshot = PaletteSpaceCatalog.read(directory: directory, profiles: profiles)
        let first = lock.withLock {
            count += 1
            mainThread = mainThread || Thread.isMainThread
            guard count == 1 else { return false }
            entered = true
            entry?.resume(); entry = nil
            return true
        }
        // A regression to the main thread must fail an assertion, not deadlock it.
        if first && !Thread.isMainThread { release.wait() }
        return snapshot
    }

    func waitForEntry() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if entered { continuation.resume() }
                else { entry = continuation }
            }
        }
    }
    func resume() { release.signal() }
}

@MainActor final class PaletteSpaceCatalogTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-palette-spaces-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProfileManager(directory: root, sandboxed: true)
    }

    func testBlockedSavedMetadataLoadingLeavesMainActorAvailableAndCoalescesQueries() async throws {
        let manager = try manager()
        let home = manager.createSpace(name: "Home", in: manager.active.id)
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let first = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        XCTAssertFalse(gate.ranOnMain, "Metadata reads and JSON decoding must run on a worker")
        for query in ["h", "ho", "hom", "home"] {
            catalog.prepare(manager: manager)
            XCTAssertTrue(Palette.rank(query, catalog.strip(manager: manager), key: \.name).isEmpty)
        }
        XCTAssertEqual(gate.calls, 1, "Keystrokes must coalesce the same pending metadata request")
        gate.resume()
        await first?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home])
        XCTAssertEqual(catalog.generation, 1)
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(gate.calls, 1, "Ready metadata must be reused until its revision changes")
    }

    func testSuccessiveQueriesReuseMetadataAndSavedChangesRefreshIt() async throws {
        let manager = try manager()
        var docs = manager.createSpace(name: "Documents", in: manager.active.id)
        let catalog = PaletteSpaceCatalog()
        await catalog.prepare(manager: manager)?.value
        for query in ["d", "do", "doc", "documents"] {
            let matches = Palette.rank(query, catalog.strip(manager: manager), key: \.name)
            XCTAssertTrue(matches.contains { $0.id == docs.id })
        }
        XCTAssertEqual(catalog.generation, 1)
        docs.name = "Live Documents"
        XCTAssertTrue(manager.updateSpace(docs))
        XCTAssertTrue(catalog.strip(manager: manager).isEmpty, "A stale revision must not render")
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager).first { $0.id == docs.id }?.name, docs.name)
        let extra = manager.createSpace(name: "New Space", in: manager.active.id)
        await catalog.prepare(manager: manager)?.value
        XCTAssertTrue(catalog.strip(manager: manager).contains { $0.id == extra.id })
        XCTAssertTrue(manager.deleteSpace(docs.id, in: manager.active.id))
        await catalog.prepare(manager: manager)?.value
        XCTAssertFalse(catalog.strip(manager: manager).contains { $0.id == docs.id })
        XCTAssertEqual(catalog.generation, 4)
    }

    func testUnsavedPreviewAndOwnProfileFilterStayLiveWithoutReloading() async throws {
        let manager = try manager()
        let first = manager.active
        let home = manager.createSpace(name: "Home", in: first.id)
        let other = manager.create(name: "Other")
        let work = manager.createSpace(name: "Work", in: other.id)
        let catalog = PaletteSpaceCatalog()
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager).map(\.id), [home.id, work.id])
        var preview = home
        preview.name = "Unsaved name"
        XCTAssertEqual(catalog.spaces(for: first.id, manager: manager, preview: preview), [preview])
        XCTAssertEqual(catalog.spaces(for: other.id, manager: manager, preview: preview), [work])
        XCTAssertEqual(catalog.strip(manager: manager).first?.name, "Home", "Preview must not replace saved metadata")
        XCTAssertEqual(manager.spaces(for: first.id), [home], "A preview must not persist")
        var foreignPreview = preview; foreignPreview.profileID = other.id
        XCTAssertEqual(catalog.strip(manager: manager, preview: foreignPreview).first, home)
        let empty = manager.create(name: "Empty")
        XCTAssertTrue(catalog.strip(manager: manager).isEmpty)
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager).map(\.id), [home.id, work.id])
        XCTAssertTrue(manager.delete(empty.id))
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.generation, 3)
    }

    func testNewRevisionWinsWhenOldWorkerCompletesLast() async throws {
        let manager = try manager()
        var home = manager.createSpace(name: "Old", in: manager.active.id)
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        home.name = "Current"
        XCTAssertTrue(manager.updateSpace(home))
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home])
        gate.resume()
        await old?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home], "A late older revision must never overwrite current rows")
        XCTAssertEqual(catalog.generation, 1)
    }

    func testRevisionChangeWithoutAnotherRequestRejectsPendingResult() async throws {
        let manager = try manager()
        var home = manager.createSpace(name: "Old", in: manager.active.id)
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        home.name = "Current"
        XCTAssertTrue(manager.updateSpace(home))
        gate.resume()
        await old?.value
        XCTAssertTrue(catalog.strip(manager: manager).isEmpty)
        XCTAssertEqual(catalog.generation, 0, "A revision changed during decoding must not publish")
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home])
    }

    func testDismissalRejectsLateResultAndReopenStartsFreshRequest() async throws {
        let manager = try manager()
        let home = manager.createSpace(name: "Home", in: manager.active.id)
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        catalog.cancel()
        gate.resume()
        await old?.value
        XCTAssertTrue(catalog.strip(manager: manager).isEmpty)
        XCTAssertEqual(catalog.generation, 0, "A dismissed palette must not receive a late update")
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home])
        XCTAssertEqual(gate.calls, 2)
    }

    func testRejectedRequestDoesNotBlockReloadWhenProfileListReturnsToItsOriginalKey() async throws {
        let manager = try manager()
        let home = manager.createSpace(name: "Home", in: manager.active.id)
        let revision = manager.spacesRevision
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        let temporary = manager.create(name: "Temporary")
        gate.resume()
        await old?.value
        XCTAssertEqual(catalog.generation, 0, "The changed profile list must reject the old result")
        XCTAssertTrue(manager.delete(temporary.id))
        XCTAssertEqual(manager.spacesRevision, revision)
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home],
                       "A rejected completed request must not suppress a fresh read of the same key")
        XCTAssertEqual(gate.calls, 2)
    }

    func testASecondManagerCannotReuseOrBeOverwrittenByAnotherManagersSnapshot() async throws {
        let first = try manager(), second = try manager()
        _ = first.createSpace(name: "One", in: first.active.id)
        let two = second.createSpace(name: "Two", in: second.active.id)
        XCTAssertEqual(first.profiles.map(\.id), second.profiles.map(\.id))
        XCTAssertEqual(first.spacesRevision, second.spacesRevision)
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: first)
        await gate.waitForEntry()
        await catalog.prepare(manager: second)?.value
        gate.resume()
        await old?.value
        XCTAssertEqual(catalog.strip(manager: second), [two])
        XCTAssertTrue(catalog.strip(manager: first).isEmpty)
        XCTAssertEqual(catalog.generation, 1)
    }

    func testProfileListChangeRejectsOldSnapshotAndReaderFiltersForeignEntries() async throws {
        let manager = try manager()
        let first = manager.active
        let home = manager.createSpace(name: "Home", in: first.id)
        let gate = PaletteCatalogReadGate()
        defer { gate.resume() }
        let catalog = PaletteSpaceCatalog(load: gate.load)
        let old = catalog.prepare(manager: manager)
        await gate.waitForEntry()
        let other = manager.create(name: "Other")
        let work = manager.createSpace(name: "Work", in: other.id)
        // Malformed ownership in one file must not leak into another profile's results.
        try JSONEncoder().encode([home, work]).write(to: ProfileManager.spacesURL(for: first.id, in: manager.directory))
        await catalog.prepare(manager: manager)?.value
        gate.resume()
        await old?.value
        XCTAssertEqual(catalog.strip(manager: manager), [home, work])
        XCTAssertEqual(catalog.spaces(for: first.id, manager: manager), [home])
        XCTAssertEqual(catalog.spaces(for: other.id, manager: manager), [work])
        XCTAssertEqual(catalog.generation, 1)
    }
}
