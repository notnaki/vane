import Darwin
import XCTest
@testable import vane

@MainActor final class BlockerLocalSourceTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let domain = "vane-linked-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        return (root, defaults)
    }

    func testExplicitLinkRefreshReplacementDisappearanceAndRelaunch() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try "||first.example^".write(to: file, atomically: true, encoding: .utf8)
        let manager = LocalFilterSources(defaults: defaults, directory: root)
        await manager.refreshAll()
        XCTAssertTrue(manager.items.isEmpty, "Reading a file never links it implicitly")
        try await manager.link(file)
        let id = try XCTUnwrap(manager.items.first?.id)
        let first = manager.items[0]
        await manager.refresh(id)
        XCTAssertEqual(manager.items[0].text, first.text)
        try "||replacement.example^".write(to: file, atomically: true, encoding: .utf8)
        await manager.refresh(id)
        XCTAssertEqual(manager.items[0].text, "||replacement.example^")
        try FileManager.default.removeItem(at: file)
        await manager.refresh(id)
        XCTAssertEqual(manager.items[0].text, "||replacement.example^")
        XCTAssertNotNil(manager.items[0].lastError)
        let relaunched = LocalFilterSources(defaults: defaults, directory: root)
        await relaunched.load()
        XCTAssertEqual(relaunched.items, manager.items)
        try "||repaired.example^".write(to: file, atomically: true, encoding: .utf8)
        await relaunched.refresh(id)
        XCTAssertEqual(relaunched.items[0].text, "||repaired.example^")
        XCTAssertNil(relaunched.items[0].lastError)
    }

    func testInvalidUpdatesAndCompilerFailuresKeepOwnedSnapshot() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        var reject = false
        let manager = LocalFilterSources(defaults: defaults, directory: root, validate: { _ in
            if reject { throw BlockerFiles.Failure("Compiler rejected complete candidate") }
        })
        try await manager.link(file)
        let id = manager.items[0].id
        for bad in [Data([0xff]), Data(repeating: 65, count: BlockerFiles.sourceByteLimit + 1), Data("! empty".utf8), Data("<html>error</html>".utf8), Data("||x.example^\n!#if missing".utf8)] {
            try bad.write(to: file, options: .atomic)
            await manager.refresh(id)
            XCTAssertEqual(manager.items[0].text, "||good.example^")
            XCTAssertNotNil(manager.items[0].lastError)
        }
        reject = true
        try Data("||new.example^".utf8).write(to: file, options: .atomic)
        await manager.refresh(id)
        XCTAssertEqual(manager.items[0].text, "||good.example^")
        await manager.remove(id)
        XCTAssertEqual(manager.items.count, 1, "Removal must compile the remaining complete policy")
        await manager.setEnabled(id, enabled: false)
        XCTAssertTrue(manager.items[0].enabled)
        let saved = try LocalFilterSources.read(defaults: defaults)
        XCTAssertEqual(saved[0].text, "||good.example^")
    }

    func testDisabledRefreshAndDisabledRulesRemovalAndSaveFailure() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        var failSave = false
        let manager = LocalFilterSources(defaults: defaults, directory: root, persist: { items in
            if failSave { throw BlockerFiles.Failure("Disk full") }
            try LocalFilterSources.write(items, defaults: defaults)
        })
        try await manager.link(file)
        let id = manager.items[0].id
        await manager.setAutomaticUpdates(id, enabled: false)
        try Data("||new.example^".utf8).write(to: file, options: .atomic)
        await manager.refreshAll()
        XCTAssertEqual(manager.items[0].text, "||good.example^")
        await manager.refresh(id) // Explicit retry still works with automatic updates off.
        XCTAssertEqual(manager.items[0].text, "||new.example^")
        await manager.setEnabled(id, enabled: false)
        XCTAssertFalse(manager.items[0].enabled)
        try Data("||later.example^".utf8).write(to: file, options: .atomic)
        failSave = true
        await manager.refresh(id)
        XCTAssertEqual(manager.items[0].text, "||new.example^")
        XCTAssertNotNil(manager.storageError)
        failSave = false
        await manager.remove(id)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try LocalFilterSources.read(defaults: defaults).isEmpty)
    }

    func testBackupCarriesSnapshotWithoutAccessGrantAndRelinkRecovers() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root.appendingPathComponent("grants"))
        try await manager.link(file)
        let data = try XCTUnwrap(defaults.data(forKey: LocalFilterSources.snapshotsKey))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(file.path))
        // Restore only portable preferences, never the deliberately unowned grant directory.
        let restored = LocalFilterSources(defaults: defaults, directory: root.appendingPathComponent("fresh-grants"))
        await restored.load()
        let id = restored.items[0].id
        await restored.refresh(id)
        XCTAssertEqual(restored.items[0].text, "||good.example^")
        XCTAssertNotNil(restored.items[0].lastError)
        try await restored.link(file, replacing: id)
        XCTAssertEqual(restored.items[0].id, id)
        XCTAssertNil(restored.items[0].lastError)
        XCTAssertFalse(BackupPaths.isOwned("LocalFilterSources/grants.json"))
    }

    func testCorruptSnapshotsCannotBeSilentlyOverwritten() async throws {
        let (root, defaults) = try fixture()
        defaults.set(Data("broken".utf8), forKey: LocalFilterSources.snapshotsKey)
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root)
        do { try await manager.link(file); XCTFail("Must preserve corrupt storage") } catch { }
        XCTAssertEqual(defaults.data(forKey: LocalFilterSources.snapshotsKey), Data("broken".utf8))
    }
}

