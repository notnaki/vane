import AppKit
import XCTest
@testable import vane

/// The global Space order lives in profiles.json (which backups carry) and syncs as one
/// record with no profile. Each profile's `spaces.json` stays the order inside that profile.
@MainActor final class SpaceOrderPersistenceTests: XCTestCase {
    private struct Library {
        let directory: URL, manager: ProfileManager, work: Profile
        let home: Space, mail: Space, docs: Space, chat: Space
        var personal: UUID { ProfileManager.defaultID }
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-space-order-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Personal: Home, Mail. Work: Docs, Chat.
    private func library() throws -> Library {
        let directory = try directory()
        let manager = ProfileManager(directory: directory, sandboxed: true)
        let work = manager.create(name: "Work")
        return Library(directory: directory, manager: manager, work: work,
                       home: manager.createSpace(name: "Home", in: ProfileManager.defaultID),
                       mail: manager.createSpace(name: "Mail", in: ProfileManager.defaultID),
                       docs: manager.createSpace(name: "Docs", in: work.id),
                       chat: manager.createSpace(name: "Chat", in: work.id))
    }

    private func names(_ manager: ProfileManager) -> [String] { manager.allSpaces.map(\.name) }
    private func savedProfiles(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("profiles.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Saving and loading

    func testNoSavedOrderIsEachProfilesOwnOrder() throws {
        let l = try library()
        XCTAssertEqual(names(l.manager), ["Home", "Mail", "Docs", "Chat"])
        XCTAssertTrue(l.manager.spaceOrder.isEmpty)
        XCTAssertNil(try savedProfiles(l.directory)["spaceOrder"], "The file stays what an older version writes")

        // A profiles.json from an older version has no such key, and still loads.
        let old = try directory()
        try Data(##"{"profiles":[{"id":"\##(ProfileManager.defaultID)","name":"Personal","colorHex":"#6E7DD2"}],"activeID":"\##(ProfileManager.defaultID)"}"##.utf8)
            .write(to: old.appendingPathComponent("profiles.json"))
        let manager = ProfileManager(directory: old, sandboxed: true)
        XCTAssertEqual(manager.profiles.map(\.name), ["Personal"])
        XCTAssertTrue(manager.spaceOrder.isEmpty)
    }

    func testACrossProfileMoveSavesOnlyTheGlobalOrderAndSurvivesAReload() throws {
        let l = try library()
        let revision = l.manager.spacesRevision
        let personalFile = try Data(contentsOf: ProfileManager.spacesURL(for: l.personal, in: l.directory))
        // Mail to after Docs.
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))
        XCTAssertEqual(names(l.manager), ["Home", "Docs", "Mail", "Chat"])
        XCTAssertEqual(l.manager.spaces(for: l.personal).map(\.name), ["Home", "Mail"], "Ownership and in-profile order are untouched")
        XCTAssertEqual(l.manager.spaces(for: l.work.id).map(\.name), ["Docs", "Chat"])
        XCTAssertEqual(try Data(contentsOf: ProfileManager.spacesURL(for: l.personal, in: l.directory)), personalFile)
        XCTAssertEqual(l.manager.spacesRevision, revision, "No Space was saved")

        let reloaded = ProfileManager(directory: l.directory, sandboxed: true)
        XCTAssertEqual(names(reloaded), ["Home", "Docs", "Mail", "Chat"])
        XCTAssertEqual(reloaded.spaceOrder, [l.home.id, l.docs.id, l.mail.id, l.chat.id])
    }

    func testAMoveInsideAProfileAlsoRewritesThatProfilesOwnOrder() throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))       // Home, Docs, Mail, Chat
        let revision = l.manager.spacesRevision
        // Home to the end: past Mail, its own profile's, and both of Work's.
        XCTAssertTrue(l.manager.reorderSpace(from: 0, to: 4))
        XCTAssertEqual(names(l.manager), ["Docs", "Mail", "Chat", "Home"])
        XCTAssertEqual(l.manager.spaces(for: l.personal).map(\.name), ["Mail", "Home"],
                       "spaces.json is what older versions, sync and per-profile readers follow")
        XCTAssertEqual(l.manager.spacesRevision, revision + 1, "One profile's Spaces were saved, once")
        XCTAssertEqual(names(ProfileManager(directory: l.directory, sandboxed: true)), ["Docs", "Mail", "Chat", "Home"])

