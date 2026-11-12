import AppKit
import XCTest
import SQLite3
@testable import vane

@MainActor final class ICloudLibraryAdapterTests: XCTestCase {
    private func fixture(_ name: String = UUID().uuidString) throws -> (URL, UserDefaults, ProfileManager, ICloudLibraryAdapter) {
        TestEnvironment.prepare()
        // Pending browsing writes rebuild menus; admit AppKit before exercising replay.
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vane-icloud-library-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "vane.library.\(UUID())")!
        let manager = ProfileManager(directory: dir, sandboxed: true)
        return (dir, defaults, manager, ICloudLibraryAdapter(directory: dir, defaults: defaults, deviceID: name, profiles: manager))
    }

    func testProfilesKeepIdentityAndChildOnlyDoesNotLeakNames() async throws {
        let (_, _, manager, adapter) = try fixture()
        let one = manager.create(name: "Secret work"), two = manager.create(name: "Secret work")
        let space = manager.createSpace(name: "Secret space", in: one.id)
        var changed = space; changed.pinnedTabURLs = [URL(string: "https://example.com")!]
        XCTAssertTrue(manager.updateSpace(changed))
        let all = try await adapter.capture([.profiles, .spaces])
        XCTAssertTrue(all.contains { $0.id == one.id.uuidString && $0.category == .profiles })
        XCTAssertTrue(all.contains { $0.id == two.id.uuidString && $0.category == .profiles })
        let child = try await adapter.capture([.pinnedTabs])
        XCTAssertFalse(child.contains { $0.category == .profiles || $0.category == .spaces })
        XCTAssertFalse(child.flatMap { $0.fields.values }.contains { String(decoding: $0, as: UTF8.self).contains("Secret") })
        let (_, _, targetManager, target) = try fixture()
        try await target.apply(child, deleted: [], enabled: [.pinnedTabs])
        XCTAssertEqual(targetManager.profiles.first { $0.id == one.id }?.name, "Synced profile")
        XCTAssertEqual(targetManager.spaces(for: one.id).first { $0.id == space.id }?.name, "Synced Space")
        let placeholders = try await target.capture([.profiles, .spaces])
        XCTAssertFalse(placeholders.contains { $0.id == one.id.uuidString || $0.id == space.id.uuidString })
        try await target.apply(all, deleted: [], enabled: [.profiles, .spaces])
        XCTAssertEqual(targetManager.profiles.first { $0.id == one.id }?.name, "Secret work")
        XCTAssertEqual(targetManager.spaces(for: one.id).first { $0.id == space.id }?.name, "Secret space")
    }
    func testCancelledApplyCannotCreateOrRenameProfiles() async throws {
        let (_, _, sourceManager, source) = try fixture()
        _ = sourceManager.create(name: "Remote")
        let items = try await source.capture([.profiles])
        let (_, _, targetManager, target) = try fixture()
        let before = targetManager.profiles
        let task = Task { @MainActor in try await target.apply(items, deleted: [], enabled: [.profiles]) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled remote work must not mutate local profiles") } catch is CancellationError { }
        XCTAssertEqual(targetManager.profiles, before)
    }

    func testBookmarksDeduplicatePerProfileAndRetainStableIdentity() async throws {
        let (_, _, manager, adapter) = try fixture()
        let id = manager.profiles[0].id
        let store = adapter.localStore(for: id)
        _ = store.addBookmarks([(URL(string: "https://example.com")!, "Local")])
        let before = try await adapter.capture([.bookmarks])
        var remote = try XCTUnwrap(before.first { $0.fields["url"] != nil })
        remote.id = UUID().uuidString
        remote.fields["title"] = try JSONEncoder().encode("Remote")
        try await adapter.apply([remote], deleted: [], enabled: [.bookmarks])
        XCTAssertEqual(store.managedBookmarks().count, 1)
        XCTAssertEqual(store.managedBookmarks().first?.title, "Remote")
        let after = try await adapter.capture([.bookmarks])
        XCTAssertEqual(after.filter { $0.fields["url"] != nil }.count, 1)
        XCTAssertEqual(after.first { $0.fields["url"] != nil }?.id, min(before[0].id, remote.id))
        let winner = try XCTUnwrap(after.first { $0.fields["url"] != nil })
        let loser = winner.id == remote.id ? before[0] : remote
        try await adapter.apply([], deleted: [loser], enabled: [.bookmarks])
        XCTAssertEqual(store.managedBookmarks().count, 1, "Retiring a duplicate must preserve the surviving bookmark")
        try await adapter.apply([], deleted: [winner], enabled: [.bookmarks])
        try await adapter.apply([before[0], remote], deleted: [], enabled: [.bookmarks])
        XCTAssertTrue(store.managedBookmarks().isEmpty, "Retired duplicate aliases cannot resurrect a deleted bookmark")
    }

    func testOtherDeviceTabsNeverChangeLocalSession() async throws {
        let (dir, _, manager, adapter) = try fixture("other")
        let id = manager.profiles[0].id
        let sessionURL = ProfileManager.sessionURL(for: id, in: dir)
        let bytes = try XCTUnwrap(Session.encode([[.init(id: UUID().uuidString, url: "https://remote.example", title: "Remote")]]))
        try bytes.write(to: sessionURL)
        let items = try await adapter.capture([.openTabs])
        let (localDir, _, localManager, local) = try fixture("local")
        let localFile = ProfileManager.sessionURL(for: localManager.profiles[0].id, in: localDir)
        let localBytes = try XCTUnwrap(Session.encode([[.init(url: "https://local.example")]]))
        try localBytes.write(to: localFile)
        try local.setAccountNamespace("first-account")
        try await local.apply(items, deleted: [], enabled: [.openTabs])
        XCTAssertEqual(try Data(contentsOf: localFile), localBytes)
        XCTAssertEqual(local.remoteTabs.first?.url.absoluteString, "https://remote.example")
        XCTAssertEqual(local.remoteTabs.first?.deviceID, "other")
        try local.setAccountNamespace("second-account")
        XCTAssertTrue(local.remoteTabs.isEmpty)
        let secondAccount = try await local.capture([.openTabs])
        XCTAssertFalse(secondAccount.contains { $0.id == items.first?.id })
        try local.setAccountNamespace("first-account")
        XCTAssertEqual(local.remoteTabs.first?.deviceID, "other")
    }

    func testCompletedDownloadMetadataOmitsLocalCapabilities() async throws {
        let (dir, _, manager, adapter) = try fixture("other")
        var record = Downloads.Record(name: "example.zip", destination: URL(fileURLWithPath: "/secret/path/example.zip"), source: URL(string: "https://example.com/file"), total: 30, received: 30, state: "done")
        record.completed = Date(); record.destinationBookmark = Data("secret grant".utf8); record.resumeFile = "secret-resume"
        try JSONEncoder().encode([record]).write(to: Downloads.listURL(for: manager.profiles[0].id, in: dir))
        let items = try await adapter.capture([.downloadHistory])
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(Set(items[0].fields.keys).isDisjoint(with: ["destination", "destinationBookmark", "resumeFile", "resumeData"]))
        let (_, _, _, local) = try fixture("local")
        try await local.apply(items, deleted: [], enabled: [.downloadHistory])
        XCTAssertEqual(local.remoteDownloads.first?.name, "example.zip")
        XCTAssertEqual(local.remoteDownloads.first?.deviceID, "other")
    }

    func testFolderProtectionAndIndependentSpaceFieldsSurviveImport() async throws {
        let (_, defaults, manager, adapter) = try fixture()
        let pid = manager.profiles[0].id
        let space = manager.createSpace(name: "Local name", in: pid)
        var folder = Folder(name: "Protected"); folder.requiresAuthentication = true
        let shape = Pins(entries: [.init(row: .folder(folder), parent: nil)])
        defaults.set(try JSONEncoder().encode(shape), forKey: TabStore.shapeKey(.pinned, space: space.id, profileID: pid))
        var folders = try await adapter.capture([.sidebarFolders])
        XCTAssertEqual(folders.count, 1)
        folders[0].fields["requiresAuthentication"] = try JSONEncoder().encode(false)
        folders[0].fields["name"] = try JSONEncoder().encode("Renamed")
        try await adapter.apply(folders, deleted: [], enabled: [.sidebarFolders])
        let saved = try JSONDecoder().decode(Pins.self, from: XCTUnwrap(defaults.data(forKey: TabStore.shapeKey(.pinned, space: space.id, profileID: pid))))
        XCTAssertEqual(saved.folder(folder.id)?.name, "Renamed")
        XCTAssertEqual(saved.folder(folder.id)?.requiresAuthentication, true)
        let colorPatch = ICloudItem(category: .spaces, id: space.id.uuidString, profileID: pid, parentID: nil,
            fields: ["colorHex": try JSONEncoder().encode("#FF0000")])
        try await adapter.apply([colorPatch], deleted: [], enabled: [.spaces])
        let updated = try XCTUnwrap(manager.spaces(for: pid).first)
        XCTAssertEqual(updated.name, "Local name")
        XCTAssertEqual(updated.colorHex, "#FF0000")
    }

    func testIncomingPinIdentitySurvivesCaptureAndDisabledParentDeletion() async throws {
        let (_, _, manager, adapter) = try fixture()
        let profile = manager.create(name: "Other")
        let space = manager.createSpace(name: "Work", in: profile.id)
        let pin = ICloudItem(category: .pinnedTabs, id: UUID().uuidString, profileID: profile.id, parentID: space.id.uuidString,
            fields: ["url": try JSONEncoder().encode(URL(string: "https://example.com")!), "position": try JSONEncoder().encode(0), "title": try JSONEncoder().encode("Example")])
        try await adapter.apply([pin], deleted: [], enabled: [.pinnedTabs])
        let recaptured = try await adapter.capture([.pinnedTabs])
        XCTAssertTrue(recaptured.contains { $0.id == pin.id })
        let parent = ICloudItem(category: .profiles, id: profile.id.uuidString, profileID: profile.id, parentID: nil, fields: [:])
        try await adapter.apply([], deleted: [parent], enabled: [.profiles])
        try await adapter.apply([pin], deleted: [], enabled: [.pinnedTabs])
        XCTAssertFalse(manager.profiles.contains { $0.id == profile.id })
    }

    func testRevocationWhileSQLiteWriterIsLockedLeavesEveryRemoteMutationUncommitted() async throws {
        for operation in ["insert", "update", "delete", "folder"] {
            let (directory, _, manager, adapter) = try fixture()
            let pid = manager.profiles[0].id
            let store = adapter.localStore(for: pid)
            _ = store.addBookmarks([(URL(string: "https://local.example")!, "Local")])
            let before = try await store.captureICloud([.bookmarks], profile: pid)
            var item = try XCTUnwrap(before.first)
            if operation == "insert" {
                item.id = UUID().uuidString
                item.fields["url"] = try JSONEncoder().encode("https://remote.example")
            } else if operation == "folder" {
                item = ICloudItem(category: .bookmarks, id: "folder:" + UUID().uuidString, profileID: pid, parentID: nil,
                    fields: ["name": try JSONEncoder().encode("Remote folder"), "position": try JSONEncoder().encode(0)])
            } else { item.fields["title"] = try JSONEncoder().encode("Remote") }
            var lock: OpaquePointer?
            XCTAssertEqual(sqlite3_open(ProfileManager.dbURL(for: pid, in: directory).path, &lock), SQLITE_OK)
            defer { sqlite3_close(lock) }
            XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
            let admission = ICloudAdmission()
            let incoming = item
            let task = Task { @MainActor in
                try await ICloudApplyContext.$admission.withValue(admission) {
                    try await store.applyICloud(incoming, deleting: operation == "delete")
                }
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while !store.hasPendingWrites, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertTrue(store.hasPendingWrites, "Sync must have reached its actual native writer")
            try await Task.sleep(for: .milliseconds(30))
            admission.revoke()
            // Folder insertion proves the captured lease rejects work even without
            // Task cancellation; the other cases exercise both revocation paths.
            if operation != "folder" { task.cancel() }
            XCTAssertEqual(sqlite3_exec(lock, "COMMIT", nil, nil, nil), SQLITE_OK)
            do { try await task.value; XCTFail("Revoked \(operation) must fail before native commit") }
            catch is CancellationError { }
            let after = try await store.captureICloud([.bookmarks], profile: pid)
            XCTAssertEqual(Set(after.map(\.key)), Set(before.map(\.key)), operation)
            XCTAssertEqual(after.first?.fields, before.first?.fields, operation)
        }
    }

    func testNativeApplyKeepsLateLocalBookmarkFieldAndMergesIndependentRemoteField() async throws {
        let (_, _, manager, adapter) = try fixture()
        let pid = manager.profiles[0].id
        let store = adapter.localStore(for: pid)
        _ = store.addBookmarks([(URL(string: "https://original.example")!, "Original")])
        let snapshot = try await store.captureICloud([.bookmarks], profile: pid)
        let original = try XCTUnwrap(snapshot.first)
        let mark = try XCTUnwrap(store.managedBookmarks().first)
        XCTAssertTrue(store.updateBookmark(mark.id, url: URL(string: mark.url)!, title: "Late local title", folderID: nil))
        var remote = original
        remote.fields["title"] = try JSONEncoder().encode("Remote title")
        remote.fields["url"] = try JSONEncoder().encode("https://remote.example")
        try await ICloudApplyContext.$baseline.withValue([original.key: original]) {
            try await store.applyICloud(remote, deleting: false)
        }
        let merged = try XCTUnwrap(store.managedBookmarks().first)
        XCTAssertEqual(merged.title, "Late local title")
        XCTAssertEqual(merged.url, "https://remote.example")
    }

    func testLocalTitleQueuedDuringLockedRemoteApplyDoesNotUndoIndependentRemoteURL() async throws {
        let (directory, _, manager, adapter) = try fixture()
        let pid = manager.profiles[0].id
        let store = adapter.localStore(for: pid)
        _ = store.addBookmarks([(URL(string: "https://original.example")!, "Original")])
        let snapshot = try await store.captureICloud([.bookmarks], profile: pid)
        let original = try XCTUnwrap(snapshot.first), mark = try XCTUnwrap(store.managedBookmarks().first)
        var remote = original
        remote.fields["url"] = try JSONEncoder().encode("https://remote.example")
        remote.fields["title"] = try JSONEncoder().encode("Remote title")
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(ProfileManager.dbURL(for: pid, in: directory).path, &lock), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        let incoming = remote
        let task = Task { @MainActor in
            try await ICloudApplyContext.$baseline.withValue([original.key: original]) {
                try await store.applyICloud(incoming, deleting: false)
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !store.hasPendingWrites, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(store.hasPendingWrites)
        XCTAssertTrue(store.updateBookmark(mark.id, url: URL(string: mark.url)!, title: "Late local title", folderID: nil))
        XCTAssertEqual(sqlite3_exec(lock, "COMMIT", nil, nil, nil), SQLITE_OK)
        try await task.value
        let merged = try XCTUnwrap(store.managedBookmarks().first)
        XCTAssertEqual(merged.title, "Late local title")
        XCTAssertEqual(merged.url, "https://remote.example")
    }

    func testMovingActualSpacePreservesPinsAndFoldersAfterOldProfileTombstone() async throws {
        let (_, defaults, manager, adapter) = try fixture()
        let source = manager.profiles[0].id
        let destination = manager.create(name: "Destination").id
        var space = manager.createSpace(name: "Work", in: source)
        space.pinnedTabURLs = [URL(string: "https://pin.example")!]
        XCTAssertTrue(manager.updateSpace(space))
        var folder = Folder(name: "Protected folder"); folder.requiresAuthentication = true
        defaults.set(try JSONEncoder().encode(Pins(entries: [
            .init(row: .folder(folder), parent: nil), .init(row: .tab("https://pin.example"), parent: folder.id)
        ])), forKey: TabStore.shapeKey(.pinned, space: space.id, profileID: source))
        let enabled: Set<ICloudCategory> = [.profiles, .spaces, .pinnedTabs, .sidebarFolders]
        let before = try await adapter.capture(enabled)
        let inventoryBefore = try await adapter.ancestorInventory()
        XCTAssertTrue(inventoryBefore.contains { $0.kind == .space && $0.profileID == source && $0.id == space.id.uuidString })
        let (_, _, targetManager, target) = try fixture()
        try await target.apply(before, deleted: [], enabled: enabled)
        XCTAssertNotNil(manager.moveSpace(space.id, from: source, to: destination, defaults: defaults))
        let after = try await adapter.capture(enabled)
        let inventoryAfter = try await adapter.ancestorInventory()
        XCTAssertFalse(inventoryAfter.contains { $0.kind == .space && $0.profileID == source && $0.id == space.id.uuidString })
        XCTAssertTrue(inventoryAfter.contains { $0.kind == .space && $0.profileID == destination && $0.id == space.id.uuidString })
        let keys = Set(after.map(\.key))
        let removed = before.filter { !keys.contains($0.key) }
        XCTAssertTrue(removed.contains { $0.category == .spaces && $0.profileID == source })
        try target.applyAncestorFences([ICloudDeletionFence(kind: .space, profileID: source, id: space.id.uuidString)], enabled: enabled)
        try await target.apply(after, deleted: removed, enabled: enabled)
        XCTAssertFalse(targetManager.spaces(for: source).contains { $0.id == space.id })
        let moved = try XCTUnwrap(targetManager.spaces(for: destination).first { $0.id == space.id })
        XCTAssertEqual(moved.pinnedTabURLs, [URL(string: "https://pin.example")!])
        XCTAssertEqual(moved.layout?.pins.folder(folder.id)?.name, "Protected folder")
        XCTAssertEqual(moved.layout?.pins.folder(folder.id)?.requiresAuthentication, true)
        let captured = try await target.capture(enabled)
        XCTAssertTrue(captured.contains { $0.category == .pinnedTabs && $0.profileID == destination })
        XCTAssertTrue(captured.contains { $0.category == .sidebarFolders && $0.profileID == destination && $0.id == folder.id.uuidString })
    }

    func testOpaqueProfileDeletionFenceDeletesSelectedChildrenAndPreservesDisabledParents() async throws {
        let (_, _, manager, adapter) = try fixture()
        let profile = manager.create(name: "Local profile")
        var space = manager.createSpace(name: "Local Space", in: profile.id)
        space.pinnedTabURLs = [URL(string: "https://keep-pin.example")!]
        XCTAssertTrue(manager.updateSpace(space))
        let store = adapter.localStore(for: profile.id)
        _ = store.addBookmarks([(URL(string: "https://remove-bookmark.example")!, "Bookmark")])
        let children = try await adapter.capture([.bookmarks])
        let selected = children.filter { $0.profileID == profile.id }
        try adapter.applyAncestorFences([ICloudDeletionFence(kind: .profile, profileID: profile.id, id: profile.id.uuidString)], enabled: [.bookmarks])
        try await adapter.apply([], deleted: selected, enabled: [.bookmarks])
        XCTAssertTrue(store.managedBookmarks().isEmpty)
        XCTAssertEqual(manager.profiles.first { $0.id == profile.id }?.name, "Local profile")
        XCTAssertEqual(manager.spaces(for: profile.id).first?.name, "Local Space")
        XCTAssertEqual(manager.spaces(for: profile.id).first?.pinnedTabURLs, space.pinnedTabURLs)
        try await adapter.apply(selected, deleted: [], enabled: [.bookmarks])
        XCTAssertTrue(store.managedBookmarks().isEmpty)
    }

    func testKnownBaselineEntitiesDeletedLocallyAreNotRecreatedByStaleApply() async throws {
        let (_, defaults, manager, adapter) = try fixture()
        let pid = manager.profiles[0].id
        var space = manager.createSpace(name: "Delete locally", in: pid)
        space.pinnedTabURLs = [URL(string: "https://pin.example")!]
        XCTAssertTrue(manager.updateSpace(space))
        defaults.set(["https://favourite.example"], forKey: TabStore.defaultsKey(.favourite, pid))
        let store = adapter.localStore(for: pid)
        _ = store.addBookmarks([(URL(string: "https://bookmark.example")!, "Bookmark")])
        let enabled: Set<ICloudCategory> = [.spaces, .pinnedTabs, .favourites, .bookmarks]
        let baseline = try await adapter.capture(enabled)
        XCTAssertTrue(store.deleteBookmarks(Set(store.managedBookmarks().map(\.id))))
        XCTAssertTrue(manager.deleteSpace(space.id, in: pid))
        defaults.set([], forKey: TabStore.defaultsKey(.favourite, pid))
        try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })) {
            try await adapter.apply(baseline, deleted: [], enabled: enabled)
        }
        XCTAssertTrue(store.managedBookmarks().isEmpty)
        XCTAssertTrue(manager.spaces(for: pid).isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: TabStore.defaultsKey(.favourite, pid)), [])
        XCTAssertFalse(try manager.isICloudPlaceholder(space.id, category: "spaces", profileID: pid))
    }

    func testStaleSnapshotCannotRecreateLocallyMovedSpaceOrDeletedProfile() async throws {
        let (_, defaults, manager, adapter) = try fixture()
        let source = manager.profiles[0].id
        let destination = manager.create(name: "Destination").id
        var space = manager.createSpace(name: "Move locally", in: source)
        space.pinnedTabURLs = [URL(string: "https://pin.example")!]
        XCTAssertTrue(manager.updateSpace(space))
        let enabled: Set<ICloudCategory> = [.profiles, .spaces, .pinnedTabs]
        let baseline = try await adapter.capture(enabled)
        XCTAssertNotNil(manager.moveSpace(space.id, from: source, to: destination, defaults: defaults))
        try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })) {
            try await adapter.apply(baseline, deleted: [], enabled: enabled)
        }
        XCTAssertFalse(manager.spaces(for: source).contains { $0.id == space.id })
        XCTAssertTrue(manager.spaces(for: destination).contains { $0.id == space.id })
        let nextBaseline = try await adapter.capture(enabled)
        let deleted = await manager.deleteAsync(destination)
        XCTAssertTrue(deleted)
        try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: nextBaseline.map { ($0.key, $0) })) {
            try await adapter.apply(nextBaseline, deleted: [], enabled: enabled)
        }
        XCTAssertFalse(manager.profiles.contains { $0.id == destination })
        XCTAssertFalse(try manager.isICloudPlaceholder(destination, category: "profiles"))
    }

    func testFailedRemoteDeviceListSaveDoesNotCaptureUncommittedCachedRows() async throws {
        let (directory, _, manager, adapter) = try fixture("local")
        _ = try await adapter.capture([.downloadHistory])
        let profile = manager.profiles[0].id
        let row = ICloudRemoteDownload(id: "other|\(profile)|\(UUID())", deviceID: "other", deviceName: "Other Mac", profileID: profile,
            source: URL(string: "https://download.example/file"), name: "file.zip", size: 10, completed: Date())
        let item = ICloudItem(category: .downloadHistory, id: row.id, profileID: profile, parentID: nil, fields: try ICloudItem.encodedFields(row))
        let file = directory.appendingPathComponent("icloud-device-lists.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do { try await adapter.apply([item], deleted: [], enabled: [.downloadHistory]); XCTFail("Blocked sidecar must reject the import") }
        catch { }
        try FileManager.default.removeItem(at: file)
        let captured = try await adapter.capture([.downloadHistory])
        XCTAssertFalse(captured.contains { $0.key == item.key }, "Only durably accepted device rows may enter capture")
        XCTAssertTrue(adapter.remoteDownloads.isEmpty)
    }

    func testDamagedDeviceRowsFailEveryCaptureUntilPersistedDataIsRepaired() async throws {
        let (directory, _, manager, adapter) = try fixture()
        struct DeviceDisk: Encodable {
            var items: [ICloudItem]
            var deletedProfiles: [UUID] = []
            var deletedSpaces: [String] = []
        }
        let profile = manager.profiles[0].id
        let invalid = ICloudItem(category: .downloadHistory, id: "other|\(profile)|row", profileID: profile, parentID: nil,
            fields: ["name": try JSONEncoder().encode("incomplete.zip")])
        try JSONEncoder().encode(DeviceDisk(items: [invalid])).write(to: directory.appendingPathComponent("icloud-device-lists.json"))
        for _ in 0..<2 {
            do { _ = try await adapter.capture([.downloadHistory]); XCTFail("Damaged owner state must never become a successful capture") }
            catch { }
        }
        XCTAssertTrue(adapter.remoteDownloads.isEmpty)
    }

    private func folderController(directory: URL, defaults: UserDefaults, adapter: ICloudLibraryAdapter) -> (ICloudController, LibraryCloudTransport) {
        let transport = LibraryCloudTransport()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [adapter], recovery: {})
        for category in ICloudCategory.allCases { controller.setEnabled(category == .sidebarFolders, for: category) }
        return (controller, transport)
    }

    private func assertFolderMoveThroughController(from: TabKind, to: TabKind) async throws {
        let (directory, defaults, manager, adapter) = try fixture("target")
        let pid = manager.profiles[0].id
        let folder = Folder(name: "Move this folder")
        let nested = Folder(name: "Nested folder")
        let pageID = UUID(), pageURL = URL(string: "https://local-page.example")!
        let originalShape = Pins(entries: [.init(row: .folder(folder), parent: nil), .init(row: .folder(nested), parent: folder.id),
            .init(row: .tab(pageID.uuidString), parent: nested.id)])
        var space = manager.createSpace(name: "Local Space", in: pid)
        space.tabURLs = from == .today ? [pageURL] : []
        space.pinnedTabURLs = from == .pinned ? [pageURL] : []
        space.layout = SpaceLayout(tabs: [.init(id: pageID, url: pageURL, kind: from, title: "Local page", customName: nil, home: from == .pinned ? pageURL : nil)], pins: from == .pinned ? originalShape : Pins(),
            today: from == .today ? originalShape : Pins(), splits: [], selected: nil)
        XCTAssertTrue(manager.updateSpace(space))
        let (controller, transport) = folderController(directory: directory, defaults: defaults, adapter: adapter)
        await controller.setMasterEnabled(true)
        XCTAssertNil(controller.lastError)
        let initial = try await adapter.capture([.sidebarFolders])
        let (remoteDirectory, _, remoteManager, remoteAdapter) = try fixture("source")
        let remoteJournal = try ICloudJournal(directory: remoteDirectory, deviceID: "source")
        _ = try await remoteJournal.merge(transport.sent)
        try await remoteJournal.markApplied(initial, enabled: [.sidebarFolders])
        let moved = try XCTUnwrap(TabStore.moved(folder: folder.id, from: originalShape, to: Pins(), at: .init(parent: nil, index: 0)))
        var changed = space
        changed.layout?.pins = to == .pinned ? moved.to : moved.from
        changed.layout?.today = to == .today ? moved.to : moved.from
        changed.layout?.tabs[0].kind = to
        changed.layout?.tabs[0].home = to == .pinned ? pageURL : nil
        changed.tabURLs = to == .today ? [pageURL] : []
        changed.pinnedTabURLs = to == .pinned ? [pageURL] : []
        XCTAssertTrue(remoteManager.saveSpaces([changed], for: pid))
        let remoteItems = try await remoteAdapter.capture([.sidebarFolders])
        try await remoteJournal.capture(remoteItems, enabled: [.sidebarFolders])
        transport.incoming = await remoteJournal.pending(enabled: [.sidebarFolders])
        await controller.syncNow()
        XCTAssertNil(controller.lastError)
        let saved = try XCTUnwrap(manager.spaces(for: pid).first?.layout)
        try saved.validate()
        let sourceShape = from == .pinned ? saved.pins : saved.today
        let destinationShape = to == .pinned ? saved.pins : saved.today
        XCTAssertNil(sourceShape.folder(folder.id), "Moved folder must leave its prior section")
        XCTAssertNil(sourceShape.folder(nested.id), "Nested folder must leave its prior section")
        XCTAssertEqual(destinationShape.folder(folder.id)?.name, folder.name)
        XCTAssertEqual(destinationShape.folder(nested.id)?.name, nested.name)
        XCTAssertEqual(destinationShape.entries.first { $0.folder?.id == nested.id }?.parent, folder.id)
        XCTAssertEqual(destinationShape.entries.first { $0.tab == pageID.uuidString }?.parent, nested.id)
        XCTAssertEqual(saved.tabs.first { $0.id == pageID }?.kind, to)
        XCTAssertEqual(saved.tabs.first { $0.id == pageID }?.url, pageURL, "Folder move must preserve the existing local page")
        let reopened = try ICloudJournal(directory: directory)
        let readback = await reopened.items(enabled: [.sidebarFolders])
        XCTAssertEqual(readback.count, 2)
        for item in readback {
            XCTAssertEqual(try JSONDecoder().decode(TabKind.self, from: XCTUnwrap(item.fields["section"])), to,
                "Readback must retain the remote move instead of publishing an undo")
        }
        let pending = await reopened.pending(enabled: [.sidebarFolders])
        XCTAssertTrue(pending.isEmpty, "A successfully applied folder move must not echo a local undo")
    }

    func testFolderMovesFromTodayToPinnedThroughControllerReadback() async throws {
        try await assertFolderMoveThroughController(from: .today, to: .pinned)
    }

    func testFolderMovesFromPinnedToTodayThroughControllerReadback() async throws {
        try await assertFolderMoveThroughController(from: .pinned, to: .today)
    }

    func testFolderOnlyMovesReachLiveOwnersAndSurviveControllerReadback() async throws {
        for (from, to) in [(TabKind.pinned, TabKind.today), (.today, .pinned)] {
            TestEnvironment.prepare(); _ = NSApplication.shared
            let manager = ProfileManager.shared
            let profile = manager.create(name: "Live folder sync")
            let pageID = UUID(), url = URL(string: "https://live-local-page.example")!
            let folder = Folder(name: "Live folder")
            let originalShape = Pins(entries: [.init(row: .folder(folder), parent: nil), .init(row: .tab(pageID.uuidString), parent: folder.id)])
            var space = manager.createSpace(name: "Live Space", in: profile.id)
            space.tabURLs = from == .today ? [url] : []
            space.pinnedTabURLs = from == .pinned ? [url] : []
            space.layout = SpaceLayout(tabs: [.init(id: pageID, url: url, kind: from, title: "Local page", customName: nil, home: from == .pinned ? url : nil)],
                pins: from == .pinned ? originalShape : Pins(), today: from == .today ? originalShape : Pins(), splits: [], selected: nil)
            XCTAssertTrue(manager.updateSpace(space))
            let store = TabStore(profileID: profile.id, space: space, session: [])
            store.sharingReady = false
            let tab = store.makeBlankTab(as: from, id: pageID)
            tab.park(url: url, Parked(title: "Local page"))
            store.tabs = [tab]
            store.pins = from == .pinned ? originalShape : Pins()
            store.todayShape = from == .today ? originalShape : Pins()
            store.sharingReady = true
            defer {
                store.sharingReady = false
                SharedTabs.release(store.tabs)
                TabStore.all.removeAll { $0 === store }
                _ = manager.delete(profile.id)
            }
            XCTAssertNil(store.current)
            XCTAssertNil(tab.existingWeb)
            let (remoteDirectory, controls, remoteManager, remoteAdapter) = try fixture("source")
            let adapter = ICloudLibraryAdapter(directory: manager.directory, defaults: .vane, deviceID: "live-target", profiles: manager)
            let (controller, transport) = folderController(directory: manager.directory, defaults: controls, adapter: adapter)
            await controller.setMasterEnabled(true)
            XCTAssertNil(controller.lastError)
            let initial = try await adapter.capture([.sidebarFolders]).filter { $0.profileID == profile.id }
            let remoteJournal = try ICloudJournal(directory: remoteDirectory, deviceID: "source")
            _ = try await remoteJournal.merge(transport.sent.filter { $0.profileID == profile.id })
            try await remoteJournal.markApplied(initial, enabled: [.sidebarFolders])
            let transfer = try XCTUnwrap(TabStore.moved(folder: folder.id, from: originalShape, to: Pins(), at: .init(parent: nil, index: 0)))
            var changed = space
            changed.layout?.pins = to == .pinned ? transfer.to : transfer.from
            changed.layout?.today = to == .today ? transfer.to : transfer.from
            changed.layout?.tabs[0].kind = to
            changed.layout?.tabs[0].home = to == .pinned ? url : nil
            changed.tabURLs = to == .today ? [url] : []
            changed.pinnedTabURLs = to == .pinned ? [url] : []
            try remoteManager.mergeICloudProfile(Profile(id: profile.id, name: "Source fixture"))
            XCTAssertTrue(remoteManager.saveSpaces([changed], for: profile.id))
            let remoteItems = try await remoteAdapter.capture([.sidebarFolders])
            try await remoteJournal.capture(remoteItems, enabled: [.sidebarFolders])
            transport.incoming = await remoteJournal.pending(enabled: [.sidebarFolders])
            await controller.syncNow()
            XCTAssertNil(controller.lastError)
            XCTAssertEqual(tab.kind, to, "Existing live pages must follow their folder's section")
            XCTAssertTrue(store.tabs.contains { $0 === tab }, "The existing page object must survive")
            XCTAssertEqual(tab.currentURL, url)
            XCTAssertNil(store.current)
            XCTAssertNil(tab.existingWeb, "Folder sync must not navigate or wake the existing page")
            let destination = to == .pinned ? store.pins : store.todayShape
            XCTAssertNotNil(destination.folder(folder.id))
            XCTAssertEqual(destination.entries.first { $0.tab == pageID.uuidString }?.parent, folder.id)
            let saved = try XCTUnwrap(manager.spaces(for: profile.id).first?.layout)
            try saved.validate()
            XCTAssertEqual(saved.tabs.first { $0.id == pageID }?.kind, to)
            XCTAssertNotNil((to == .pinned ? saved.pins : saved.today).folder(folder.id), "Session readback must preserve the move")
            XCTAssertFalse(controller.enabledCategories.contains(.pinnedTabs))
        }
    }

    func testRepeatedChildOnlyChangesKeepContainingSpaceAtItsOriginalIndex() async throws {
        let (directory, defaults, manager, adapter) = try fixture("target")
        let pid = manager.profiles[0].id
        var a = manager.createSpace(name: "A", in: pid)
        let b = manager.createSpace(name: "B", in: pid)
        let first = Folder(name: "First"), second = Folder(name: "Second")
        a.layout = SpaceLayout(tabs: [], pins: Pins(entries: [.init(row: .folder(first), parent: nil), .init(row: .folder(second), parent: nil)]),
            today: Pins(), splits: [], selected: nil)
        XCTAssertTrue(manager.updateSpace(a))
        let expected = [a.id, b.id]
        let (controller, transport) = folderController(directory: directory, defaults: defaults, adapter: adapter)
        await controller.setMasterEnabled(true)
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(manager.spaces(for: pid).map(\.id), expected)
        let initial = try await adapter.capture([.sidebarFolders])
        let (remoteDirectory, _, remoteManager, remoteAdapter) = try fixture("source")
        let remoteJournal = try ICloudJournal(directory: remoteDirectory, deviceID: "source")
        _ = try await remoteJournal.merge(transport.sent)
        try await remoteJournal.markApplied(initial, enabled: [.sidebarFolders])
        for iteration in 0..<3 {
            var changed = a
            let ordered = iteration.isMultiple(of: 2) ? [second, first] : [first, second]
            changed.layout?.pins = Pins(entries: ordered.map { folder in
                var folder = folder; folder.name += " \(iteration)"
                return .init(row: .folder(folder), parent: nil)
            })
            XCTAssertTrue(remoteManager.saveSpaces([changed, b], for: pid))
            let remoteItems = try await remoteAdapter.capture([.sidebarFolders])
            try await remoteJournal.capture(remoteItems, enabled: [.sidebarFolders])
            transport.incoming = await remoteJournal.pending(enabled: [.sidebarFolders])
            await controller.syncNow()
            XCTAssertNil(controller.lastError)
            XCTAssertEqual(manager.spaces(for: pid).map(\.id), expected, "Child apply must not reorder disabled Space metadata")
            XCTAssertEqual(manager.spaces(for: pid).first?.layout?.pins.entries.compactMap { $0.folder?.id }, ordered.map(\.id))
        }
        XCTAssertFalse(controller.enabledCategories.contains(.spaces))
    }

    func testCorruptCommittedDataThrowsInsteadOfInferringDeletion() async throws {
        let (dir, _, manager, adapter) = try fixture()
        try Data("broken".utf8).write(to: ProfileManager.spacesURL(for: manager.profiles[0].id, in: dir))
        do { _ = try await adapter.capture([.spaces]); XCTFail("Corrupt Spaces must not become an empty snapshot") }
        catch { }
    }
}

@MainActor private final class LibraryCloudTransport: ICloudTransport {
    var sent: [ICloudRecord] = []
    var incoming: [ICloudRecord] = []
    func account() async throws -> String { "library-controller-test" }
    func exchange(pending: [ICloudRecord], enabled: Set<ICloudCategory>, state: Data?, epochs: [ICloudCategory: String],
                  persistState: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudExchange {
        sent += pending
        return ICloudExchange(received: incoming, acknowledged: pending)
    }
    func remove(_ categories: Set<ICloudCategory>) async throws { }
}
