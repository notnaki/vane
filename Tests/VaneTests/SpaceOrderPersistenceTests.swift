import AppKit
import XCTest
@testable import vane

/// The global Space order lives in profiles.json (which backups carry) and syncs as one
/// Spaces record. Each profile's `spaces.json` stays the order inside that profile.
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
        ICloudItem(category: .spaces, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil,
                   fields: ["ids": try JSONEncoder().encode(ids)])
    }
    private let categories: Set<ICloudCategory> = [.profiles, .spaces]

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

        // And an older version given the order record skips it, as it has no profile; here
        // that is every other record applying exactly as before with the order left out.
        XCTAssertTrue(l.manager.reorderSpace(from: 0, to: 4))
        let new = try await adapter(l).capture(categories)
        let (older, olderTarget) = try emptyMac()
        try await olderTarget.apply(new.filter { !$0.isSpaceOrder }, deleted: [], enabled: categories)
        XCTAssertEqual(older.spaces(for: l.personal).map(\.name), ["Mail", "Home"], "The per-profile order still carries the move")
        XCTAssertEqual(Set(names(older)), ["Home", "Mail", "Docs", "Chat"], "No Space is lost")
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
            let bad = ICloudItem(category: .spaces, id: ICloudItem.spaceOrderID, profileID: nil, parentID: nil, fields: fields)
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

    /// Versions from before the order skip the live record but reject its tombstone as
    /// corrupt, so a Mac that stops holding an order must never delete the record.
    func testTheJournalNeverDeletesTheOrderRecord() async throws {
        let directory = try directory()
        let journal = try ICloudJournal(directory: directory, deviceID: "local")
        let space = ICloudItem(category: .spaces, id: UUID().uuidString, profileID: ProfileManager.defaultID, parentID: nil,
                               fields: ["name": Data(#""Home""#.utf8)])
        let order = try orderItem([UUID(), UUID()])
        try await journal.capture([space, order], enabled: [.spaces])
        try await journal.acknowledge(await journal.pending(enabled: [.spaces]))

        // An older build rewrote profiles.json, or an older backup was restored: no order.
        try await journal.capture([], enabled: [.spaces])
        var deleted = await journal.deleted(enabled: [.spaces])
        XCTAssertEqual(deleted.map(\.id), [space.id], "An ordinary Space's absence is still a deletion")
        var live = await journal.items(enabled: [.spaces])
        XCTAssertEqual(live, [order], "The order record stays live, to be taken back on the next apply")

        try await journal.markApplied([order], enabled: [.spaces])
        try await journal.markApplied([], enabled: [.spaces])
        deleted = await journal.deleted(enabled: [.spaces])
        live = await journal.items(enabled: [.spaces])
        XCTAssertFalse(deleted.contains(where: \.isSpaceOrder))
        XCTAssertEqual(live, [order])
        let pending = await journal.pending(enabled: [.spaces])
        XCTAssertFalse(pending.contains { $0.item.isSpaceOrder }, "Nothing about the order is uploaded either")
    }
}
