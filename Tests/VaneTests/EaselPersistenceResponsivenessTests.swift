import XCTest
@testable import vane

final class EaselWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var events: [String] = []
    private var mainThreadWork = false
    private let stage: String
    init(_ stage: String) { self.stage = stage }
    func inspect(_ event: String) {
        let shouldWait = lock.withLock {
            events.append(event); mainThreadWork = mainThreadWork || Thread.isMainThread
            guard event == stage, !entered else { return false }
            entered = true; continuation?.resume(); continuation = nil
            return true
        }
        if shouldWait { release.wait() }
    }
    func waitForEntry() async {
        await withCheckedContinuation { waiting in
            lock.withLock { if entered { waiting.resume() } else { continuation = waiting } }
        }
    }
    func resume() { release.signal() }
    var ranOnMain: Bool { lock.withLock { mainThreadWork } }
    var recorded: [String] { lock.withLock { events } }
}

@MainActor final class EaselPersistenceResponsivenessTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testQueuedItemEditsKeepChangesToOtherFields() {
        let original = EaselItem(kind: .note, text: "Original", x: 100)
        var editor = original; editor.text = "Edited"
        var moved = original; moved.x = 250
        let merged = EaselItemLayout.merging(editor, from: original, into: moved)
        XCTAssertEqual(merged.text, "Edited"); XCTAssertEqual(merged.x, 250)
        XCTAssertEqual(merged.id, original.id)
    }
    func testBlockedArchiveLoadLeavesMainActorAvailableAndPreservesOriginal() async throws {
        let directory = try root(), profile = UUID()
        let board = EaselBoard(title: "Existing", items: [EaselItem(kind: .drawing,
            points: Array(repeating: .init(x: 1, y: 1), count: 5000))])
        let bytes = try JSONEncoder().encode(EaselStore.Archive(boards: [board]))
        let file = EaselStore.file(profileID: profile, directory: directory)
        try bytes.write(to: file)
        let gate = EaselWorkerGate("load")
        let store = EaselStore(profileID: profile, directory: directory, background: true, inspection: gate.inspect)
        await gate.waitForEntry()
        XCTAssertTrue(store.loading); XCTAssertTrue(store.boards.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(gate.ranOnMain)
        gate.resume(); await store.waitUntilReady()
        XCTAssertEqual(store.boards, [board]); XCTAssertFalse(store.loading)
    }
    func testPendingCancelledSaveStaysOrderedAndFlushIncludesDurableUndo() async throws {
        let directory = try root(), profile = UUID(), gate = EaselWorkerGate("save")
        let board = EaselBoard(title: "Original")
        try JSONEncoder().encode(EaselStore.Archive(boards: [board])).write(to: EaselStore.file(profileID: profile, directory: directory))
        let store = EaselStore(profileID: profile, directory: directory, background: true, inspection: gate.inspect)
        await store.waitUntilReady()
        var changed = board; changed.title = "First"
        let firstBoard = changed
        let first = Task { try await store.saveAsync(firstBoard) }
        await gate.waitForEntry()
        XCTAssertEqual(store.board(board.id)?.title, "Original"); XCTAssertFalse(store.canUndo(board.id))
        first.cancel()
        changed.title = "Second"; let secondBoard = changed
        let second = Task { try await store.saveAsync(secondBoard) }
        gate.resume()
        try await first.value; try await second.value; try await store.flush()
        XCTAssertEqual(store.board(board.id)?.title, "Second"); XCTAssertTrue(store.canUndo(board.id))
        try await store.undoAsync(board.id)
        XCTAssertEqual(store.board(board.id)?.title, "First")
        let disk = EaselStore(profileID: profile, directory: directory)
        XCTAssertEqual(disk.boards, store.boards); XCTAssertFalse(gate.ranOnMain)
    }
    func testFailedBackgroundUndoRetainsContentAndBothUndoStacks() async throws {
        let store = EaselStore(profileID: UUID(), directory: try root(), background: true)
        let board = try await store.createAsync(title: "Original")
        var changed = board; changed.title = "Saved"
        try await store.saveAsync(changed)
        try FileManager.default.removeItem(at: store.directory)
        try Data().write(to: store.directory)
        do { try await store.undoAsync(board.id); XCTFail("Failed undo unexpectedly succeeded") } catch {}
        XCTAssertEqual(store.board(board.id)?.title, "Saved")
        XCTAssertTrue(store.canUndo(board.id)); XCTAssertFalse(store.canRedo(board.id)); XCTAssertNotNil(store.error)
        do { try await store.flush(); XCTFail("Flush hid the save failure") } catch {}
        try FileManager.default.removeItem(at: store.directory)
        try await store.undoAsync(board.id)
        XCTAssertEqual(store.board(board.id)?.title, "Original"); XCTAssertNil(store.error)
        XCTAssertFalse(store.canUndo(board.id)); XCTAssertTrue(store.canRedo(board.id))
    }
    func testLargeLibraryEditValidatesAndEncodesOnlyTheChangedBoard() async throws {
        let directory = try root(), profile = UUID(), gate = EaselWorkerGate("unused")
        let points = Array(repeating: EaselPoint(x: 1, y: 1), count: 1000)
        let boards = (0..<4).map { index in
            EaselBoard(title: "Board \(index)", items: (0..<256).map { _ in EaselItem(kind: .drawing, points: points) })
        }
        let file = EaselStore.file(profileID: profile, directory: directory)
        try JSONEncoder().encode(EaselStore.Archive(boards: boards)).write(to: file)
        let store = EaselStore(profileID: profile, directory: directory, background: true, inspection: gate.inspect)
        await store.waitUntilReady()
        var changed = boards[0]; changed.items[0].x += 1
        try await store.saveAsync(changed)
        XCTAssertEqual(gate.recorded.filter { $0.hasPrefix("validate:") }, ["validate:" + changed.id.uuidString])
        XCTAssertEqual(gate.recorded.filter { $0.hasPrefix("encode:") }, ["encode:" + changed.id.uuidString])
        XCTAssertFalse(gate.ranOnMain)
        let reopened = EaselStore(profileID: profile, directory: directory)
        XCTAssertEqual(reopened.boards, store.boards)
    }
    func testRetiredPendingWriteCannotResurrectOrDeleteReplacementRepository() async throws {
        let directory = try root(), profile = UUID(), gate = EaselWorkerGate("save")
        let store = EaselStore.shared(profileID: profile, directory: directory, inspection: gate.inspect)
        await store.waitUntilReady()
        let pending = Task { try await store.createAsync(title: "Retired") }
        await gate.waitForEntry()
        EaselStore.forget(profile, directory: directory)
        let replacement = EaselStore.shared(profileID: profile, directory: directory)
        let created = Task { try await replacement.createAsync(title: "Replacement") }
        gate.resume()
        do { _ = try await pending.value; XCTFail("Retired store published its pending board") } catch {}
        let board = try await created.value
        try await replacement.flush()
        XCTAssertTrue(store.boards.isEmpty)
        XCTAssertEqual(replacement.boards.map(\.id), [board.id])
        XCTAssertEqual(EaselStore(profileID: profile, directory: directory).boards, replacement.boards)
        EaselStore.forget(profile, directory: directory)
        await EaselStore.waitForRetirement(profileID: profile, directory: directory)
    }
    func testExitBarrierRejectsNewIntentsAndDrainsPreviouslyAcceptedSessionEdits() async throws {
        TestEnvironment.prepare()
        let directory = try root(), profile = UUID(), gate = EaselWorkerGate("save")
        let board = EaselBoard(title: "Original")
        try JSONEncoder().encode(EaselStore.Archive(boards: [board])).write(to: EaselStore.file(profileID: profile, directory: directory))
        let store = EaselStore.shared(profileID: profile, directory: directory, inspection: gate.inspect)
        await store.waitUntilReady()
        let session = EaselSession(store); session.selected = board.id
        XCTAssertTrue(session.edit { $0.title = "First accepted" })
        XCTAssertTrue(session.edit { $0.title = "Second accepted" })
        await gate.waitForEntry()
        XCTAssertTrue(AppLifecycle.shared.beginPersistenceExit())
        defer { AppLifecycle.shared.endPersistenceExit() }
        XCTAssertFalse(session.edit { $0.title = "Rejected" })
        do { _ = try await store.createAsync(); XCTFail("Exit barrier admitted a new write") } catch {}
        gate.resume()
        try await EaselStore.drainAllPendingWrites(directory: directory)
        XCTAssertEqual(store.board(board.id)?.title, "Second accepted")
        XCTAssertEqual(EaselStore(profileID: profile, directory: directory).boards, store.boards)
        EaselStore.forget(profile, directory: directory)
        await EaselStore.waitForRetirement(profileID: profile, directory: directory)
    }

}
