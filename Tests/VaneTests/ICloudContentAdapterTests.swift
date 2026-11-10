import XCTest
@testable import vane

@MainActor final class ICloudContentAdapterTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let easel: EaselStore
        let queue: ReadingQueueStore
        let boosts: SiteBoostStore
        let subscriptions: FilterSubscriptions
        let adapter: ICloudContentAdapter
    }
    private func fixture(queueCheckpoint: @escaping (String) throws -> Void = { _ in },
                         easelInspection: @escaping @Sendable (String) throws -> Void = { _ in },
                         initialBoard: EaselBoard? = nil,
                         initialSubscriptions: [FilterSubscription] = [],
                         subscriptionFetch: @escaping (FilterSubscription) async throws -> FilterSubscriptions.Response = { _ in .init(status: 500) },
                         subscriptionValidation: @escaping (String) async throws -> Void = { _ in }) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-content-\(UUID())")
        let suite = "icloud-content-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: suite) }
        if let initialBoard {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(EaselStore.Archive(boards: [initialBoard])).write(to: EaselStore.file(profileID: ProfileManager.defaultID, directory: directory))
        }
        let easel = EaselStore(profileID: ProfileManager.defaultID, directory: directory, background: true, inspection: easelInspection)
        let queue = try ReadingQueueStore(profileID: ProfileManager.defaultID, directory: directory, checkpoint: queueCheckpoint)
        let boosts = SiteBoostStore(defaults: defaults)
        let subscriptionDirectory = directory.appendingPathComponent("FilterSubscriptions")
        if !initialSubscriptions.isEmpty { try FilterSubscriptions.write(initialSubscriptions, directory: subscriptionDirectory) }
        let subscriptions = FilterSubscriptions(directory: subscriptionDirectory, fetch: subscriptionFetch, validate: subscriptionValidation)
        let adapter = ICloudContentAdapter(directory: directory, defaults: defaults,
            profileIDs: { [ProfileManager.defaultID, Profile.incognito.id] },
            easelStore: { _ in easel }, readingStore: { _ in queue }, boosts: boosts, subscriptions: subscriptions)
        return .init(directory: directory, defaults: defaults, easel: easel, queue: queue, boosts: boosts, subscriptions: subscriptions, adapter: adapter)
    }
    func testEaselImportRetainsIdentityAndUnrelatedBoards() async throws {
        let source = try fixture(), target = try fixture()
        let original = try await source.easel.createAsync(title: "Sketch")
        _ = try await source.easel.mutateAsync(original.id) { $0.items = [.init(kind: .note, text: "Saved note"), .init(kind: .link, source: "https://example.com/live")] }
        let local = try await target.easel.createAsync(title: "Local")
        let items = try await source.adapter.capture([.easels])
        try await target.adapter.apply(items, deleted: [], enabled: [.easels])
        try await target.adapter.apply(items, deleted: [], enabled: [.easels])
        XCTAssertEqual(Set(target.easel.boards.map(\.id)), [original.id, local.id])
        XCTAssertEqual(target.easel.board(original.id)?.items.first?.text, "Saved note")
        var conflict = try XCTUnwrap(items.first); conflict.id = "\(ProfileManager.defaultID.uuidString.lowercased())/\(UUID().uuidString.lowercased())"
        try await target.adapter.apply([conflict], deleted: [], enabled: [.easels])
        XCTAssertEqual(target.easel.boards.count, 3, "Journal conflict UUID must become a second board")
    }
    func testCancelledDeletionCannotRemoveSavedBoard() async throws {
        let target = try fixture()
        let board = try await target.easel.createAsync(title: "Keep")
        let items = try await target.adapter.capture([.easels])
        let task = Task { @MainActor in try await target.adapter.apply([], deleted: items, enabled: [.easels]) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled remote deletion must not remove saved work") } catch is CancellationError { }
        XCTAssertNotNil(target.easel.board(board.id))
    }
    func testCancellationAtEaselWriterGateCannotPublishRemoteBoard() async throws {
        let source = try fixture()
        _ = try await source.easel.createAsync(title: "Remote")
        let items = try await source.adapter.capture([.easels])
        let gate = EaselWorkerGate("save")
        let target = try fixture(easelInspection: gate.inspect)
        let task = Task { @MainActor in try await target.adapter.apply(items, deleted: [], enabled: [.easels]) }
        await gate.waitForEntry()
        task.cancel(); gate.resume()
        do { try await task.value; XCTFail("Revoked writer must stop before committing remote content") } catch is CancellationError { }
        XCTAssertTrue(target.easel.boards.isEmpty)
        let reopened = EaselStore(profileID: ProfileManager.defaultID, directory: target.directory)
        XCTAssertTrue(reopened.boards.isEmpty)
    }
    func testMalformedFilterPreferencesCannotBecomeDeletionSnapshots() async throws {
        for key in ["blockerLists", "blockerImportedNames"] {
            let target = try fixture()
            target.defaults.set(42, forKey: key)
            do { _ = try await target.adapter.capture([.contentBlocking]); XCTFail("Malformed \(key) must fail capture") }
            catch { }
        }
    }
    func testReadingMetadataExcludesBodyAndDoesNotCreateOfflineExport() async throws {
        let source = try fixture(), target = try fixture()
        let article = makeReadingArticle(text: "secret offline body")
        try await source.queue.publish(.init(article: article, images: [:]))
        let items = try await source.adapter.capture([.readingQueue])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items.flatMap { $0.fields.values }.contains { String(decoding: $0, as: UTF8.self).contains("secret offline body") })
        try await target.adapter.apply(items, deleted: [], enabled: [.readingQueue])
        XCTAssertEqual(target.queue.articles.first?.id, article.id)
        XCTAssertEqual(target.queue.articles.first?.title, article.title)
        let offline = try await target.adapter.capture([.offlineArticles])
        XCTAssertTrue(offline.isEmpty)
    }
    func testOfflineOnlyCarriesSavedTextImagesButNoMetadata() async throws {
        let source = try fixture(), target = try fixture()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png))
        var article = makeReadingArticle(); article.title = "Private metadata title"
        article.nodes.append(.init(e: "img", a: ["src": "images/" + raster.resource.name]))
        article.resources = [raster.resource]
        try await source.queue.publish(.init(article: article, images: [raster.resource.name: raster.data]))
        let items = try await source.adapter.capture([.offlineArticles])
        XCTAssertTrue(items.allSatisfy { $0.category == .offlineArticles })
        XCTAssertFalse(items.flatMap { $0.fields.values }.contains { String(decoding: $0, as: UTF8.self).contains(article.title) })
        try await target.adapter.apply(items, deleted: [], enabled: [.offlineArticles])
        let saved = try await target.queue.candidate(article.id)
        XCTAssertEqual(saved.article.nodes, article.nodes); XCTAssertEqual(saved.images[raster.resource.name], raster.data)
        XCTAssertEqual(saved.article.title, "Saved article")
        try await target.adapter.apply(try await source.adapter.capture([.readingQueue]), deleted: [], enabled: [.readingQueue])
        XCTAssertEqual(target.queue.articles.first?.title, article.title)
        let afterMetadata = try await target.queue.candidate(article.id)
        XCTAssertEqual(afterMetadata.images[raster.resource.name], raster.data)
    }
    func testDamagedAssetFailsBeforeMutatingLocalBoard() async throws {
        let source = try fixture(), target = try fixture()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let board = try await source.easel.createAsync()
        _ = try await source.easel.mutateAsync(board.id) { $0.items = [.init(kind: .image, image: png)] }
        var items = try await source.adapter.capture([.easels])
        let key = try XCTUnwrap(items[0].fields.keys.first { $0.hasPrefix("asset.") })
        items[0].fields[key] = Data("damaged".utf8)
        do { try await target.adapter.apply(items, deleted: [], enabled: [.easels]); XCTFail("Must reject digest mismatch") } catch {}
        XCTAssertTrue(target.easel.boards.isEmpty)
        items[0].fields[key] = nil
        do { try await target.adapter.apply(items, deleted: [], enabled: [.easels]); XCTFail("Must reject missing asset") } catch {}
    }
    func testIncomingBoostScriptAlwaysRequiresLocalConsent() async throws {
        let source = try fixture(), target = try fixture()
        var boost = SiteBoost(); boost.css = "body { color:red }"; boost.script = "window.pwned=true"; boost.scriptEnabled = true
        source.boosts.set(boost, origin: "https://example.com", profile: ProfileManager.defaultID)
        try await target.adapter.apply(try await source.adapter.capture([.boosts]), deleted: [], enabled: [.boosts])
        let saved = target.boosts.get(origin: "https://example.com", profile: ProfileManager.defaultID)
        XCTAssertEqual(saved.script, boost.script); XCTAssertEqual(saved.css, boost.css); XCTAssertFalse(saved.scriptEnabled)
    }
    func testDisabledCategoriesNeverReadOrApply() async throws {
        let source = try fixture(), target = try fixture()
        _ = try await source.easel.createAsync(title: "Private board")
        let items = try await source.adapter.capture([.easels])
        let empty = try await source.adapter.capture([])
        XCTAssertTrue(empty.isEmpty)
        try await target.adapter.apply(items, deleted: items, enabled: [])
        XCTAssertTrue(target.easel.boards.isEmpty)
    }
    func testDamagedQueueDoesNotBecomeEmptySuccessfulCapture() async throws {
        let source = try fixture(), article = makeReadingArticle()
        try await source.queue.publish(.init(article: article, images: [:]))
        let file = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: source.directory).appendingPathComponent("article.json")
        try Data("broken".utf8).write(to: file)
        source.queue.reload(); await source.queue.waitUntilReady()
        do { _ = try await source.adapter.capture([.readingQueue]); XCTFail("Damaged inventory cannot imply deletion") } catch {}
    }
    func testOwnedFilterRulesTransferWithoutLocalPathOrNetworkFetch() async throws {
        let source = try fixture(), target = try fixture()
        let folder = source.directory.appendingPathComponent("FilterLists")
        let name = try BlockerFiles.importList("||tracking.example^", into: folder)
        source.defaults.set([name], forKey: "blockerImportedLists")
        source.defaults.set([name: "My custom rules"], forKey: "blockerImportedNames")
        let items = try await source.adapter.capture([.contentBlocking])
        XCTAssertFalse(items.flatMap { $0.fields.values }.contains { String(decoding: $0, as: UTF8.self).contains(source.directory.path) })
        try await target.adapter.apply(items, deleted: [], enabled: [.contentBlocking])
        let imported = try XCTUnwrap(target.defaults.stringArray(forKey: "blockerImportedLists")?.first)
        XCTAssertEqual(try BlockerFiles.readText(target.directory.appendingPathComponent("FilterLists").appendingPathComponent(imported)), "||tracking.example^")
    }
    func testOversizeAndTraversalAssetsAreRejectedWithoutWrites() async throws {
        let source = try fixture(), target = try fixture()
        _ = try await source.easel.createAsync()
        let captured = try await source.adapter.capture([.easels])
        var item = try XCTUnwrap(captured.first)
        item.fields["asset." + String(repeating: "a", count: 64)] = Data(repeating: 0, count: 32 * 1024 * 1024 + 1)
        do { try await target.adapter.apply([item], deleted: [], enabled: [.easels]); XCTFail("Oversize bytes must fail") } catch {}
        XCTAssertTrue(target.easel.boards.isEmpty)
        item.fields = ["asset../../outside": Data("escape".utf8)]
        do { try await target.adapter.apply([item], deleted: [], enabled: [.easels]); XCTFail("Untrusted asset name must fail") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.appendingPathComponent("outside").path))
    }

    func testFailedArticleImportPreservesDiskAndPublishedState() async throws {
        let source = try fixture()
        var fail = false
        let target = try fixture(queueCheckpoint: { if fail, $0 == "sync-publish" { throw CocoaError(.fileWriteNoPermission) } })
        var article = makeReadingArticle(); article.title = "Original title"
        try await source.queue.publish(.init(article: article, images: [:]))
        try await target.queue.publish(.init(article: article, images: [:]))
        let file = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: target.directory).appendingPathComponent("article.json")
        let original = try Data(contentsOf: file)
        try await source.queue.setRead(true, id: article.id)
        let incoming = try await source.adapter.capture([.readingQueue])
        fail = true
        do { try await target.adapter.apply(incoming, deleted: [], enabled: [.readingQueue]); XCTFail("Failure must propagate") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(target.queue.articles[0].isRead)
    }
    func testOfflineDeletionPreservesMetadataAndStopsBodyExport() async throws {
        let source = try fixture(), target = try fixture(), article = makeReadingArticle()
        try await source.queue.publish(.init(article: article, images: [:]))
        let incoming = try await source.adapter.capture([.readingQueue, .offlineArticles])
        try await target.adapter.apply(incoming, deleted: [], enabled: [.readingQueue, .offlineArticles])
        let offline = incoming.filter { $0.category == .offlineArticles }
        try await target.adapter.apply([], deleted: offline, enabled: [.offlineArticles])
        XCTAssertEqual(target.queue.articles.first?.title, article.title)
        XCTAssertFalse(ReadingArticleCodec.plainText(target.queue.articles[0]).contains("nebula"))
        let remaining = try await target.adapter.capture([.offlineArticles])
        XCTAssertTrue(remaining.isEmpty)
    }

    func testLegacySelectedRulesTransferAsOwnedBytesWithoutSourceGrant() async throws {
        let source = try fixture(), target = try fixture()
        let original = source.directory.appendingPathComponent("selected-rules.txt")
        try FileManager.default.createDirectory(at: source.directory, withIntermediateDirectories: true)
        try "||legacy.example^".write(to: original, atomically: true, encoding: .utf8)
        source.defaults.set([original.path], forKey: "blockerLists")
        let incoming = try await source.adapter.capture([.contentBlocking])
        try await target.adapter.apply(incoming, deleted: [], enabled: [.contentBlocking])
        let names = target.defaults.stringArray(forKey: "blockerImportedLists") ?? []
        XCTAssertEqual(names.count, 1)
        guard let name = names.first else { return }
        XCTAssertEqual(try BlockerFiles.readText(target.directory.appendingPathComponent("FilterLists").appendingPathComponent(name)), "||legacy.example^")
        XCTAssertNil(target.defaults.object(forKey: "blockerLists"))
        XCTAssertFalse(incoming.flatMap { $0.fields.values }.contains { String(decoding: $0, as: UTF8.self).contains(original.path) })
    }

    func testRemoteExceptionPreservesUnrelatedLocalSiteChoice() async throws {
        let source = try fixture(), target = try fixture()
        let key = ProfileManager.defaultsKey("blockerSiteExceptions", ProfileManager.defaultID)
        source.defaults.set(["remote.example"], forKey: key)
        target.defaults.set(["local.example"], forKey: key)
        try await target.adapter.apply(try await source.adapter.capture([.contentBlocking]), deleted: [], enabled: [.contentBlocking])
        XCTAssertEqual(Set(target.defaults.stringArray(forKey: key) ?? []), ["local.example", "remote.example"])
    }

    func testLateLocalEaselEditKeepsOriginalAndRemoteConflictCopy() async throws {
        let source = try fixture()
        let board = try await source.easel.createAsync(title: "Baseline")
        let gate = EaselWorkerGate("save")
        let target = try fixture(easelInspection: gate.inspect, initialBoard: board)
        let baselineItems = try await target.adapter.capture([.easels])
        let baseline = Dictionary(uniqueKeysWithValues: baselineItems.map { ($0.key, $0) })
        _ = try await source.easel.mutateAsync(board.id) { $0.title = "Remote title" }
        let remote = try await source.adapter.capture([.easels])
        let local = Task { @MainActor in try await target.easel.mutateAsync(board.id) { $0.title = "Local title" } }
        await gate.waitForEntry()
        let importing = Task { @MainActor in
            try await ICloudApplyContext.$baseline.withValue(baseline) {
                try await target.adapter.apply(remote, deleted: [], enabled: [.easels])
            }
        }
        await Task.yield(); gate.resume()
        _ = try await local.value; try await importing.value
        XCTAssertEqual(target.easel.board(board.id)?.title, "Local title")
        XCTAssertEqual(target.easel.boards.count, 2)
        XCTAssertTrue(target.easel.boards.contains { $0.id != board.id && $0.title.hasPrefix("Remote title") })
        let conflictID = try XCTUnwrap(target.easel.boards.first { $0.id != board.id }?.id)
        try await ICloudApplyContext.$baseline.withValue(baseline) {
            try await target.adapter.apply(remote, deleted: [], enabled: [.easels])
        }
        XCTAssertEqual(target.easel.boards.count, 2)
        XCTAssertNotNil(target.easel.board(conflictID), "Retry must reuse the stable conflict identity")
    }
    func testHeldArticleImportPreservesLateReadStateAndOfflineBody() async throws {
        let source = try fixture(), target = try fixture(), article = makeReadingArticle(text: "Baseline body")
        try await source.queue.publish(.init(article: article, images: [:]))
        try await target.queue.publish(.init(article: article, images: [:]))
        let baselineItems = try await target.adapter.capture([.readingQueue, .offlineArticles])
        let baseline = Dictionary(uniqueKeysWithValues: baselineItems.map { ($0.key, $0) })
        try await source.queue.mergeICloudArticle(article.id) { saved in
            var candidate = saved!; candidate.article.title = "Remote title"
            candidate.article.nodes = [.init(x: "Remote body")]; return candidate
        }
        let remote = try await source.adapter.capture([.readingQueue, .offlineArticles])
        let gate = EaselWorkerGate("article-update")
        let local = Task { @MainActor in
            try await target.queue.mergeICloudArticle(article.id) { saved in
                gate.inspect("article-update")
                var candidate = saved!; candidate.article.isRead = true
                candidate.article.nodes = [.init(x: "Late local body")]; return candidate
            }
        }
        await gate.waitForEntry()
        let importing = Task { @MainActor in
            try await ICloudApplyContext.$baseline.withValue(baseline) {
                try await target.adapter.apply(remote, deleted: [], enabled: [.readingQueue, .offlineArticles])
            }
        }
        await Task.yield(); gate.resume()
        try await local.value; try await importing.value
        let saved = try await target.queue.candidate(article.id)
        XCTAssertEqual(saved.article.title, "Remote title")
        XCTAssertTrue(saved.article.isRead)
        XCTAssertEqual(ReadingArticleCodec.plainText(saved.article), "Late local body")
    }

    func testBoostLateFieldEditSurvivesEarlierOwnerAwait() async throws {
        let source = try fixture(), gate = EaselWorkerGate("save")
        let target = try fixture(easelInspection: gate.inspect)
        let origin = "https://boost.example", profile = ProfileManager.defaultID
        var value = SiteBoost(); value.css = "body { color: blue }"
        source.boosts.set(value, origin: origin, profile: profile)
        target.boosts.set(value, origin: origin, profile: profile)
        let baselineItems = try await target.adapter.capture([.boosts])
        let baseline = Dictionary(uniqueKeysWithValues: baselineItems.map { ($0.key, $0) })
        value.css = "body { color: red }"; source.boosts.set(value, origin: origin, profile: profile)
        _ = try await source.easel.createAsync(title: "Earlier remote owner")
        let incoming = try await source.adapter.capture([.easels, .boosts])
        let importing = Task { @MainActor in
            try await ICloudApplyContext.$baseline.withValue(baseline) {
                try await target.adapter.apply(incoming, deleted: [], enabled: [.easels, .boosts])
            }
        }
        await gate.waitForEntry()
        var local = target.boosts.get(origin: origin, profile: profile); local.font = "Georgia"
        target.boosts.set(local, origin: origin, profile: profile)
        gate.resume(); try await importing.value
        let saved = target.boosts.get(origin: origin, profile: profile)
        XCTAssertEqual(saved.font, "Georgia")
        XCTAssertEqual(saved.css, "body { color: red }")
    }
    func testSubscriptionLateTextSurvivesQueuedGateAndKeepsRemoteURL() async throws {
        let original = FilterSubscription(url: URL(string: "https://lists.example/base.txt")!, text: "||base.example^")
        let source = try fixture(initialSubscriptions: [original])
        let gate = ICloudContentAsyncGate()
        let target = try fixture(initialSubscriptions: [original], subscriptionFetch: { _ in
            await gate.hold()
            return .init(status: 200, text: "||late-local.example^")
        })
        let baselineItems = try await target.adapter.capture([.contentBlocking])
        let baseline = Dictionary(uniqueKeysWithValues: baselineItems.map { ($0.key, $0) })
        var remote = original; remote.url = URL(string: "https://lists.example/remote.txt")!; remote.text = "||remote.example^"
        try await source.subscriptions.mergeICloudSubscription(remote, deleting: original.id)
        let incoming = try await source.adapter.capture([.contentBlocking])
        let localUpdate = Task { @MainActor in await target.subscriptions.update(original.id) }
        await gate.waitForEntry()
        let importing = Task { @MainActor in
            try await ICloudApplyContext.$baseline.withValue(baseline) {
                try await target.adapter.apply(incoming, deleted: [], enabled: [.contentBlocking])
            }
        }
        await Task.yield(); await gate.resume()
        await localUpdate.value; try await importing.value
        let saved = try XCTUnwrap(target.subscriptions.items.first)
        XCTAssertEqual(saved.text, "||late-local.example^")
        XCTAssertEqual(saved.url.absoluteString, "https://lists.example/remote.txt")
    }
    func testBlockerLateNativeEditsKeepLocalRulesAndIndependentRemoteTitle() async throws {
        let source = try fixture(), gate = EaselWorkerGate("save")
        let target = try fixture(easelInspection: gate.inspect)
        let profile = ProfileManager.defaultID
        let sourceRoot = source.directory.appendingPathComponent("FilterLists")
        let sourceName = try BlockerFiles.importList("||baseline.example^", into: sourceRoot)
        source.defaults.set([sourceName], forKey: "blockerImportedLists")
        source.defaults.set([sourceName: "Original name"], forKey: "blockerImportedNames")
        let exceptionKey = ProfileManager.defaultsKey("blockerSiteExceptions", profile)
        source.defaults.set(["allowed.example"], forKey: exceptionKey)
        try await target.adapter.apply(try await source.adapter.capture([.contentBlocking]), deleted: [], enabled: [.contentBlocking])
        let baselineItems = try await target.adapter.capture([.contentBlocking])
        let baseline = Dictionary(uniqueKeysWithValues: baselineItems.map { ($0.key, $0) })
        try "||remote.example^".write(to: sourceRoot.appendingPathComponent(sourceName), atomically: true, encoding: .utf8)
        source.defaults.set([sourceName: "Remote name"], forKey: "blockerImportedNames")
        _ = try await source.easel.createAsync(title: "Earlier remote owner")
        let incoming = try await source.adapter.capture([.easels, .contentBlocking])
        let importing = Task { @MainActor in
            try await ICloudApplyContext.$baseline.withValue(baseline) {
                try await target.adapter.apply(incoming, deleted: [], enabled: [.easels, .contentBlocking])
            }
        }
        await gate.waitForEntry()
        let enabledKey = ProfileManager.defaultsKey("blockerEnabled", profile)
        target.defaults.set(false, forKey: enabledKey); target.defaults.set([String](), forKey: exceptionKey)
        let targetName = try XCTUnwrap(target.defaults.stringArray(forKey: "blockerImportedLists")?.first)
        let localFile = target.directory.appendingPathComponent("FilterLists").appendingPathComponent(targetName)
        try "||late-local.example^".write(to: localFile, atomically: true, encoding: .utf8)
        gate.resume(); try await importing.value
        XCTAssertFalse(target.defaults.bool(forKey: enabledKey))
        XCTAssertEqual(target.defaults.stringArray(forKey: exceptionKey), [])
        XCTAssertEqual(try BlockerFiles.readText(localFile), "||late-local.example^")
        XCTAssertEqual((target.defaults.dictionary(forKey: "blockerImportedNames") as? [String: String])?[targetName], "Remote name")
    }

    func testSubscriptionRevokedDuringValidationKeepsPublishedAndDurableCopy() async throws {
        let original = FilterSubscription(url: URL(string: "https://lists.example/base.txt")!, text: "||base.example^")
        let source = try fixture(initialSubscriptions: [original]), gate = ICloudContentAsyncGate()
        let target = try fixture(initialSubscriptions: [original], subscriptionValidation: { _ in await gate.hold() })
        var remote = original; remote.text = "||remote.example^"
        try await source.subscriptions.mergeICloudSubscription(remote, deleting: original.id)
        let incoming = try await source.adapter.capture([.contentBlocking])
        let importing = Task { @MainActor in try await target.adapter.apply(incoming, deleted: [], enabled: [.contentBlocking]) }
        await gate.waitForEntry(); importing.cancel(); await gate.resume()
        do { try await importing.value; XCTFail("Revoked subscription must not publish") } catch is CancellationError { }
        XCTAssertEqual(target.subscriptions.items, [original])
        let durable = try FilterSubscriptions.read(directory: target.directory.appendingPathComponent("FilterSubscriptions"))
        XCTAssertEqual(durable, [original])
    }

}

private actor ICloudContentAsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entryWaiters.forEach { $0.resume() }; entryWaiters = []
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func resume() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
