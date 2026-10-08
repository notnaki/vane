import XCTest
@testable import vane

/// Real repositories and the launch transaction share one synthetic, isolated library.
@MainActor final class DataIntegrationTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare() }
    private struct Inventory {
        var profiles: [Profile]
        var templates: [WorkspaceTemplate]
        var spaces: [Space]
        var boards: [EaselBoard]
        var articles: [ReadingQueueCandidate]
    }
    private enum Interrupted: Error { case now }
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture(); _ = f.seed()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        return f
    }
    private func populate(_ f: BackupFixture) async throws -> Inventory {
        let manager = f.seed()
        let profiles = [manager.active, manager.create(name: "Research")]
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png))
        var inventory = Inventory(profiles: profiles, templates: [], spaces: [], boards: [], articles: [])
        for (index, profile) in profiles.enumerated() {
            let easels = EaselStore(profileID: profile.id, directory: f.root)
            var board = try easels.create(title: "Board \(index)")
            board.items = [EaselItem(kind: .note, text: "Synthetic note \(index)"), EaselItem(kind: .image, image: raster.data)]
            try easels.save(board)
            inventory.boards.append(try XCTUnwrap(easels.board(board.id)))
            let url = URL(string: "https://example.test/article")!
            let first = UUID(), second = UUID(), easel = UUID()
            let layout = SpaceLayout(tabs: [
                .init(id: first, url: url, kind: .pinned, title: "Article", customName: "Source"),
                .init(id: second, url: url, kind: .today, title: "Duplicate", customName: "Notes"),
                .init(id: easel, url: EaselAddress.url(board.id), kind: .today, title: board.title)
            ], pins: Pins(entries: [.init(row: .tab(first.uuidString))]),
               today: Pins(entries: [.init(row: .tab(second.uuidString)), .init(row: .tab(easel.uuidString))]),
               splits: [.init(urls: [url.absoluteString, url.absoluteString], vertical: true, active: 1,
                              ids: [first.uuidString, second.uuidString], weights: [0.3, 0.7])], selected: second)
            var space = Space(name: "Source \(index)", profileID: profile.id,
                tabURLs: [url, EaselAddress.url(board.id)], pinnedTabURLs: [url])
            space.layout = layout
            XCTAssertTrue(manager.saveSpaces([space], for: profile.id))
            let templates = WorkspaceTemplates(manager: manager)
            let template = try templates.save(name: "Setup \(index)", space: space, layout: layout, unlocked: [])
            XCTAssertEqual(template.layout.tabs.count, 2, "Local Easels are excluded from templates")
            inventory.templates.append(template)
            let copy = try templates.create(template.id, profile: profile.id, name: "Copy \(index)", unlocked: [])
            inventory.spaces += [space, copy]
            var article = makeReadingArticle(profileID: profile.id, text: "Offline original \(index)")
            article.isRead = index == 1; article.resources = [raster.resource]
            article.nodes.append(.init(e: "img", a: ["src": "images/" + raster.resource.name]))
            let candidate = ReadingQueueCandidate(article: article, images: [raster.resource.name: raster.data])
            try await ReadingQueueStore(profileID: profile.id, directory: f.root).publish(candidate)
            inventory.articles.append(candidate)
            var boost = SiteBoost(); boost.font = index == 0 ? "Georgia" : "Menlo"
            boost.textScale = 1.25; boost.background = "#123456"; boost.hidden = [".advert"]
            boost.css = "p { margin: 2em }"; boost.script = "window.syntheticBoost = \(index);"
            boost.scriptEnabled = index == 1
            SiteBoostStore(defaults: f.defaults).set(boost, origin: "https://example.test", profile: profile.id)
        }
        f.defaults.set(27, forKey: "readerFontSize"); f.defaults.set(false, forKey: "readerSerif")
        f.defaults.set(1.9, forKey: "readerLineSpacing"); f.defaults.set(82, forKey: "readerWidth")
        f.defaults.set("local bookkeeping", forKey: "backup.lastPoint")
        return inventory
    }
    private func preferences(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
    }
    private func assertInventory(_ expected: Inventory, in f: BackupFixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        // New instances model a cold launch; none can rely on the old in-memory inventory.
        let manager = f.seed(), templates = WorkspaceTemplates(manager: manager)
        XCTAssertEqual(manager.profiles, expected.profiles, file: file, line: line)
        let boosts = SiteBoostStore(defaults: try XCTUnwrap(UserDefaults(suiteName: f.domain)))
        for (index, profile) in expected.profiles.enumerated() {
            XCTAssertEqual(try templates.load(profile: profile.id), [expected.templates[index]], file: file, line: line)
            XCTAssertEqual(manager.spaces(for: profile.id), expected.spaces.filter { $0.profileID == profile.id }, file: file, line: line)
            XCTAssertEqual(EaselStore(profileID: profile.id, directory: f.root).boards, [expected.boards[index]], file: file, line: line)
            let queue = try ReadingQueueStore(profileID: profile.id, directory: f.root)
            await queue.waitUntilReady()
            XCTAssertNil(queue.error, file: file, line: line)
            XCTAssertEqual(queue.articles, [expected.articles[index].article], file: file, line: line)
            let candidate = try await queue.candidate(expected.articles[index].article.id)
            XCTAssertEqual(candidate.images, expected.articles[index].images, file: file, line: line)
            XCTAssertFalse(queue.articles.contains { $0.profileID != profile.id }, file: file, line: line)
            XCTAssertEqual(boosts.get(origin: "https://example.test", profile: profile.id).font, index == 0 ? "Georgia" : "Menlo", file: file, line: line)
            XCTAssertEqual(boosts.get(origin: "https://example.test:8443", profile: profile.id), SiteBoost(), file: file, line: line)
            XCTAssertEqual(boosts.get(origin: "https://sub.example.test", profile: profile.id), SiteBoost(), file: file, line: line)
        }
        XCTAssertEqual(f.defaults.integer(forKey: "readerFontSize"), 27, file: file, line: line)
        XCTAssertEqual(f.defaults.bool(forKey: "readerSerif"), false, file: file, line: line)
        XCTAssertEqual(f.defaults.double(forKey: "readerLineSpacing"), 1.9, file: file, line: line)
        XCTAssertEqual(f.defaults.integer(forKey: "readerWidth"), 82, file: file, line: line)
    }
    func testPopulatedLibraryExportDeleteRestoreAndColdReopen() async throws {
        let f = try fixture(), inventory = try await populate(f)
        let archive = try f.library.capture(reason: .manual)
        let export = f.root.appendingPathComponent("export.vanebackup")
        try BackupCodec.write(archive, to: export)
        XCTAssertEqual(try f.library.validate(archive).easels, 2)
        XCTAssertEqual(try f.library.validate(archive).readingQueue, 2)
        // Delete each owned file and replace settings, retaining only the external backup.
        for name in try f.library.ownedNames() { try FileManager.default.removeItem(at: f.root.appendingPathComponent(name)) }
        f.defaults.setPersistentDomain(["readerFontSize": 13, "backup.lastPoint": "this device"], forName: f.domain)
        _ = f.seed()
        let transaction = BackupRestore(library: f.library)
        try transaction.prepare(BackupCodec.read(export))
        XCTAssertEqual(try BackupRestore(library: f.library).recoverAtLaunch(), .restored)
        XCTAssertEqual(try f.library.capture(reason: .manual).files, archive.files)
        XCTAssertEqual(try preferences(f.library.currentPreferences()), try preferences(archive.preferences))
        XCTAssertEqual(f.defaults.string(forKey: "backup.lastPoint"), "this device")
        try await assertInventory(inventory, in: f)
        XCTAssertEqual(try BackupRestore(library: f.library).recoverAtLaunch(), .none)
        try await assertInventory(inventory, in: f)
    }
    func testEveryPopulatedRestoreCheckpointPreservesCompleteRecoverableInventory() async throws {
        let source = try fixture(); _ = try await populate(source)
        let incoming = try source.library.capture(reason: .manual)
        let probe = try fixture(); _ = try await populate(probe)
        var checkpoints: [String] = []
        let complete = BackupRestore(library: probe.library, checkpoint: { checkpoints.append($0) })
        try complete.prepare(incoming); XCTAssertEqual(try complete.recoverAtLaunch(), .restored)
        XCTAssertTrue(checkpoints.contains { $0.hasPrefix("installed:ReadingQueue/") })
        for (stopIndex, stop) in checkpoints.enumerated() {
            let target = try fixture(), originals = try await populate(target)
            let before = try target.library.capture(reason: .manual)
            let originalPreferences = try target.library.currentPreferences(includeLocal: true)
            var reached = 0
            let transaction = BackupRestore(library: target.library, checkpoint: { _ in
                defer { reached += 1 }
                if reached == stopIndex { throw Interrupted.now }
            })
            try transaction.prepare(incoming)
            XCTAssertThrowsError(try transaction.recoverAtLaunch(), stop)
            let recovered = try BackupRestore(library: target.library).recoverAtLaunch()
            if stop == "committed" {
                XCTAssertEqual(recovered, .restored, stop)
                XCTAssertEqual(try target.library.capture(reason: .manual).files, incoming.files, stop)
                XCTAssertEqual(try preferences(target.library.currentPreferences()), try preferences(incoming.preferences), stop)
            } else {
                XCTAssertEqual(recovered, .rolledBack, stop)
                XCTAssertEqual(try target.library.capture(reason: .manual).files, before.files, stop)
                XCTAssertEqual(try self.preferences(target.library.currentPreferences(includeLocal: true)), try self.preferences(originalPreferences), stop)
                try await assertInventory(originals, in: target)
            }
            XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .none, stop)
        }
    }
    func testCorruptBoostPreferencesAreRejectedBeforeRestoreAndPreservedForRecovery() throws {
        let f = try fixture(), key = SiteBoostStore.key(f.seed().active.id)
        let healthy = try f.library.capture(reason: .manual)
        let corrupt = Data("broken Boost JSON".utf8)
        f.defaults.set(corrupt, forKey: key)
        XCTAssertThrowsError(try f.library.capture(reason: .manual)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Boost"))
        }
        let evidence = try f.library.capture(reason: .beforeRestore, allowDamaged: true)
        XCTAssertNotNil(evidence.damage)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: evidence.preferences, format: nil) as? [String: Any])
        XCTAssertEqual(values[key] as? Data, corrupt)
        XCTAssertThrowsError(try BackupRestore(library: f.library).prepare(evidence))
        XCTAssertEqual(f.defaults.data(forKey: key), corrupt)
        let repair = BackupRestore(library: f.library)
        try repair.prepare(healthy)
        XCTAssertEqual(try repair.recoverAtLaunch(), .restored)
        XCTAssertNil(f.defaults.data(forKey: key))
        let point = try BackupCodec.read(XCTUnwrap(BackupRecovery(library: f.library).points().first?.url))
        XCTAssertNotNil(point.damage)
        let originals = try XCTUnwrap(PropertyListSerialization.propertyList(from: point.preferences, format: nil) as? [String: Any])
        XCTAssertEqual(originals[key] as? Data, corrupt)
    }
    func testBoostWrongTypesAndNoncanonicalOriginsCannotReachRestore() throws {
        let source = try fixture()
        let key = SiteBoostStore.key(source.seed().active.id)
        for value: Any in ["not encoded records", try JSONEncoder().encode(["https://example.test/path": SiteBoost()])] {
            let target = try fixture(), before = try target.library.capture(reason: .manual)
            source.defaults.set(value, forKey: key)
            let encodedPreferences = try source.library.currentPreferences()
            let bad = BackupArchive(preferences: encodedPreferences, files: try source.library.capture(reason: .beforeRestore, allowDamaged: true).files)
            XCTAssertThrowsError(try BackupRestore(library: target.library).prepare(bad))
            XCTAssertEqual(try target.library.capture(reason: .manual).files, before.files)
            XCTAssertEqual(try preferences(target.library.currentPreferences()), try preferences(before.preferences))
        }
    }
    func testControllerStorageAndCorruptInputFailuresPreservePopulatedLibraryAndReportFeedback() async throws {
        let f = try fixture(); _ = try await populate(f)
        let before = try f.library.capture(reason: .manual)
        var restarts = 0
        let controller = BackupController(library: f.library, flush: { true }, restart: { restarts += 1 })
        let bad = f.root.appendingPathComponent("broken.vanebackup")
        try Data("bad input".utf8).write(to: bad)
        await controller.previewRestore(from: bad)
        XCTAssertNil(controller.preview); XCTAssertTrue(controller.error?.contains("could not be read") == true)
        let unavailable = f.root.appendingPathComponent("unavailable")
        try Data("not a directory".utf8).write(to: unavailable)
        await controller.export(to: unavailable.appendingPathComponent("export.vanebackup"))
        XCTAssertNotNil(controller.error); XCTAssertFalse(controller.busy)
        let good = f.root.appendingPathComponent("good.vanebackup")
        try BackupCodec.write(before, to: good)
        await controller.previewRestore(from: good)
        XCTAssertNotNil(controller.preview)
        try Data("blocked recovery storage".utf8).write(to: f.root.appendingPathComponent("Recovery"))
        await controller.restorePreview()
        XCTAssertTrue(controller.error?.contains("regular directory") == true)
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(try f.library.capture(reason: .manual).files, before.files)
        XCTAssertEqual(try preferences(f.library.currentPreferences()), try preferences(before.preferences))
    }
    func testUnavailableStorageSaveFailuresKeepLastSnapshotsAndCanRetry() async throws {
        let f = try fixture(), inventory = try await populate(f), manager = f.seed()
        let before = try f.library.capture(reason: .manual)
        let profile = inventory.profiles[0].id
        let templates = WorkspaceTemplates(manager: manager)
        let easels = EaselStore(profileID: profile, directory: f.root)
        let queue = try ReadingQueueStore(profileID: profile, directory: f.root)
        await queue.waitUntilReady()
        let parked = f.root.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: f.root, to: parked)
        defer {
            if FileManager.default.fileExists(atPath: parked.path) {
                try? FileManager.default.removeItem(at: f.root)
                try? FileManager.default.moveItem(at: parked, to: f.root)
            }
        }
        try Data("unmounted storage placeholder".utf8).write(to: f.root)
        XCTAssertThrowsError(try templates.rename(inventory.templates[0].id, profile: profile, name: "Lost"))
        var changed = inventory.boards[0]; changed.title = "Lost"
        XCTAssertThrowsError(try easels.save(changed))
        XCTAssertNotNil(easels.error); XCTAssertEqual(easels.boards, [inventory.boards[0]])
        do { try await queue.setRead(true, id: inventory.articles[0].article.id); XCTFail("Unavailable article storage must fail") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(queue.articles, [inventory.articles[0].article])
        try FileManager.default.removeItem(at: f.root)
        try FileManager.default.moveItem(at: parked, to: f.root)
        XCTAssertEqual(try f.library.capture(reason: .manual).files, before.files)
        try await assertInventory(inventory, in: f)
        try templates.rename(inventory.templates[0].id, profile: profile, name: "Retry")
        changed.title = "Retry"; try easels.save(changed)
        try await queue.setRead(true, id: inventory.articles[0].article.id)
        XCTAssertEqual(try templates.load(profile: profile).first?.name, "Retry")
        XCTAssertEqual(EaselStore(profileID: profile, directory: f.root).boards.first?.title, "Retry")
        let reopened = try ReadingQueueStore(profileID: profile, directory: f.root)
        await reopened.waitUntilReady(); XCTAssertEqual(reopened.articles.first?.isRead, true)
    }
    func testCrossProfileEaselReferenceIsRejectedWithoutChangingCurrentLibrary() async throws {
        let source = try fixture(), inventory = try await populate(source), target = try fixture()
        let before = try target.library.capture(reason: .manual)
        let original = try source.library.capture(reason: .manual)
        for boardFile in original.files.filter({ $0.name.hasPrefix("easels-") }) {
            var broken = original
            broken.files.removeAll { $0.name == boardFile.name }
            XCTAssertThrowsError(try BackupRestore(library: target.library).prepare(broken)) { error in
                XCTAssertTrue(error.localizedDescription.contains("missing Easel"))
            }
        }
        let profile = inventory.profiles[0].id
        var space = inventory.spaces[0]
        space.layout = nil
        space.tabURLs = [EaselAddress.url(inventory.boards[1].id)]
        var broken = original
        let name = ProfileManager.spacesURL(for: profile, in: source.root).lastPathComponent
        let index = try XCTUnwrap(broken.files.firstIndex { $0.name == name })
        broken.files[index] = .init(name: name, data: try JSONEncoder().encode([space]))
        XCTAssertThrowsError(try BackupRestore(library: target.library).prepare(broken))
        XCTAssertEqual(try target.library.capture(reason: .manual).files, before.files)
        XCTAssertEqual(try preferences(target.library.currentPreferences()), try preferences(before.preferences))
    }
    func testPrivateFeatureActionsDoNotChangeBackupInventory() async throws {
        let f = try fixture(), manager = f.seed()
        let before = try f.library.capture(reason: .manual)
        XCTAssertThrowsError(try ReadingQueueStore(profileID: Profile.incognito.id, directory: f.root))
        XCTAssertThrowsError(try WorkspaceTemplates(manager: manager).save(name: "Private",
            space: Space(name: "Private", profileID: Profile.incognito.id),
            layout: SpaceLayout(tabs: [], pins: Pins(), today: Pins(), splits: [], selected: nil), unlocked: []))
        // The runtime's own isolated defaults domain must remain untouched by private Boosts.
        let domain = UserDefaults.vaneDomain
        let settings = UserDefaults.vane.persistentDomain(forName: domain) ?? [:]
        let tab = Tab(isPrivate: true), other = Tab(isPrivate: true)
        defer { tab.tearDown(); other.tearDown() }
        var boost = SiteBoost(); boost.css = "body { color: red }"; boost.scriptEnabled = true
        SiteBoosts.set(boost, origin: "https://example.test", tab: tab)
        XCTAssertEqual(SiteBoosts.value(origin: "https://example.test", tab: other), SiteBoost())
        XCTAssertEqual(UserDefaults.vane.persistentDomain(forName: domain) as NSDictionary? ?? [:], settings as NSDictionary)
        tab.tearDown()
        XCTAssertEqual(SiteBoosts.value(origin: "https://example.test", tab: tab), SiteBoost())
        XCTAssertEqual(try f.library.capture(reason: .manual).files, before.files)
        XCTAssertEqual(try preferences(f.library.currentPreferences()), try preferences(before.preferences))
    }
}
