import XCTest
@testable import vane

@MainActor final class ReadingQueueProfileCleanupResponsivenessTests: XCTestCase {
    func testBlockedRecursiveDeletionLeavesProfileNamespaceFreeAndReplacementUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ProfileManager.defaultID, neighbor = UUID()
        let store = try ReadingQueueStore.shared(profileID: profile, directory: directory)
        _ = try await store.publish(.init(article: makeReadingArticle(), images: [:]))
        let neighborRoot = ReadingQueueFiles.profileURL(neighbor, in: directory)
        try FileManager.default.createDirectory(at: neighborRoot, withIntermediateDirectories: true)
        let sentinel = neighborRoot.appendingPathComponent("keep")
        try Data("neighbor".utf8).write(to: sentinel)
        let gate = EaselWorkerGate("cleanup")
        try ReadingQueueStore.forget(profileID: profile, directory: directory, cleanup: { url in
            gate.inspect("cleanup")
            try FileManager.default.removeItem(at: url)
        })
        await gate.waitForEntry()
        XCTAssertTrue(store.invalidated)
        XCTAssertFalse(ReadingQueueFiles.exists(ReadingQueueFiles.profileURL(profile, in: directory)))
        XCTAssertFalse(gate.ranOnMain)
        // The UI can create a new queue while recursive deletion is still blocked.
        let replacement = try ReadingQueueStore.shared(profileID: profile, directory: directory)
        _ = try await replacement.publish(.init(article: makeReadingArticle(), images: [:]))
        gate.resume(); await ReadingQueueStore.waitForProfileCleanup()
        XCTAssertEqual(replacement.articles.count, 1)
        XCTAssertTrue(ReadingQueueFiles.exists(ReadingQueueFiles.profileURL(profile, in: directory)))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("neighbor".utf8))
        try ReadingQueueStore.forget(profileID: profile, directory: directory)
        await ReadingQueueStore.waitForProfileCleanup()
    }
    func testFailedProfileCleanupIsRetriedByNextBackgroundScan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ProfileManager.defaultID
        let store = try ReadingQueueStore.shared(profileID: profile, directory: directory)
        _ = try await store.publish(.init(article: makeReadingArticle(), images: [:]))
        try ReadingQueueStore.forget(profileID: profile, directory: directory, cleanup: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        })
        await ReadingQueueStore.waitForProfileCleanup()
        let staging = ReadingQueueFiles.root(in: directory).appendingPathComponent(".staging")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).contains { $0.hasPrefix(".deleted-") })
        let replacement = try ReadingQueueStore.shared(profileID: profile, directory: directory)
        await replacement.waitUntilReady()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: staging.path).contains { $0.hasPrefix(".deleted-") })
        XCTAssertTrue(replacement.articles.isEmpty); XCTAssertNil(replacement.error)
        try ReadingQueueStore.forget(profileID: profile, directory: directory)
        await ReadingQueueStore.waitForProfileCleanup()
    }

}
