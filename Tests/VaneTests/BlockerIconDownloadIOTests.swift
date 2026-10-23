import Darwin
import Foundation
import Combine
import XCTest
@testable import vane


/// Deliberately block a utility worker until the test observes a UI heartbeat. The
/// deadline only prevents a broken implementation from hanging the entire test runner.
private final class Task7WorkerGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "IO worker entered")
    private let condition = NSCondition()
    private var released = false
    private var enteredOnce = false
    private var timedOut = false
    private var running = 0
    private var maximumRunning = 0
    private var count = 0
    var usedFallback: Bool { condition.withLock { timedOut } }
    var calls: Int { condition.withLock { count } }
    var maxConcurrent: Int { condition.withLock { maximumRunning } }

    func block() {
        condition.lock()
        count += 1; running += 1; maximumRunning = max(maximumRunning, running)
        if !enteredOnce { enteredOnce = true; entered.fulfill() }
        let deadline = Date.now.addingTimeInterval(10)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; break }
        }
        running -= 1
        condition.unlock()
    }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}

private final class Task7ReplyGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "helper request entered")
    private let lock = NSLock()
    private var reply: (@Sendable (Bool) -> Void)?
    func receive(_ reply: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { self.reply = reply }
        entered.fulfill()
    }
    func finish(_ value: Bool) { lock.withLock { reply }?(value) }
}

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
        let sweepFinished = XCTestExpectation(description: "busy sweep returned")
        let createFinished = XCTestExpectation(description: "busy create returned")
        let sweep = Task.detached {
            defer { sweepFinished.fulfill() }
            do { try BlockerPrivateCache.sweep(root: root); return false } catch { return true }
        }
        let creation = Task {
            defer { createFinished.fulfill() }
            do {
                let cache = try await BlockerPrivateCache.create(root: root)
                cache.close(removeFiles: false)
                return false
            } catch { return true }
        }
        // The owner remains locked until both operations have demonstrably returned.
        // On regression, fulfillment fails first, then cleanup releases their wait.
        await fulfillment(of: [sweepFinished, createFinished], timeout: 5)
        flock(descriptor, LOCK_UN); Darwin.close(descriptor)
        let sweepRejected = await sweep.value
        let creationRejected = await creation.value
        XCTAssertTrue(sweepRejected)
        XCTAssertTrue(creationRejected)
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
        let file = root.appendingPathComponent("large-list.pipe")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let gate = Task7WorkerGate()
        let text = Data(String(repeating: "||fixture.example^\n", count: 50_000).utf8)
        let writer = Task {
            await withCheckedContinuation { continuation in
                // FIFO open/write deliberately blocks a real utility thread; do not
                // occupy Swift's cooperative task executor or replace the IO gate.
                DispatchQueue.global(qos: .utility).async {
                    let success: Bool = {
                        let deadline = Date.now.addingTimeInterval(10)
                        var descriptor: Int32 = -1
                        while descriptor < 0, Date.now < deadline {
                            descriptor = Darwin.open(file.path, O_WRONLY | O_NONBLOCK)
                            if descriptor < 0 { Thread.sleep(forTimeInterval: 0.01) }
                        }
                        guard descriptor >= 0 else { return false }
                        defer { Darwin.close(descriptor) }
                        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
                        gate.block()
                        return text.withUnsafeBytes { buffer in
                            var written = 0
                            while written < buffer.count {
                                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                                if count <= 0 { return false }
                                written += count
                            }
                            return true
                        }
                    }()
                    continuation.resume(returning: success)
                }
            }
        }
        let work = Task { try await Blocker.prepareImportedFile(file, sources: []) }
        await fulfillment(of: [gate.entered], timeout: 5)
        // Reader is waiting for the writer; actor activity is independent of file speed.
        var pulse = false
        await Task { @MainActor in pulse = true }.value
        XCTAssertTrue(pulse)
        gate.release()
        let result = try await work.value
        let wroteAll = await writer.value
        XCTAssertTrue(wroteAll)
        XCTAssertFalse(gate.usedFallback)
        XCTAssertEqual(result.1.rules, 50_000)
    }

    func testIconReplyYieldsActorAndAcceptsOnlyTheFirstCompletion() async {
        let gate = Task7ReplyGate()
        let task = Task { await AppIconPersistence.request(timeout: 10) { gate.receive($0) } }
        await fulfillment(of: [gate.entered], timeout: 5)
        var pulse = false
        await Task { @MainActor in pulse = true }.value
        XCTAssertTrue(pulse)
        gate.finish(true); gate.finish(false)
        let result = await task.value
        XCTAssertTrue(result)
        let timeout = await AppIconPersistence.request(timeout: 0.01) { finish in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { finish(true) }
        }
        XCTAssertFalse(timeout)
    }

    func testIconQueuePreservesSelectionOrderAndFlushesFinalFailure() async {
        let queue = AppIconPersistenceQueue()
        let gate = Task7ReplyGate()
        var order: [String] = []
        queue.enqueue {
            order.append("first-start")
            _ = await AppIconPersistence.request(timeout: 10) { gate.receive($0) }
            order.append("first-end")
            return true
        }
        queue.enqueue { order.append("second"); return false }
        await fulfillment(of: [gate.entered], timeout: 5)
        XCTAssertTrue(queue.pending)
        XCTAssertEqual(order, ["first-start"])
        gate.finish(true)
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
        let gate = Task7WorkerGate()
        let manager = Downloads(directory: root, sandboxed: true, destinationProbe: { request in
            gate.block()
            return .init(request: request, url: request.record.destination, readable: false)
        })
        let row = manager.add(.init(name: "file.bin", destination: root.appendingPathComponent("before"), state: "done"))
        manager.refreshMissing()
        await fulfillment(of: [gate.entered], timeout: 5)
        var pulse = false
        await Task { @MainActor in pulse = true }.value
        XCTAssertTrue(pulse)
        row.url = root.appendingPathComponent("new-destination")
        gate.release()
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
        XCTAssertFalse(gate.usedFallback)
    }

    private func pausedFixture(in root: URL, state: String = "paused") throws -> (Downloads.Record, URL, URL) {
        let file = root.appendingPathComponent("partial-\(UUID()).bin")
        try Data([1, 2, 3]).write(to: file)
        var record = Downloads.Record(name: file.lastPathComponent, destination: file,
            source: URL(string: "https://example.invalid/file"), received: 3,
            state: state, reason: "Paused", sourceMethod: "GET")
        record.resumeFile = "\(record.id).resume"
        let blobs = Downloads.resumeDir(for: ProfileManager.defaultID, in: root)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent(record.resumeFile!)
        let data = try PropertyListSerialization.data(fromPropertyList: ["fixture": "resume"], format: .binary, options: 0)
        try data.write(to: blob)
        return (record, file, blob)
    }

    func testProductionInitialInspectionCannotAuthorizeDestructiveRetry() async throws {
        let root = try scratch()
        let (record, partial, blob) = try pausedFixture(in: root)
        try JSONEncoder().encode([record]).write(to: Downloads.listURL(for: ProfileManager.defaultID, in: root))
        let suite = "vane.task7.download-eligibility.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let gate = Task7WorkerGate()
        defer { gate.release() }
        let manager = Downloads(directory: root, locationDefaults: defaults, destinationProbe: { request in
            gate.block()
            return Downloads.inspectDestination(request)
        })
        let row = try XCTUnwrap(manager.items.first)
        await fulfillment(of: [gate.entered], timeout: 5)
        XCTAssertFalse(manager.canResume(row), "Pending IO has not established resumability yet")
        XCTAssertFalse(manager.canRetry(row), "Pending IO is not a confirmed failure")
        XCTAssertFalse(manager.retry(row), "Retry must not delete a potentially valid partial/blob")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        let eligibilityPublished = XCTestExpectation(description: "inspection eligibility published")
        let observation = row.$inspectedDestination.dropFirst().sink { snapshot in
            if snapshot != nil { eligibilityPublished.fulfill() }
        }
        gate.release()
        await manager.waitForDestinationRefresh()
        await fulfillment(of: [eligibilityPublished], timeout: 5)
        XCTAssertEqual(row.status, .paused)
        XCTAssertTrue(manager.canResume(row))
        XCTAssertFalse(manager.canRetry(row))
        XCTAssertFalse(gate.usedFallback)
        withExtendedLifetime(observation) {}
    }

    func testOverlappingRefreshRerunsForNewlyPausedRowWithOnlyOneWorker() async throws {
        let root = try scratch()
        let (record, _, _) = try pausedFixture(in: root, state: "running")
        let gate = Task7WorkerGate()
        defer { gate.release() }
        let manager = Downloads(directory: root, sandboxed: true, destinationProbe: { request in
            gate.block()
            return Downloads.inspectDestination(request)
        })
        let complete = root.appendingPathComponent("complete.bin")
        try Data([7]).write(to: complete)
        manager.add(.init(name: "complete.bin", destination: complete, state: "done"))
        let transfer = manager.add(record)
        manager.refreshMissing()
        await fulfillment(of: [gate.entered], timeout: 5)
        transfer.status = .paused
        transfer.state = .failed("Paused")
        // Mirrors finish(_:error:resumeData:) requesting refresh while an older batch
        // contains only finished rows. Any number of overlap requests become one rerun.
        for _ in 0..<20 { manager.refreshMissing() }
        XCTAssertFalse(manager.canResume(transfer))
        XCTAssertFalse(manager.canRetry(transfer))
        gate.release()
        await manager.waitForDestinationRefresh()
        XCTAssertTrue(manager.canResume(transfer))
        XCTAssertFalse(manager.canRetry(transfer))
        XCTAssertEqual(gate.calls, 3, "First batch has one row; exactly one rerun has two")
        XCTAssertEqual(gate.maxConcurrent, 1)
        XCTAssertFalse(gate.usedFallback)
    }

    func testCancelledResumeRejectsLateDestinationResultAndAllowsRetry() async throws {
        let root = try scratch()
        let gate = Task7WorkerGate()
        let workerReturned = XCTestExpectation(description: "cancelled resume worker returned")
        defer { gate.release() }
        let manager = Downloads(directory: root, sandboxed: true, destinationProbe: { request in
            gate.block()
            workerReturned.fulfill()
            return .init(request: request, bookmark: request.record.destinationBookmark, unavailable: true)
        })
        let row = manager.add(.init(name: "partial.bin", destination: root.appendingPathComponent("partial.bin"),
            source: URL(string: "https://example.invalid/file"), state: "paused", sourceMethod: "GET"))
        XCTAssertTrue(manager.resume(row))
        await fulfillment(of: [gate.entered], timeout: 5)
        manager.cancel(row)
        gate.release()
        await fulfillment(of: [workerReturned], timeout: 5)
        await Task.yield()
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.state, .failed(Downloads.cancelledText))
        XCTAssertTrue(manager.canRetry(row), "Cancelled worker must release pending resume state")
        XCTAssertFalse(gate.usedFallback)
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
