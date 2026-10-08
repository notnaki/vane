import XCTest
@testable import vane

@MainActor final class ReadingQueueStoreTests: XCTestCase {
    private func expectFailure(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected a failed mutation", file: file, line: line) } catch {}
    }
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
    func testAtomicPublishReadStateAndRemoval() async throws {
        let directory = root(), profile = ProfileManager.defaultID
        let repository = try ReadingQueueStore(profileID: profile, directory: directory)
        let article = makeReadingArticle()
        try await repository.publish(.init(article: article, images: [:]))
        XCTAssertEqual(repository.articles.count, 1)
        XCTAssertGreaterThan(repository.usage.publishedBytes, 0)
        XCTAssertFalse(repository.articles[0].isRead)
        try await repository.setRead(true, id: article.id)
        let reloaded = try ReadingQueueStore(profileID: profile, directory: directory)
        await reloaded.waitUntilReady()
        XCTAssertTrue(reloaded.articles[0].isRead)
        XCTAssertEqual(reloaded.articles[0].capturedAt, article.capturedAt)
        XCTAssertTrue(try ReadingQueueStore(profileID: UUID(), directory: directory).articles.isEmpty)
        try await repository.remove(article.id)
        XCTAssertTrue(repository.articles.isEmpty)
        XCTAssertEqual(repository.usage.publishedBytes, 0)
    }
    func testFailedMutationPreservesPriorStateAndDuplicateSource() async throws {
        let directory = root()
        var failure: String?
        let repository = try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: directory, checkpoint: {
            if $0 == failure { throw CocoaError(.fileWriteNoPermission) }
        })
        let article = makeReadingArticle()
        failure = "publish"
        await expectFailure { _ = try await repository.publish(.init(article: article, images: [:])) }
        XCTAssertTrue(repository.articles.isEmpty)
        XCTAssertTrue(try ReadingQueueFiles.ownedNames(in: directory).isEmpty)
        failure = nil; try await repository.publish(.init(article: article, images: [:]))
        let path = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: directory).appendingPathComponent("article.json")
        let old = try Data(contentsOf: path)
        failure = "read-state"
        await expectFailure { _ = try await repository.setRead(true, id: article.id) }
        XCTAssertEqual(try Data(contentsOf: path), old)
        XCTAssertFalse(repository.articles[0].isRead)
        failure = "delete"
        await expectFailure { _ = try await repository.remove(article.id) }
        XCTAssertEqual(repository.articles.count, 1)
        failure = nil
        let duplicate = try await repository.publish(.init(article: makeReadingArticle(), images: [:]))
        XCTAssertEqual(duplicate.id, article.id)
        XCTAssertEqual(repository.articles.count, 1)
    }
    func testDamagedSiblingIsPreservedAndRemovable() async throws {
        let directory = root(), article = makeReadingArticle()
        let repository = try ReadingQueueStore(profileID: article.profileID, directory: directory)
        try await repository.publish(.init(article: article, images: [:]))
        let badID = UUID()
        let bad = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: badID, in: directory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: bad.appendingPathComponent("article.json"))
        repository.reload(); await repository.waitUntilReady()
        XCTAssertEqual(repository.articles.count, 1)
        XCTAssertEqual(repository.damaged.map(\.id), [badID])
        XCTAssertEqual(try Data(contentsOf: bad.appendingPathComponent("article.json")), Data("damaged".utf8))
        let beforeExtra = repository.usage.publishedBytes
        try Data(repeating: 7, count: 32_768).write(to: bad.appendingPathComponent("extra.bin"))
        repository.reload(); await repository.waitUntilReady()
        XCTAssertEqual(repository.usage.publishedBytes, beforeExtra + 32_768, "Damaged files must still count toward storage usage")
        try await repository.remove(badID)
        XCTAssertTrue(repository.damaged.isEmpty)
    }
    func testDamagedFileAndLinkEntriesCanBeRemovedWithoutFollowingLink() async throws {
        let directory = root(), outside = root(), profile = ProfileManager.defaultID
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep outside".utf8).write(to: sentinel)
        let repository = try ReadingQueueStore(profileID: profile, directory: directory)
        try await repository.publish(.init(article: makeReadingArticle(), images: [:]))
        let fileID = UUID(), linkID = UUID()
        let file = ReadingQueueFiles.articleURL(profileID: profile, articleID: fileID, in: directory)
        let link = ReadingQueueFiles.articleURL(profileID: profile, articleID: linkID, in: directory)
        try Data("invalid article entry".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        repository.reload(); await repository.waitUntilReady()
        XCTAssertEqual(Set(repository.damaged.map(\.id)), [fileID, linkID])
        try await repository.remove(fileID); try await repository.remove(linkID)
        XCTAssertTrue(repository.damaged.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep outside".utf8))
    }
    func testSymlinkAndInvalidationGuards() async throws {
        let directory = root(), outside = root()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("ReadingQueue"), withDestinationURL: outside)
        XCTAssertThrowsError(try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: directory))
        let clean = root()
        let repository = try ReadingQueueStore.shared(profileID: ProfileManager.defaultID, directory: clean)
        try ReadingQueueStore.forget(profileID: ProfileManager.defaultID, directory: clean)
        await expectFailure { _ = try await repository.publish(.init(article: makeReadingArticle(), images: [:])) }
    }
    func testProfileDeletionRemovesUnfinishedSnapshots() async throws {
        let directory = root(), profile = ProfileManager.defaultID
        let repository = try ReadingQueueStore.shared(profileID: profile, directory: directory)
        try await repository.publish(.init(article: makeReadingArticle(), images: [:]))
        let staging = ReadingQueueFiles.root(in: directory).appendingPathComponent(".staging").appendingPathComponent(profile.uuidString.lowercased())
        let abandoned = staging.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("unfinished private profile article".utf8).write(to: abandoned.appendingPathComponent("article.json"))
        try ReadingQueueStore.forget(profileID: profile, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(repository.invalidated)
    }
    func testRetryRemovesAbandonedFileAndLinkTrashWithoutFollowingLink() async throws {
        let directory = root(), outside = root(), profile = ProfileManager.defaultID
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("outside stays".utf8).write(to: sentinel)
        let stage = ReadingQueueFiles.root(in: directory).appendingPathComponent(".staging/" + profile.uuidString.lowercased())
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let file = stage.appendingPathComponent(UUID().uuidString.lowercased()), link = stage.appendingPathComponent(UUID().uuidString.lowercased())
        try Data("unfinished trash".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        let repository = try ReadingQueueStore(profileID: profile, directory: directory)
        await repository.waitUntilReady()
        XCTAssertNil(repository.error); XCTAssertEqual(repository.usage.pendingCleanupBytes, 0)
        XCTAssertFalse(ReadingQueueFiles.exists(file)); XCTAssertFalse(ReadingQueueFiles.exists(link))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside stays".utf8))
        try await repository.publish(.init(article: makeReadingArticle(), images: [:]))
        XCTAssertEqual(repository.articles.count, 1)
    }
    func testProfileInvalidationDiscardsPreparedSaveBeforePublication() async throws {
        let directory = root(), profile = ProfileManager.defaultID
        let repository = try ReadingQueueStore.shared(profileID: profile, directory: directory)
        var checks = 0
        await expectFailure {
            _ = try await repository.publish(.init(article: makeReadingArticle(), images: [:]), validity: {
                checks += 1
                if checks == 2 { try ReadingQueueStore.forget(profileID: profile, directory: directory) }
            })
        }
        XCTAssertEqual(checks, 2); XCTAssertTrue(repository.invalidated)
        XCTAssertTrue(try ReadingQueueFiles.ownedNames(in: directory).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ReadingQueueFiles.profileURL(profile, in: directory).path))
    }
    func testUnexpectedCanonicalImageRejectedBeforeReadingItsBytes() throws {
        let directory = root(), article = makeReadingArticle()
        let folder = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: directory)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        try ReadingArticleCodec.encode(article).write(to: folder.appendingPathComponent("article.json"))
        let extra = folder.appendingPathComponent("images/" + UUID().uuidString.lowercased() + ".png")
        FileManager.default.createFile(atPath: extra.path, contents: nil)
        let handle = try FileHandle(forWritingTo: extra); try handle.truncate(atOffset: UInt64(ReadingArticleCodec.imageLimit + 1)); try handle.close()
        do { _ = try ReadingQueueFiles.load(folder, profileID: article.profileID, articleID: article.id); XCTFail("Unexpected image accepted") }
        catch ReadingQueueFailure.invalid(let reason) { XCTAssertTrue(reason.contains("match")) }
        catch { XCTFail("Read the unexpected image before checking the resource set: \(error)") }
    }
    func testOversizedImageInventoryRejectedBeforeDecoding() throws {
        let directory = root()
        var article = makeReadingArticle()
        let folder = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: directory)
        let images = folder.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for _ in 0..<5 {
            let resource = ReadingArticle.Resource(name: UUID().uuidString.lowercased() + ".png", byteCount: ReadingArticleCodec.imageLimit,
                digest: String(repeating: "a", count: 64), pixelWidth: 1, pixelHeight: 1)
            article.resources.append(resource); article.nodes.append(.init(e: "img", a: ["src": "images/" + resource.name]))
            let path = images.appendingPathComponent(resource.name)
            FileManager.default.createFile(atPath: path.path, contents: nil)
            let handle = try FileHandle(forWritingTo: path); try handle.truncate(atOffset: UInt64(resource.byteCount)); try handle.close()
        }
        try ReadingArticleCodec.encode(article).write(to: folder.appendingPathComponent("article.json"))
        do { _ = try ReadingQueueFiles.load(folder, profileID: article.profileID, articleID: article.id); XCTFail("Oversized inventory accepted") }
        catch ReadingQueueFailure.tooLarge {}
        catch { XCTFail("Decoded image contents before rejecting the aggregate budget: \(error)") }
    }
    func testReloadKeepsMainActorResponsiveAndPublishesOnlyCompletedScan() async throws {
        let directory = root(), entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let repository = try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: directory, scanCheckpoint: {
            XCTAssertFalse(Thread.isMainThread)
            entered.signal(); gate.wait()
        })
        defer { gate.signal() }
        func started() -> Bool { entered.wait(timeout: .now()) == .success }
        try await compatibilityWait { started() }
        XCTAssertTrue(repository.loading)
        var heartbeat = false
        await Task { @MainActor in heartbeat = true }.value
        XCTAssertTrue(heartbeat, "Browser input must remain available during a disk/image scan")
        XCTAssertTrue(repository.articles.isEmpty)
        gate.signal(); await repository.waitUntilReady()
        XCTAssertFalse(repository.loading)
    }
    func testPathGrammarExcludesStagingTraversalAndUppercase() {
        let profile = UUID().uuidString.lowercased(), article = UUID().uuidString.lowercased()
        XCTAssertNotNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/\(profile)/\(article)/article.json"))
        XCTAssertNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/.staging/\(article)/article.json"))
        XCTAssertNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/\(profile)/\(article)/images/../outside.png"))
        XCTAssertNil(ReadingQueueFiles.parseOwnedName("ReadingQueue/\(profile.uppercased())/\(article)/article.json"))
    }
}