        // An older version that knows nothing of the global order still reorders a profile.
        XCTAssertTrue(l.manager.saveSpaces(l.manager.spaces(for: l.work.id).reversed(), for: l.work.id))
        XCTAssertEqual(names(l.manager), ["Chat", "Mail", "Docs", "Home"])
        XCTAssertEqual(l.manager.spaceOrder, l.manager.allSpaces.map(\.id))
    }

    func testAnUnchangedOrderWritesNothing() throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))
        let file = l.directory.appendingPathComponent("profiles.json")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let revision = l.manager.spacesRevision
        var published = 0
        let observation = l.manager.$spaceOrder.dropFirst().sink { _ in published += 1 }
        XCTAssertTrue(l.manager.reorderSpace(from: 2, to: 2))
        XCTAssertTrue(l.manager.reorderSpace(from: 2, to: 3))
        XCTAssertFalse(l.manager.reorderSpace(from: 9, to: 0))
        observation.cancel()
        XCTAssertEqual(published, 0)
        XCTAssertEqual(l.manager.spacesRevision, revision)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)

        // With no saved order yet, a drop where the Space already stands does not start one.
        let fresh = try library()
        XCTAssertTrue(fresh.manager.reorderSpace(from: 1, to: 1))
        XCTAssertTrue(fresh.manager.reorderSpace(from: 1, to: 2))
        XCTAssertTrue(fresh.manager.spaceOrder.isEmpty)
        XCTAssertNil(try savedProfiles(fresh.directory)["spaceOrder"])
    }

    func testADamagedSavedOrderNeverCostsTheProfileList() throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))
        var saved = try savedProfiles(l.directory)
        let file = l.directory.appendingPathComponent("profiles.json")

        saved["spaceOrder"] = ["not a uuid", 7]
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        var manager = ProfileManager(directory: l.directory, sandboxed: true)
        XCTAssertEqual(manager.profiles.map(\.name), ["Personal", "Work"])
        XCTAssertEqual(names(manager), ["Home", "Mail", "Docs", "Chat"], "An unreadable order is no order")

        let stray = UUID().uuidString
        saved["spaceOrder"] = [l.docs.id.uuidString, stray, l.docs.id.uuidString, l.home.id.uuidString]
            + Array(repeating: l.chat.id.uuidString, count: 50_000)
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        manager = ProfileManager(directory: l.directory, sandboxed: true)
        XCTAssertEqual(manager.spaceOrder.count, 4, "Duplicates are dropped on load")
        XCTAssertEqual(names(manager), ["Docs", "Home", "Mail", "Chat"], "Mail, which it never named, stays beside Home")
    }

    // MARK: New and deleted Spaces

    func testANewSpaceStandsBesideItsOwnProfilesSpaces() throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 3, to: 0))       // Chat, Home, Mail, Docs
        let notes = l.manager.createSpace(name: "Notes", in: l.personal)
        XCTAssertEqual(names(l.manager), ["Chat", "Home", "Mail", "Notes", "Docs"], "Not at the end of the whole strip")
        XCTAssertEqual(l.manager.spaceOrder, l.manager.allSpaces.map(\.id), "And the saved order names it there")
        let plans = l.manager.createSpace(name: "Plans", in: l.work.id)
        XCTAssertEqual(names(l.manager), ["Chat", "Home", "Mail", "Notes", "Docs", "Plans"])

        // Deleting a Space leaves every other Space where it stood, including the new ones.
        XCTAssertTrue(l.manager.deleteSpace(l.mail.id, in: l.personal))
        XCTAssertEqual(names(l.manager), ["Chat", "Home", "Notes", "Docs", "Plans"])
        XCTAssertEqual(l.manager.spaceOrder, [l.chat.id, l.home.id, notes.id, l.docs.id, plans.id])

        // A profile made after the order was saved comes after the profiles before it.
        let side = l.manager.create(name: "Side")
        _ = l.manager.createSpace(name: "Garden", in: side.id)
        XCTAssertEqual(names(l.manager), ["Chat", "Home", "Notes", "Docs", "Plans", "Garden"])
    }

    func testDeletedSpacesAndProfilesLeaveTheSavedOrder() throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))       // Home, Docs, Mail, Chat
        XCTAssertTrue(l.manager.deleteSpace(l.docs.id, in: l.work.id))
        XCTAssertEqual(l.manager.spaceOrder, [l.home.id, l.mail.id, l.chat.id])
        XCTAssertEqual((try savedProfiles(l.directory)["spaceOrder"] as? [String])?.count, 3, "Pruned on disk too")

        // Re-homing a Space keeps one entry for it, now among its new profile's Spaces.
        XCTAssertNotNil(l.manager.moveSpace(l.mail.id, from: l.personal, to: l.work.id, defaults: UserDefaults(suiteName: "vane.order.\(UUID())")!))
        XCTAssertEqual(l.manager.spaceOrder.filter { $0 == l.mail.id }.count, 1)
        XCTAssertEqual(Set(l.manager.spaceOrder), Set(l.manager.allSpaces.map(\.id)))
        XCTAssertEqual(l.manager.spaces(for: l.work.id).map(\.name), ["Chat", "Mail"])

        XCTAssertTrue(l.manager.delete(l.work.id))
        XCTAssertEqual(l.manager.spaceOrder, [l.home.id])
        XCTAssertEqual(ProfileManager(directory: l.directory, sandboxed: true).spaceOrder, [l.home.id])

        // The last Space going leaves no order behind, and the key leaves the file.
        XCTAssertTrue(l.manager.deleteSpace(l.home.id, in: l.personal))
        XCTAssertTrue(l.manager.spaceOrder.isEmpty)
        XCTAssertNil(try savedProfiles(l.directory)["spaceOrder"])
    }

    // MARK: Backups

    func testABackupCarriesTheOrderAndAnOlderBackupStillRestores() throws {
        let fixture = try BackupFixture()
        addTeardownBlock { await MainActor.run { fixture.cleanup() } }
        let manager = fixture.seed(), work = manager.create(name: "Work")
        _ = manager.createSpace(name: "Home", in: ProfileManager.defaultID)
        _ = manager.createSpace(name: "Mail", in: ProfileManager.defaultID)
        _ = manager.createSpace(name: "Docs", in: work.id)
        XCTAssertTrue(manager.reorderSpace(from: 2, to: 1))         // Home, Docs, Mail

        let archive = try fixture.library.capture(reason: .manual)
        XCTAssertEqual(try fixture.library.validate(archive).spaces, 3)
        let restored = try directory()
        for file in archive.files { try file.data.write(to: restored.appendingPathComponent(file.name)) }
        XCTAssertEqual(names(ProfileManager(directory: restored, sandboxed: true)), ["Home", "Docs", "Mail"])

        // Without the key, as a backup from before the global order: the per-profile order.
        var profiles = try savedProfiles(restored)
        profiles["spaceOrder"] = nil
        try JSONSerialization.data(withJSONObject: profiles).write(to: restored.appendingPathComponent("profiles.json"))
        XCTAssertEqual(names(ProfileManager(directory: restored, sandboxed: true)), ["Home", "Mail", "Docs"])
    }

    // MARK: iCloud

    private func adapter(_ l: Library, device: String = UUID().uuidString) -> ICloudLibraryAdapter {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        return ICloudLibraryAdapter(directory: l.directory, defaults: UserDefaults(suiteName: "vane.order.\(UUID())")!,
                                    deviceID: device, profiles: l.manager)
    }
    private func emptyMac() throws -> (ProfileManager, ICloudLibraryAdapter) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let directory = try directory()
        let manager = ProfileManager(directory: directory, sandboxed: true)
        return (manager, ICloudLibraryAdapter(directory: directory, defaults: UserDefaults(suiteName: "vane.order.\(UUID())")!,
                                             deviceID: UUID().uuidString, profiles: manager))
    }
    private func orderItem(_ ids: [UUID]) throws -> ICloudItem {
        ICloudItem(category: .sidebarFolders, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil,
                   fields: ["ids": try JSONEncoder().encode(ids)])
    }
    private let categories: Set<ICloudCategory> = [.profiles, .spaces, .sidebarFolders]

    func testTheOrderSurvivesASyncRoundTripWithoutAnEcho() async throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))       // Home, Docs, Mail, Chat
        let captured = try await adapter(l).capture(categories)
        XCTAssertEqual(captured.filter(\.isSpaceOrder), [try orderItem(l.manager.spaceOrder)])

        let (manager, target) = try emptyMac()
        try await target.apply(captured, deleted: [], enabled: categories)
        XCTAssertEqual(names(manager), ["Home", "Docs", "Mail", "Chat"])
        XCTAssertEqual(manager.spaces(for: l.work.id).map(\.name), ["Docs", "Chat"])
        // Reading back exactly what arrived is what keeps this Mac from re-uploading it.
        let readback = try await target.capture(categories)
        XCTAssertEqual(readback.filter(\.isSpaceOrder), captured.filter(\.isSpaceOrder))

        // A later reorder on the first Mac, in-profile and across, reaches the second.
        XCTAssertTrue(l.manager.reorderSpace(from: 0, to: 4))       // Docs, Mail, Chat, Home
        let later = try await adapter(l).capture(categories)
        try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: readback.map { ($0.key, $0) })) {
            try await target.apply(later, deleted: [], enabled: categories)
        }
        XCTAssertEqual(names(manager), ["Docs", "Mail", "Chat", "Home"])
        XCTAssertEqual(manager.spaces(for: l.personal).map(\.name), ["Mail", "Home"])
    }

    func testWithoutASyncedOrderEachProfilesOwnOrderApplies() async throws {
        let l = try library()
        let captured = try await adapter(l).capture(categories)
        XCTAssertFalse(captured.contains(where: \.isSpaceOrder), "A Mac that never reordered uploads no order")

        // What an older version uploads after a reorder inside one profile: positions only.
        XCTAssertTrue(l.manager.saveSpaces(l.manager.spaces(for: l.work.id).reversed(), for: l.work.id))
        let old = try await adapter(l).capture(categories)
        let (manager, target) = try emptyMac()
        try await target.apply(old, deleted: [], enabled: categories)
        XCTAssertEqual(names(manager), ["Home", "Mail", "Chat", "Docs"])
        XCTAssertTrue(manager.spaceOrder.isEmpty)

        // The order needs both of its categories: with either off, none is uploaded.
        XCTAssertTrue(l.manager.reorderSpace(from: 0, to: 4))
        for off in ICloudItem.spaceOrderCategories {
            let partial = try await adapter(l).capture(categories.subtracting([off]))
            XCTAssertFalse(partial.contains(where: \.isSpaceOrder))
        }
    }

    /// All a version from before the order has for a record with no profile are the
    /// adapter's ordinary loops, the same since 0.2.0. They are also all this adapter runs
    /// for the record while the order's own handling is off, which is what is applied here.
    /// Those loops skip it live and deleted in Sidebar folders, and refuse it deleted in
    /// Spaces, which is why it is not filed there. See `ICloudItem.isSpaceOrder`.
    func testAVersionFromBeforeTheOrderSkipsItsRecordLiveAndDeleted() async throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))       // Home, Docs, Mail, Chat
        let order = try await adapter(l).capture(categories).filter(\.isSpaceOrder)
        XCTAssertEqual(order.map(\.key), ["sidebarFolders:global:spaceOrder"], "The shape older versions tolerate")

        let (older, target) = try emptyMac()
        let ordinary = categories.subtracting([.spaces])
        try await target.apply(order, deleted: [], enabled: ordinary)
        try await target.apply([], deleted: order, enabled: ordinary)
        XCTAssertTrue(older.spaceOrder.isEmpty)
        XCTAssertEqual(older.profiles.map(\.id), [ProfileManager.defaultID], "No profile or Space is invented for it")
        XCTAssertTrue(older.allSpaces.isEmpty)

        let asSpaces = ICloudItem(category: .spaces, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil, fields: [:])
        do {
            try await target.apply([], deleted: [asSpaces], enabled: categories)
            XCTFail("A deleted Spaces record with no profile is refused, by this version and older ones")
        } catch {}

        // This version, given the tombstone an older build left, keeps the order it holds.
        try await adapter(l).apply([], deleted: order, enabled: categories)
        XCTAssertEqual(names(l.manager), ["Home", "Docs", "Mail", "Chat"])
    }

    func testALocalReorderSinceTheLastSyncIsNotOverwritten() async throws {
        let l = try library()
        XCTAssertTrue(l.manager.reorderSpace(from: 1, to: 3))       // Home, Docs, Mail, Chat
        let adapter = adapter(l)
        let baseline = try await adapter.capture(categories)
        XCTAssertTrue(l.manager.reorderSpace(from: 3, to: 0))       // Chat, Home, Docs, Mail
        let remote = try orderItem([l.docs.id, l.chat.id, l.home.id, l.mail.id])
        try await ICloudApplyContext.$baseline.withValue(Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })) {
            try await adapter.apply([remote], deleted: [], enabled: categories)
        }
        XCTAssertEqual(names(l.manager), ["Chat", "Home", "Docs", "Mail"])
    }

    func testMalformedSyncedOrdersAreValidatedNotTrusted() async throws {
        let l = try library()
        let adapter = adapter(l)
        // Unknown ids, duplicates and far too many entries.
        let noisy = [UUID(), l.chat.id, l.chat.id, l.home.id, UUID()] + (0..<20_000).map { _ in UUID() }
        try await adapter.apply([try orderItem(noisy)], deleted: [], enabled: categories)
        XCTAssertEqual(names(l.manager), ["Docs", "Chat", "Home", "Mail"], "Work first, in Work's own order")
        XCTAssertEqual(l.manager.spaceOrder.count, ProfileManager.spaceOrderLimit)
        XCTAssertEqual(Set(l.manager.spaceOrder).count, l.manager.spaceOrder.count)
        XCTAssertEqual(Set(names(l.manager)).count, 4, "Every Space still shows exactly once")

        // Not a list of ids at all, or no ids field: skipped, and nothing else is refused.
        let before = l.manager.spaceOrder
        for fields in [["ids": Data(#"{"a":1}"#.utf8)], ["ids": Data("[1,2]".utf8)], ["ids": Data()], [:]] {
            let bad = ICloudItem(category: .sidebarFolders, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil, fields: fields)
            try await adapter.apply([bad], deleted: [bad], enabled: categories)
        }
        XCTAssertEqual(l.manager.spaceOrder, before)
        XCTAssertEqual(l.manager.profiles.count, 2)

        // A Space that arrives with the order takes the place the order gives it.
        let plans = Space(name: "Plans", profileID: l.work.id)
        var record = try ICloudItem.encodedFields(plans)
        for key in ["tabURLs", "pinnedURLs", "pinnedTabURLs", "layout", "profileID", "id"] { record[key] = nil }
        record["position"] = try JSONEncoder().encode(2)
        let order = try orderItem([l.home.id, plans.id, l.mail.id, l.docs.id, l.chat.id])
        try await adapter.apply([ICloudItem(category: .spaces, id: plans.id.uuidString, profileID: l.work.id, parentID: nil, fields: record), order],
                                deleted: [], enabled: categories)
        XCTAssertEqual(names(l.manager), ["Home", "Docs", "Mail", "Chat", "Plans"],
                       "Work's own list says Docs, Chat, Plans; the order says where Work's places are")
    }

    /// A Mac that stops holding an order is not a Mac whose user removed it, so this
    /// version never turns the order's absence into a deletion.
    func testTheJournalNeverDeletesTheOrderRecord() async throws {
        let enabled = ICloudItem.spaceOrderCategories
        let directory = try directory()
        let journal = try ICloudJournal(directory: directory, deviceID: "local")
        let space = ICloudItem(category: .spaces, id: UUID().uuidString, profileID: ProfileManager.defaultID, parentID: nil,
                               fields: ["name": Data(#""Home""#.utf8)])
        let order = try orderItem([UUID(), UUID()])
        try await journal.capture([space, order], enabled: enabled)
        try await journal.acknowledge(await journal.pending(enabled: enabled))

        // An older build rewrote profiles.json, or an older backup was restored: no order.
        try await journal.capture([], enabled: enabled)
        var deleted = await journal.deleted(enabled: enabled)
        XCTAssertEqual(deleted.map(\.id), [space.id], "An ordinary Space's absence is still a deletion")
        var live = await journal.items(enabled: enabled)
        XCTAssertEqual(live, [order], "The order record stays live, to be taken back on the next apply")

        try await journal.markApplied([order], enabled: enabled)
        try await journal.markApplied([], enabled: enabled)
        deleted = await journal.deleted(enabled: enabled)
        live = await journal.items(enabled: enabled)
        XCTAssertFalse(deleted.contains(where: \.isSpaceOrder))
        XCTAssertEqual(live, [order])
        let pending = await journal.pending(enabled: enabled)
        XCTAssertFalse(pending.contains { $0.item.isSpaceOrder }, "Nothing about the order is uploaded either")
    }

    /// An older build run on a Mac that had synced an order does delete the record: it
    /// finds it in the shared journal's baseline and captures none. A Mac that still
    /// holds the order writes it again, or it would stop syncing for the whole account.
    func testAnOrderAnOlderBuildDeletedIsWrittenAgain() async throws {
        let enabled = ICloudItem.spaceOrderCategories
        let journal = try ICloudJournal(directory: try directory(), deviceID: "local")
        let order = try orderItem([UUID(), UUID()])
        try await journal.capture([order], enabled: enabled)
        let sent = await journal.pending(enabled: enabled)
        try await journal.acknowledge(sent)

        // What the older build uploads: this record, deleted after everything it had seen.
        var tombstone = try XCTUnwrap(sent.first)
        var vector = tombstone.vector; vector["older"] = 7
        tombstone.deletion = ICloudVersion(vector: vector, writer: "older", counter: 7)
        _ = try await journal.merge([tombstone])
        var deleted = await journal.deleted(enabled: enabled)
        XCTAssertEqual(deleted.map(\.key), [order.key])

        // Nothing changed on this Mac, and its next capture still revives the record.
        try await journal.capture([order], enabled: enabled)
        deleted = await journal.deleted(enabled: enabled)
        let live = await journal.items(enabled: enabled)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(live, [order])
        var pending = await journal.pending(enabled: enabled)
        let revived = try XCTUnwrap(pending.first { $0.item.isSpaceOrder }, "And uploads it")

        // Every Mac that holds the tombstone, the older one included, takes the revival.
        for merged in [ICloudRecord.merged(tombstone, revived), ICloudRecord.merged(revived, tombstone)] {
            XCTAssertNil(merged.deletion)
            XCTAssertEqual(merged.item, order)
        }

        // An ordinary record is not revived by a tombstone it never saw the absence of.
        let folder = ICloudItem(category: .sidebarFolders, id: UUID().uuidString, profileID: ProfileManager.defaultID,
                                parentID: nil, fields: ["name": Data(#""Work""#.utf8)])
        try await journal.capture([order, folder], enabled: enabled)
        pending = await journal.pending(enabled: enabled)
        var gone = try XCTUnwrap(pending.first { $0.key == folder.key })
        vector = gone.vector; vector["older"] = 9
        gone.deletion = ICloudVersion(vector: vector, writer: "older", counter: 9)
        _ = try await journal.merge([gone])
        try await journal.capture([order, folder], enabled: enabled)
        deleted = await journal.deleted(enabled: enabled)
        XCTAssertEqual(deleted.map(\.key), [folder.key])
    }
}
