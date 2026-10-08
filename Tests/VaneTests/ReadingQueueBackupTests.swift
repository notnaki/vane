import XCTest
@testable import vane

@MainActor final class ReadingQueueBackupTests: XCTestCase {
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture(); _ = f.seed()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        return f
    }
    private func imageArticle(profile: UUID = ProfileManager.defaultID) throws -> ReadingQueueCandidate {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png))
        var article = makeReadingArticle(profileID: profile)
        article.isRead = true; article.resources = [raster.resource]
        article.nodes.append(.init(e: "img", a: ["src": "images/" + raster.resource.name, "alt": "Fixture image"]))
        return .init(article: article, images: [raster.resource.name: raster.data])
    }
    func testMultiProfileRoundTripWithImagesReadStateAndStagingExcluded() async throws {
        let source = try fixture(), target = try fixture()
        let manager = source.seed(), second = manager.create(name: "Second")
        let candidate = try imageArticle()
        let queue = try ReadingQueueStore(profileID: candidate.article.profileID, directory: source.root)
        try await queue.publish(candidate)
        try await ReadingQueueStore(profileID: second.id, directory: source.root).publish(.init(article: makeReadingArticle(profileID: second.id), images: [:]))
        let staging = source.root.appendingPathComponent("ReadingQueue/.staging/unpublished")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("not saved".utf8).write(to: staging.appendingPathComponent("article.json"))
        let archive = try source.library.capture(reason: .manual)
        XCTAssertFalse(archive.files.contains { $0.name.contains(".staging") })
        XCTAssertEqual(try source.library.validate(archive).readingQueue, 2)
        let transaction = BackupRestore(library: target.library)
        try transaction.prepare(archive)
        XCTAssertEqual(try transaction.recoverAtLaunch(), .restored)
        let restored = try ReadingQueueStore(profileID: candidate.article.profileID, directory: target.root)
        let saved = try await restored.candidate(candidate.article.id)
        XCTAssertEqual(saved.article, candidate.article)
        XCTAssertEqual(saved.images, candidate.images)
        let secondQueue = try ReadingQueueStore(profileID: second.id, directory: target.root)
        await secondQueue.waitUntilReady(); XCTAssertEqual(secondQueue.articles.count, 1)
        XCTAssertEqual(archive.files.filter { $0.name.hasPrefix("ReadingQueue/") }.count, 3)
    }
    func testPreQueueRestoreRemovesArticlesAndInterruptedRestoreRollsBackRawBytes() async throws {
        let source = try fixture(), target = try fixture()
        let incoming = try source.library.capture(reason: .manual)
        let candidate = try imageArticle()
        try await ReadingQueueStore(profileID: candidate.article.profileID, directory: target.root).publish(candidate)
        let names = try ReadingQueueFiles.ownedNames(in: target.root)
        let originals = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: target.root.appendingPathComponent($0))) })
        let transaction = BackupRestore(library: target.library, checkpoint: { phase in
            if phase.hasPrefix("removed:ReadingQueue/") { throw CocoaError(.fileWriteNoPermission) }
        })
        try transaction.prepare(incoming)
        XCTAssertThrowsError(try transaction.recoverAtLaunch())
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .rolledBack)
        for (name, bytes) in originals { XCTAssertEqual(try Data(contentsOf: target.root.appendingPathComponent(name)), bytes) }
        let healthy = BackupRestore(library: target.library)
        try healthy.prepare(incoming)
        XCTAssertEqual(try healthy.recoverAtLaunch(), .restored)
        let removed = try ReadingQueueStore(profileID: candidate.article.profileID, directory: target.root)
        await removed.waitUntilReady(); XCTAssertTrue(removed.articles.isEmpty)
        XCTAssertTrue(try ReadingQueueFiles.ownedNames(in: target.root).isEmpty)
    }
    func testBackupDuringStagedSaveIncludesOnlyPublishedInventory() async throws {
        let source = try fixture(), candidate = try imageArticle()
        var during: BackupArchive?
        let queue = try ReadingQueueStore(profileID: candidate.article.profileID, directory: source.root, checkpoint: { phase in
            if phase == "publish" {
                let stage = source.root.appendingPathComponent("ReadingQueue/.staging/" + candidate.article.profileID.uuidString.lowercased())
                let prepared = try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil)
                XCTAssertTrue(prepared.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("article.json").path) })
                during = try source.library.capture(reason: .manual)
            }
        })
        try await queue.publish(candidate)
        XCTAssertEqual(try source.library.validate(XCTUnwrap(during)).readingQueue, 0)
        XCTAssertEqual(try source.library.validate(source.library.capture(reason: .manual)).readingQueue, 1)
    }
    func testIncomingOrphansDamagedResourcesAndStagingAreRejected() async throws {
        let source = try fixture(), candidate = try imageArticle()
        try await ReadingQueueStore(profileID: candidate.article.profileID, directory: source.root).publish(candidate)
        let original = try source.library.capture(reason: .manual)
        var broken = original
        let imageIndex = try XCTUnwrap(broken.files.firstIndex { $0.name.hasSuffix(".png") })
        broken.files.remove(at: imageIndex)
        XCTAssertThrowsError(try source.library.validate(broken))
        broken = original
        let recordIndex = try XCTUnwrap(broken.files.firstIndex { $0.name.hasSuffix("/article.json") })
        var article = candidate.article; article.profileID = UUID()
        broken.files[recordIndex] = .init(name: broken.files[recordIndex].name, data: try ReadingArticleCodec.encode(article))
        XCTAssertThrowsError(try source.library.validate(broken))
        broken = original
        broken.files.append(.init(name: "ReadingQueue/.staging/article.json", data: Data()))
        XCTAssertThrowsError(try source.library.validate(broken))
    }
}