extension BlockerLocalSourceTests {
    func testCorruptGrantRequiresRelinkWithoutLosingSnapshot() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root)
        try await manager.link(file)
        let accepted = manager.items[0]
        try Data("stale grant".utf8).write(to: root.appendingPathComponent(accepted.grantID.uuidString + ".json"))
        await manager.refresh(accepted.id)
        XCTAssertEqual(manager.items[0].text, accepted.text)
        XCTAssertTrue(manager.items[0].lastError?.contains("Relink") == true)
        try await manager.link(file, replacing: accepted.id)
        XCTAssertNil(manager.items[0].lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(accepted.grantID.uuidString + ".json").path))
    }

    func testNonRegularReplacementsFailPromptlyWithoutBlockingMainActor() async throws {
        let (root, _) = try fixture()
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let rejected = await Task.detached(priority: .utility) {
            XCTAssertFalse(Thread.isMainThread)
            do { _ = try LocalFilterSources.readRegularText(fifo); return false }
            catch { return true }
        }.value
        XCTAssertTrue(rejected)
    }

    func testConcurrentRefreshRemovalCannotResurrectSource() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root)
        try await manager.link(file)
        let id = manager.items[0].id
        try Data("||new.example^".utf8).write(to: file, options: .atomic)
        let refreshing = Task { await manager.refresh(id) }
        let removal = Task { await manager.remove(id) }
        await refreshing.value; await removal.value
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try LocalFilterSources.read(defaults: defaults).isEmpty)
    }
}

extension BlockerLocalSourceTests {
    func testPortableBackupPreferencesIncludeAcceptedTextButNeverBookmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "vane-linked-backup-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("filters.txt")
        try Data("||saved.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root.appendingPathComponent("LocalFilterSources"))
        try await manager.link(file)
        let library = BackupLibrary(directory: root, defaults: defaults, domain: domain)
        let prefs = try XCTUnwrap(PropertyListSerialization.propertyList(from: library.currentPreferences(), format: nil) as? [String: Any])
        XCTAssertEqual(prefs[LocalFilterSources.snapshotsKey] as? Data, defaults.data(forKey: LocalFilterSources.snapshotsKey))
        XCTAssertTrue(try library.ownedNames().isEmpty)
        let portable = try XCTUnwrap(prefs[LocalFilterSources.snapshotsKey] as? Data)
        XCTAssertFalse(String(decoding: portable, as: UTF8.self).contains("bookmark"))
        XCTAssertFalse(String(decoding: portable, as: UTF8.self).contains(file.path))
    }
}

