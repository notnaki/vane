import Darwin
import Foundation
import XCTest
@testable import vane

@MainActor final class BlockerIconDownloadIOTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPrivateCacheBusyLockFailsImmediatelyInsteadOfWaitingForOwner() async throws {
        let root = try scratch()
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        // Also makes a regression terminate, rather than hanging the test runner.
        let released = Task.detached {
            try? await Task.sleep(for: .milliseconds(400))
            flock(descriptor, LOCK_UN); Darwin.close(descriptor)
        }
        let start = ContinuousClock.now
        do { try BlockerPrivateCache.sweep(root: root); XCTFail("Busy sweep must report unavailable") }
        catch { XCTAssertLessThan(start.duration(to: .now), .milliseconds(150)) }
        do { _ = try await BlockerPrivateCache.create(root: root); XCTFail("Busy cache must report unavailable") }
        catch { XCTAssertLessThan(start.duration(to: .now), .milliseconds(150)) }
        await released.value
        let cache = try await BlockerPrivateCache.create(root: root)
        cache.close(removeFiles: false)
        try await Task.detached { try BlockerPrivateCache.sweep(root: root) }.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
    }

    func testFilterAdmissionRejectsOversizedAndInvalidUTF8WithoutPartialAcceptance() throws {
        let root = try scratch()
        let file = root.appendingPathComponent("filters.txt")
        try Data(repeating: 65, count: BlockerFiles.sourceByteLimit + 1).write(to: file)
        XCTAssertThrowsError(try BlockerFiles.readText(file))
        XCTAssertThrowsError(try BlockerFiles.sourceTexts(builtin: "||valid.example^", files: [file]))
        try Data([0xff]).write(to: file)
        XCTAssertThrowsError(try BlockerFiles.readText(file))
        try Data("||valid.example^\n@@||allowed.example^".utf8).write(to: file)
        XCTAssertEqual(try Blocker.convertBoundedSources([BlockerFiles.readText(file)]).rules, 2)
        XCTAssertThrowsError(try Blocker.convertBoundedSources([String(repeating: "x", count: 65 * 1024)]))
    }

    func testLargeFilterConversionLeavesMainActorFree() async throws {
        let root = try scratch()
        let file = root.appendingPathComponent("large.txt")
        let text = String(repeating: "||fixture.example^\n", count: 50_000)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let start = ContinuousClock.now
        let work = Task { try await Blocker.prepareImportedFile(file, sources: []) }
        var pulse = false
        let actor = Task { @MainActor in pulse = true }
        await actor.value
        XCTAssertTrue(pulse)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let result = try await work.value
        XCTAssertEqual(result.1.rules, 50_000)
    }

    func testIconReplyYieldsActorAndAcceptsOnlyTheFirstCompletion() async {
        let task = Task {
            await AppIconPersistence.request(timeout: 2) { finish in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { finish(true); finish(false) }
            }
        }
        let start = ContinuousClock.now
        await Task.yield()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        let result = await task.value
        XCTAssertTrue(result)
        let timeout = await AppIconPersistence.request(timeout: 0.01) { finish in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { finish(true) }
        }
        XCTAssertFalse(timeout)
    }

    func testIconQueuePreservesSelectionOrderAndFlushesFinalFailure() async {
        let queue = AppIconPersistenceQueue()
        var order: [String] = []
        queue.enqueue {
            order.append("first-start")
            try? await Task.sleep(for: .milliseconds(30))
            order.append("first-end")
            return true
        }
        queue.enqueue { order.append("second"); return false }
        XCTAssertTrue(queue.pending)
        let success = await queue.flush()
        XCTAssertFalse(success)
        XCTAssertFalse(queue.pending)
        XCTAssertEqual(order, ["first-start", "first-end", "second"])
        queue.enqueue { true }
        let retried = await queue.flush()
        XCTAssertTrue(retried)
    }

    func testLaterIconFlushRetriesAFailedFinalStamp() async {
        let queue = AppIconPersistenceQueue()
        var attempts = 0
        queue.enqueue { attempts += 1; return attempts > 1 }
        let failed = await queue.flush()
        XCTAssertFalse(failed)
        let recovered = await queue.flush()
        XCTAssertTrue(recovered)
        XCTAssertEqual(attempts, 2)
    }

    func testDownloadRefreshReturnsImmediatelyAndRejectsChangedOrForgottenRows() async throws {
        let root = try scratch()
        let manager = Downloads(directory: root, sandboxed: true, destinationProbe: { request in
            Thread.sleep(forTimeInterval: 0.15)
            return .init(request: request, url: request.record.destination, readable: false)
        })
        let row = manager.add(.init(name: "file.bin", destination: root.appendingPathComponent("before"), state: "done"))
        let start = ContinuousClock.now
        manager.refreshMissing()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        row.url = root.appendingPathComponent("new-destination")
        await manager.waitForDestinationRefresh()
        XCTAssertEqual(row.status, .done, "Late failure cannot overwrite an edited destination")
        manager.refreshMissing()
        manager.forget(row)
        await manager.waitForDestinationRefresh()
        XCTAssertTrue(manager.items.isEmpty, "Late result cannot resurrect a forgotten row")
        let current = manager.add(.init(name: "current.bin", destination: root.appendingPathComponent("gone"), state: "done"))
        manager.refreshMissing()
        await manager.waitForDestinationRefresh()
        XCTAssertEqual(current.status, .missing)
    }

    func testCancelledResumeRejectsLateDestinationResultAndAllowsRetry() async throws {
        let root = try scratch()
        let manager = Downloads(directory: root, sandboxed: true, destinationProbe: { request in
            Thread.sleep(forTimeInterval: 0.1)
            return .init(request: request, bookmark: request.record.destinationBookmark, unavailable: true)
        })
        let row = manager.add(.init(name: "partial.bin", destination: root.appendingPathComponent("partial.bin"),
            source: URL(string: "https://example.invalid/file"), state: "paused", sourceMethod: "GET"))
        XCTAssertTrue(manager.resume(row))
        manager.cancel(row)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.state, .failed(Downloads.cancelledText))
        XCTAssertTrue(manager.canRetry(row), "Cancelled worker must release pending resume state")
    }

    func testUnavailableDownloadKeepsGrantAndResumeDataForReconnection() async throws {
        let root = try scratch()
        let file = root.appendingPathComponent("partial.bin")
        try Data([1, 2, 3]).write(to: file)
        var record = Downloads.Record(name: "partial.bin", destination: file, received: 3, state: "paused")
        record.destinationBookmark = try root.bookmarkData()
        record.resumeFile = "\(record.id).resume"
        let blobs = Downloads.resumeDir(for: ProfileManager.defaultID, in: root)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent(record.resumeFile!)
        try Data("bplist00-synthetic".utf8).write(to: blob)
        let manager = Downloads(directory: root, sandboxed: true, destinationProbe: { request in
            .init(request: request, bookmark: request.record.destinationBookmark, unavailable: true)
        })
        let row = manager.add(record)
        manager.refreshMissing()
        await manager.waitForDestinationRefresh()
        XCTAssertEqual(row.status, .paused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        let saved = try JSONDecoder().decode([Downloads.Record].self,
            from: Data(contentsOf: Downloads.listURL(for: ProfileManager.defaultID, in: root)))
        XCTAssertEqual(saved.first?.destinationBookmark, record.destinationBookmark)
        XCTAssertEqual(saved.first?.resumeFile, record.resumeFile)
    }
}
