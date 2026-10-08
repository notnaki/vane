import XCTest
@testable import vane

@MainActor final class BlockerSubscriptionTests: XCTestCase {
    func testDueScheduleUsesAttemptsForBackoffAndSuccessForDailyInterval() {
        let now = Date(timeIntervalSince1970: 100_000)
        var item = FilterSubscription(url: URL(string: "https://lists.example/filter.txt")!)
        XCTAssertTrue(item.isDue(at: now))
        item.lastAttempt = now
        item.lastError = "Offline"
        XCTAssertFalse(item.isDue(at: now.addingTimeInterval(3599)))
        XCTAssertTrue(item.isDue(at: now.addingTimeInterval(3600)))
        item.lastSuccess = now; item.lastError = nil
        XCTAssertFalse(item.isDue(at: now.addingTimeInterval(86399)))
        XCTAssertTrue(item.isDue(at: now.addingTimeInterval(86400)))
    }

    func testFailedUpdatesRetainSourceValidatorsAndPersistFailureStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let manager = FilterSubscriptions(directory: directory, fetch: { item in
            calls += 1
            if calls == 1 { return .init(status: 200, text: "||working.example^", etag: "one") }
            XCTAssertEqual(item.etag, "one")
            return .init(status: 200, text: "||replacement.example^")
        }, validate: { text in
            if text.contains("replacement") { throw BlockerFiles.Failure("Compile failed") }
        })
        try await manager.add(URL(string: "https://lists.example/filter.txt")!)
        let id = try XCTUnwrap(manager.items.first?.id)
        await manager.update(id)
        XCTAssertEqual(manager.items[0].text, "||working.example^")
        XCTAssertEqual(manager.items[0].etag, "one")
        XCTAssertNotNil(manager.items[0].lastError)
        XCTAssertEqual(try FilterSubscriptions.read(directory: directory).first?.text, "||working.example^")
    }

    func testNotModifiedRequiresAcceptedSourceAndRetainsDiagnostics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FilterSubscriptions(directory: directory, fetch: { _ in .init(status: 304) }, validate: { _ in })
        try await manager.add(URL(string: "https://lists.example/filter.txt")!)
        XCTAssertTrue(manager.items[0].text.isEmpty)
        XCTAssertNotNil(manager.items[0].lastError)
        XCTAssertNil(manager.items[0].lastSuccess)
    }

    func testHTMLOrEmptyDownloadNeverReplacesAcceptedSource() async throws {
        for text in ["<!doctype html><html>error</html>", "! empty list", "/regex/"] {
            XCTAssertThrowsError(try FilterSubscriptions.usableText(.init(status: 200, text: text)))
        }
    }

    func testInvalidURLsAndDuplicateSubscriptionsAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FilterSubscriptions(directory: directory, fetch: { _ in .init(status: 200, text: "||ads.example^") }, validate: { _ in })
        for value in ["file:///tmp/list.txt", "https://user:pass@lists.example/filter", "http://lists.example/filter"] {
            do { try await manager.add(URL(string: value)!); XCTFail(value) } catch { }
        }
        let url = URL(string: "https://lists.example/filter")!
        try await manager.add(url)
        do { try await manager.add(url); XCTFail("duplicate") } catch { }
        XCTAssertEqual(manager.items.count, 1)
    }

    func testPersistenceFailureLeavesAcceptedStateIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fail = false
        let manager = FilterSubscriptions(directory: directory, fetch: { _ in .init(status: 200, text: "||ads.example^") }, validate: { _ in }, persist: { items in
            if fail { throw BlockerFiles.Failure("Disk full") }
            try FilterSubscriptions.write(items, directory: directory)
        })
        try await manager.add(URL(string: "https://lists.example/filter")!)
        let before = manager.items
        fail = true
        await manager.update(before[0].id)
        XCTAssertEqual(manager.items[0].text, before[0].text)
        XCTAssertEqual(manager.items[0].lastSuccess, before[0].lastSuccess)
        XCTAssertNotNil(manager.storageError)
        XCTAssertEqual(try FilterSubscriptions.read(directory: directory), before)
    }
}

extension BlockerSubscriptionTests {
    func testRemovalIsValidatedBeforeChangingSavedSources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reject = false
        let manager = FilterSubscriptions(directory: directory, fetch: { _ in .init(status: 200, text: "||ads.example^") }, validate: { _ in
            if reject { throw BlockerFiles.Failure("Remaining sources fail compilation") }
        })
        try await manager.add(URL(string: "https://lists.example/filter")!)
        let before = manager.items
        reject = true
        await manager.remove(before[0].id)
        XCTAssertEqual(manager.items, before)
        XCTAssertEqual(try FilterSubscriptions.read(directory: directory), before)
        XCTAssertNotNil(manager.storageError)
    }

    func testNotModifiedPreservesAcceptedTextAndReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let manager = FilterSubscriptions(directory: directory, fetch: { _ in
            calls += 1
            return calls == 1 ? .init(status: 200, text: "||ads.example^\n/regex/", etag: "tag") : .init(status: 304)
        }, validate: { _ in })
        try await manager.add(URL(string: "https://lists.example/filter")!)
        let before = manager.items[0]
        await manager.update(before.id)
        XCTAssertEqual(manager.items[0].text, before.text)
        XCTAssertEqual(manager.items[0].report, before.report)
        XCTAssertEqual(manager.items[0].etag, before.etag)
        XCTAssertNil(manager.items[0].lastError)
    }

    func testCorruptStoreCannotBeOverwrittenByAddingOrRemoving() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("subscriptions.json")
        try Data("broken".utf8).write(to: file)
        let manager = FilterSubscriptions(directory: directory, fetch: { _ in XCTFail("must not fetch"); return .init(status: 200) }, validate: { _ in })
        do { try await manager.add(URL(string: "https://lists.example/filter")!); XCTFail("must fail") } catch { }
        await manager.remove(UUID())
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
}

extension BlockerSubscriptionTests {
    func testRequestsOnlyUseValidatorsForAcceptedSource() {
        var item = FilterSubscription(url: URL(string: "https://lists.example/filter")!)
        item.etag = "tag"; item.lastModified = "yesterday"
        XCTAssertNil(FilterSubscriptions.request(for: item).value(forHTTPHeaderField: "If-None-Match"))
        item.text = "||accepted.example^"
        let request = FilterSubscriptions.request(for: item)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "tag")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), "yesterday")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }
}