extension BlockerLocalSourceTests {
    func testWrongTypedStoreCannotBecomeAnEmptyPolicy() async throws {
        let (root, defaults) = try fixture()
        defaults.set("damaged snapshot document", forKey: LocalFilterSources.snapshotsKey)
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root)
        do { try await manager.link(file); XCTFail("Must refuse corrupted storage") } catch { }
        XCTAssertEqual(defaults.string(forKey: LocalFilterSources.snapshotsKey), "damaged snapshot document")
    }

    func testSnapshotStorageAdmissionIncludesDisabledSources() throws {
        let (_, defaults) = try fixture()
        let text = String(repeating: "a", count: BlockerFiles.sourceByteLimit)
        var source = LocalFilterSource(name: "large.txt", text: text, enabled: false, report: .init())
        var sources: [LocalFilterSource] = []
        for _ in 0..<9 { source.id = UUID(); sources.append(source) }
        XCTAssertThrowsError(try LocalFilterSources.write(sources, defaults: defaults))
        XCTAssertNil(defaults.data(forKey: LocalFilterSources.snapshotsKey))
    }
}

extension BlockerLocalSourceTests {
    func testLinkAndRefreshReadActualFilesOffMainThread() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||first.example^".utf8).write(to: file)
        let reads = LocalSourceReadCounter()
        let manager = LocalFilterSources(defaults: defaults, directory: root, readSource: { file in
            XCTAssertFalse(Thread.isMainThread, "Source I/O must never run on the UI thread")
            reads.increment()
            return try LocalFilterSources.readRegularText(file)
        })
        try await manager.link(file)
        try Data("||changed.example^".utf8).write(to: file, options: .atomic)
        await manager.refresh(manager.items[0].id)
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(manager.items[0].text, "||changed.example^")
    }
}

private final class LocalSourceReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

extension BlockerLocalSourceTests {
    func testPausingRefreshSavesMetadataEvenWhenUnrelatedPolicyCannotCompile() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        try Data("||good.example^".utf8).write(to: file)
        var reject = false
        let manager = LocalFilterSources(defaults: defaults, directory: root, validate: { _ in
            if reject { throw BlockerFiles.Failure("Another source is unavailable") }
        })
        try await manager.link(file)
        let id = manager.items[0].id
        reject = true
        await manager.setAutomaticUpdates(id, enabled: false)
        XCTAssertFalse(manager.items[0].automaticUpdates)
        XCTAssertFalse(try LocalFilterSources.read(defaults: defaults)[0].automaticUpdates)
        XCTAssertEqual(manager.items[0].text, "||good.example^")
        XCTAssertNil(manager.storageError)
    }
}

extension BlockerLocalSourceTests {
    func testMovedScopedReferencePreservesSnapshotAndCanBeExplicitlyRelinked() async throws {
        let (root, defaults) = try fixture()
        let file = root.appendingPathComponent("filters.txt")
        let moved = root.appendingPathComponent("moved.txt")
        try Data("||original.example^".utf8).write(to: file)
        let manager = LocalFilterSources(defaults: defaults, directory: root)
        try await manager.link(file)
        let id = manager.items[0].id
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("||moved.example^".utf8).write(to: moved, options: .atomic)
        await manager.refresh(id)
        XCTAssertEqual(manager.items[0].text, "||original.example^")
        XCTAssertNotNil(manager.items[0].lastError)
        try await manager.link(moved, replacing: id)
        XCTAssertEqual(manager.items[0].text, "||moved.example^")
        XCTAssertNil(manager.items[0].lastError)
    }
}
