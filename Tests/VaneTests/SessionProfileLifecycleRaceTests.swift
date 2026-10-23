import Foundation
import AppKit
import XCTest
@testable import vane

private final class SessionLifecycleFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func read() -> Bool { lock.withLock { value } }
}

@MainActor final class SessionProfileLifecycleRaceTests: XCTestCase {
    func testNewProfileLoadDoesNotWaitBehindUnrelatedWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ProfileManager(directory: directory, sandboxed: true)
        let entered = expectation(description: "unrelated writer entered")
        let release = DispatchSemaphore(value: 0), watchdogReleased = SessionLifecycleFlag()
        let marker = directory.appendingPathComponent("unrelated")
        SessionPersistence.shared.enqueue(file: marker) { entered.fulfill(); release.wait(); return true }
        await fulfillment(of: [entered], timeout: 2)
        // Watchdog only prevents a regressed synchronous load from hanging the suite.
        // The assertion is whether that watchdog had to unblock the unrelated worker.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            watchdogReleased.set(); release.signal()
        }
        let created = manager.create(name: "New profile")
        let loaded = Suspension.SpaceState.load(space: UUID(), profileID: created.id, in: directory)
        let blocked = watchdogReleased.read()
        release.signal()
        let flushed = await SessionPersistence.shared.flush()
        XCTAssertTrue(flushed)
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(blocked, "A known-empty profile must not join another profile’s disk queue")
    }

    func testSessionCaptureSkipsRetiredProfileWhoseWindowRemainsOpen() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), space = Space(name: "Retire visible profile", profileID: UUID())
        var owned = space; owned.profileID = profile
        XCTAssertTrue(ProfileManager.shared.saveSpaces([owned], for: profile))
        Suspension.SpaceState.registerNewProfile(profileID: profile, in: Store.directory)
        let store = TabStore(profileID: profile, space: owned, session: [])
        addTeardownBlock { @MainActor in
            store.dropStashes(); SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }; Store.forget(profile)
        }
        let tab = store.newBlankTab(focus: false, as: .today)
        tab.restore(url: URL(string: "https://retired-visible.example/")!, home: nil, parked: Parked(title: "Retire"))
        XCTAssertTrue(Session.enqueueSave())
        let initial = await Session.flushPersistence()
        XCTAssertTrue(initial)
        await Suspension.SpaceState.retire(profileID: profile, in: Store.directory)
        RecoverySnapshots.forget(profileID: profile, in: Store.directory)
        XCTAssertTrue(TabStore.all.contains { $0 === store })
        XCTAssertTrue(Session.enqueueSave(), "An intentionally retained window must not poison global persistence")
        let flushed = await Session.flushPersistence()
        XCTAssertTrue(flushed)
        for file in [ProfileManager.sessionURL(for: profile, in: Store.directory),
                     ProfileManager.spacesURL(for: profile, in: Store.directory),
                     Suspension.SpaceState.url(for: profile, in: Store.directory)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testRetirementDrainsActiveWriterAndRejectsQueuedWritesAndFailureRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json"), lane = SessionPersistence()
        let entered = expectation(description: "old writer entered"), release = DispatchSemaphore(value: 0)
        let retired = SessionLifecycleFlag()
        lane.enqueue(file: file) {
            entered.fulfill(); release.wait()
            _ = SnapshotPersistence.write(Data("old completed generation".utf8), to: file)
            return false // A rejected operation would otherwise remain eligible for retry.
        }
        await fulfillment(of: [entered], timeout: 2)
        let retirement = Task { await lane.retire(files: [file]); retired.set() }
        // Probe real admission until the retirement task has closed it.
        while lane.enqueue(file: file, { SnapshotPersistence.write(Data("queued".utf8), to: file) }) {
            await Task.yield()
        }
        XCTAssertFalse(retired.read(), "Deletion must wait for the writer already executing")
        release.signal()
        await retirement.value
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(lane.enqueue(file: file) { SnapshotPersistence.write(Data("future".utf8), to: file) })
        let drained = await lane.flush()
        XCTAssertTrue(drained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
