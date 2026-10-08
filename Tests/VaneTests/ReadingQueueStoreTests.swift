import XCTest
@testable import vane

@MainActor final class ReadingQueueStoreTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reading-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPrivateRepositoryNeverCreatesFiles() throws {
        let directory = root()
        XCTAssertThrowsError(try ReadingQueueStore(profileID: Profile.incognito.id, directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testAtomicPublishReadStateAndRemoval() throws {
        let directory = root(), profile = ProfileManager.defaultID
        let repository = try ReadingQueueStore(profileID: profile, directory: directory)
        let article = makeReadingArticle()
        try repository.publish(.init(article: article, images: [:]))
        XCTAssertEqual(repository.articles.count, 1)
        XCTAssertGreaterThan(repository.usage.publishedBytes, 0)
        XCTAssertFalse(repository.articles[0].isRead)
        try repository.setRead(true, id: article.id)
        let reloaded = try ReadingQueueStore(profileID: profile, directory: directory)
        XCTAssertTrue(reloaded.articles[0].isRead)
        XCTAssertEqual(reloaded.articles[0].capturedAt, article.capturedAt)
        XCTAssertTrue(try ReadingQueueStore(profileID: UUID(), directory: directory).articles.isEmpty)
        try repository.remove(article.id)
        XCTAssertTrue(repository.articles.isEmpty)
        XCTAssertEqual(repository.usage.publishedBytes, 0)
    }
    func testFailedMutationPreservesPriorStateAndDuplicateSource() throws {
        let directory = root()
        var failure: String?
        let repository = try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: directory, checkpoint: {
            if $0 == failure { throw CocoaError(.fileWriteNoPermission) }
        })
        let article = makeReadingArticle()
        failure = "publish"
        XCTAssertThrowsError(try repository.publish(.init(article: article, images: [:])))
        XCTAssertTrue(repository.articles.isEmpty)
        XCTAssertTrue(try ReadingQueueFiles.ownedNames(in: directory).isEmpty)
        failure = nil; try repository.publish(.init(article: article, images: [:]))
        let path = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: directory).appendingPathComponent("article.json")
        let old = try Data(contentsOf: path)
        failure = "read-state"
        XCTAssertThrowsError(try repository.setRead(true, id: article.id))
        XCTAssertEqual(try Data(contentsOf: path), old)
        XCTAssertFalse(repository.articles[0].isRead)
        failure = "delete"
        XCTAssertThrowsError(try repository.remove(article.id))
        XCTAssertEqual(repository.articles.count, 1)
        failure = nil
        let duplicate = try repository.publish(.init(article: makeReadingArticle(), images: [:]))
        XCTAssertEqual(duplicate.id, article.id)
        XCTAssertEqual(repository.articles.count, 1)
    }
    func testDamagedSiblingIsPreservedAndRemovable() throws {
        let directory = root(), article = makeReadingArticle()
        let repository = try ReadingQueueStore(profileID: article.profileID, directory: directory)
        try repository.publish(.init(article: article, images: [:]))
        let badID = UUID()
        let bad = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: badID, in: directory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: bad.appendingPathComponent("article.json"))
        repository.reload()
        XCTAssertEqual(repository.articles.count, 1)
        XCTAssertEqual(repository.damaged.map(\.id), [badID])
        XCTAssertEqual(try Data(contentsOf: bad.appendingPathComponent("article.json")), Data("damaged".utf8))
        let beforeExtra = repository.usage.publishedBytes
        try Data(repeating: 7, count: 32_768).write(to: bad.appendingPathComponent("extra.bin"))
        repository.reload()
        XCTAssertEqual(repository.usage.publishedBytes, beforeExtra + 32_768, "Damaged files must still count toward storage usage")
        try repository.remove(badID)
        XCTAssertTrue(repository.damaged.isEmpty)
    }
    func testSymlinkAndInvalidationGuards() throws {
        let directory = root(), outside = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("ReadingQueue"), withDestinationURL: outside)
        XCTAssertThrowsError(try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: directory))
        let clean = root()
        let repository = try ReadingQueueStore.shared(profileID: ProfileManager.defaultID, directory: clean)
        try ReadingQueueStore.forget(profileID: ProfileManager.defaultID, directory: clean)
        XCTAssertThrowsError(try repository.publish(.init(article: makeReadingArticle(), images: [:])))
    }
    func testPathGrammarExcludesStagingTraversalAndUppercase() {
        let profile = UUID().uuidString.lowercased(), article = UUID().uuidString.lowercased()
        XCTAssertNotNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/\(profile)/\(article)/article.json"))
        XCTAssertNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/.staging/\(article)/article.json"))
        XCTAssertNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/\(profile)/\(article)/images/../outside.png"))
        XCTAssertNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/\(profile.uppercased())/\(article)/article.json"))
    }
}
