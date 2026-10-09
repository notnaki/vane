import Combine
import XCTest
@testable import vane

@MainActor final class ReadingQueueCollectionTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reading-library-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }

    func testAggregatesProfilesAndKeepsCollidingArticleIdentitiesSeparate() async throws {
        let manager = try manager()
        let first = manager.profiles[0], second = manager.create(name: "Work")
        let collection = ReadingQueueCollection(manager: manager) {
            try ReadingQueueStore(profileID: $0, directory: manager.directory)
        }
        var a = makeReadingArticle(profileID: first.id), b = makeReadingArticle(profileID: second.id)
        b.id = a.id; b.capturedAt = a.capturedAt; b.isRead = true
        a.sourceURL = "https://example.com/personal"; b.sourceURL = "https://example.com/work"
        let firstRepository = try XCTUnwrap(collection.repository(for: first.id))
        let secondRepository = try XCTUnwrap(collection.repository(for: second.id))
        try await firstRepository.publish(.init(article: a, images: [:]))
        try await secondRepository.publish(.init(article: b, images: [:]))

        XCTAssertEqual(collection.items.count, 2)
        XCTAssertEqual(Set(collection.items.map(\.id)).count, 2)
        XCTAssertEqual(collection.usage.articleCount, 2)
        XCTAssertEqual(collection.usage.publishedBytes, firstRepository.usage.publishedBytes + secondRepository.usage.publishedBytes)
        let read = ReadingQueueSearch.results(items: collection.items, query: "nebula", filter: .read)
        XCTAssertEqual(read.map(\.profileID), [second.id])
        let ordered = ReadingQueueSearch.results(items: Array(collection.items.reversed()), query: "", filter: .all)
        XCTAssertEqual(ordered.map(\.profileID), [first.id, second.id].sorted { $0.uuidString < $1.uuidString })
        manager.rename(second.id, to: "Research")
        XCTAssertEqual(collection.items.first { $0.profileID == second.id }?.profileName, "Research")
        try await XCTUnwrap(collection.repository(for: read[0].profileID)).remove(read[0].article.id)
        XCTAssertEqual(firstRepository.articles.map(\.id), [a.id])
        XCTAssertTrue(secondRepository.articles.isEmpty)
    }

    func testRepositoryChangesInvalidateCollectionAndUpdateGlobalResults() async throws {
        let manager = try manager(), profile = manager.create(name: "Work")
        let collection = ReadingQueueCollection(manager: manager) {
            try ReadingQueueStore(profileID: $0, directory: manager.directory)
        }
        let repository = try XCTUnwrap(collection.repository(for: profile.id))
        await repository.waitUntilReady()
        let article = makeReadingArticle(profileID: profile.id)
        try await repository.publish(.init(article: article, images: [:]))
        let before = collection.revisions
        var changes = 0
        let observation = collection.objectWillChange.sink { changes += 1 }
        try await repository.setRead(true, id: article.id)
        XCTAssertGreaterThan(changes, 0)
        XCTAssertNotEqual(collection.revisions, before)
        XCTAssertEqual(ReadingQueueSearch.results(items: collection.items, query: "", filter: .read).map(\.article.id), [article.id])
        withExtendedLifetime(observation) {}
    }

    func testProfileChangesUpdateOwnersAndRepositoryInventory() throws {
        let manager = try manager()
        var opened: [UUID] = []
        let collection = ReadingQueueCollection(manager: manager) { id in
            opened.append(id)
            return try ReadingQueueStore(profileID: id, directory: manager.directory)
        }
        let profile = manager.create(name: "Work")
        XCTAssertNotNil(collection.repository(for: profile.id))
        manager.rename(profile.id, to: "Research")
        XCTAssertEqual(collection.profiles.first { $0.id == profile.id }?.name, "Research")
        XCTAssertEqual(opened.filter { $0 == profile.id }.count, 1)
        XCTAssertTrue(manager.delete(profile.id))
        XCTAssertNil(collection.repository(for: profile.id))
    }

    func testOneFailedProfileRetainsOtherRepositoriesAndCanRetry() throws {
        let manager = try manager(), profile = manager.create(name: "Work")
        var shouldFail = true
        let collection = ReadingQueueCollection(manager: manager) { id in
            if id == profile.id && shouldFail { throw CocoaError(.fileReadNoPermission) }
            return try ReadingQueueStore(profileID: id, directory: manager.directory)
        }
        XCTAssertNotNil(collection.repository(for: manager.profiles[0].id))
        XCTAssertEqual(collection.failures.map(\.id), [profile.id])
        shouldFail = false
        collection.reload(profileID: profile.id)
        XCTAssertNotNil(collection.repository(for: profile.id))
        XCTAssertTrue(collection.failures.isEmpty)
    }

    func testDamageRetainsOwningProfileAndCountsAcrossRepositories() async throws {
        let manager = try manager(), profile = manager.create(name: "Work")
        let collection = ReadingQueueCollection(manager: manager) {
            try ReadingQueueStore(profileID: $0, directory: manager.directory)
        }
        let repository = try XCTUnwrap(collection.repository(for: profile.id)), id = UUID()
        let folder = ReadingQueueFiles.articleURL(profileID: profile.id, articleID: id, in: manager.directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: folder.appendingPathComponent("article.json"))
        repository.reload(); await repository.waitUntilReady()
        XCTAssertEqual(collection.damaged.map(\.profileID), [profile.id])
        XCTAssertEqual(collection.usage.articleCount, 1)
        try await XCTUnwrap(collection.repository(for: collection.damaged[0].profileID)).remove(id)
        XCTAssertTrue(collection.damaged.isEmpty)
    }
}
