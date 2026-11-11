import XCTest
@testable import vane

final class ICloudJournalTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func item(_ title: String, url: String = "https://example.com") -> ICloudItem {
        ICloudItem(category: .bookmarks, id: "bookmark-1", profileID: nil, parentID: nil,
                   fields: ["title": Data(title.utf8), "url": Data(url.utf8)])
    }
    func testSensitiveDefaultsAndNoFileCategory() {
        XCTAssertFalse(ICloudCategory.history.defaultEnabled)
        XCTAssertFalse(ICloudCategory.passwords.defaultEnabled)
        XCTAssertFalse(ICloudCategory.aiKeys.defaultEnabled)
        XCTAssertFalse(ICloudCategory.extensionSyncData.defaultEnabled)
        XCTAssertTrue(ICloudCategory.downloadHistory.defaultEnabled)
        XCTAssertFalse(ICloudCategory.allCases.contains { $0.rawValue == "downloadedFiles" })
    }
    func testConcurrentFieldEditsConvergeWithoutLosingIndependentChanges() async throws {
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        let b = try ICloudJournal(directory: root(), deviceID: "b")
        try await a.capture([item("original")], enabled: [.bookmarks])
        let initial = await a.pending(enabled: [.bookmarks])
        _ = try await b.merge(initial)
        try await b.markApplied([item("original")], enabled: [.bookmarks])
        try await a.capture([item("edited")], enabled: [.bookmarks])
        try await b.capture([item("original", url: "https://other.example")], enabled: [.bookmarks])
        let left = await a.pending(enabled: [.bookmarks])
        let right = await b.pending(enabled: [.bookmarks])
        _ = try await a.merge(right)
        _ = try await b.merge(left)
        let av = await a.items(enabled: [.bookmarks])
        let bv = await b.items(enabled: [.bookmarks])
        XCTAssertEqual(av, bv)
        XCTAssertEqual(av.first?.fields["title"], Data("edited".utf8))
        XCTAssertEqual(av.first?.fields["url"], Data("https://other.example".utf8))
    }
    func testDeletionCannotBeResurrectedByOfflineEdit() async throws {
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        let b = try ICloudJournal(directory: root(), deviceID: "b")
        try await a.capture([item("original")], enabled: [.bookmarks])
        _ = try await b.merge(await a.pending(enabled: [.bookmarks]))
        try await b.markApplied([item("original")], enabled: [.bookmarks])
        try await a.capture([], enabled: [.bookmarks])
        try await b.capture([item("offline edit")], enabled: [.bookmarks])
        _ = try await a.merge(await b.pending(enabled: [.bookmarks]))
        _ = try await b.merge(await a.pending(enabled: [.bookmarks]))
        let av = await a.items(enabled: [.bookmarks])
        let bv = await b.items(enabled: [.bookmarks])
        XCTAssertTrue(av.isEmpty)
        XCTAssertTrue(bv.isEmpty)
    }
    func testDisabledCaptureCannotInferDeletionAndPendingSurvivesRestart() async throws {
        let directory = try root()
        let a = try ICloudJournal(directory: directory, deviceID: "a")
        try await a.capture([item("kept")], enabled: [.bookmarks])
        try await a.capture([], enabled: [.history])
        let reopened = try ICloudJournal(directory: directory, deviceID: "ignored")
        let pending = await reopened.pending(enabled: [.bookmarks])
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.deletion)
        let identity = await reopened.deviceID
        XCTAssertEqual(identity, "a")
    }
    func testStaleAcknowledgementCannotClearNewerLocalEdit() async throws {
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        try await a.capture([item("first")], enabled: [.bookmarks])
        let sent = await a.pending(enabled: [.bookmarks])
        try await a.capture([item("newer")], enabled: [.bookmarks])
        try await a.acknowledge(sent)
        let pending = await a.pending(enabled: [.bookmarks])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.item.fields["title"], Data("newer".utf8))
    }
    func testAccountChangeCannotAdmitOldPendingRecords() async throws {
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        try await a.bindAccount("old", allowMerge: false)
        try await a.capture([item("private")], enabled: [.bookmarks])
        do {
            try await a.bindAccount("new", allowMerge: false)
            XCTFail("Account change must require a deliberate merge choice")
        } catch ICloudFailure.accountChanged { }
        let account = await a.accountID
        XCTAssertEqual(account, ICloudIdentity.digest("old"))
    }
    func testConcurrentEaselEditsPreserveDeterministicConflictCopy() async throws {
        let profile = ProfileManager.defaultID
        let board = UUID()
        func boardItem(_ value: String) -> ICloudItem {
            ICloudItem(category: .easels, id: "\(profile.uuidString.lowercased())/\(board.uuidString.lowercased())",
                profileID: profile, parentID: profile.uuidString,
                fields: ["id": try! JSONEncoder().encode(board), "title": Data(value.utf8)])
        }
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        let b = try ICloudJournal(directory: root(), deviceID: "b")
        try await a.capture([boardItem("original")], enabled: [.easels])
        _ = try await b.merge(await a.pending(enabled: [.easels]))
        try await b.markApplied([boardItem("original")], enabled: [.easels])
        try await a.capture([boardItem("left")], enabled: [.easels])
        try await b.capture([boardItem("right")], enabled: [.easels])
        let left = await a.pending(enabled: [.easels]), right = await b.pending(enabled: [.easels])
        _ = try await a.merge(right); _ = try await b.merge(left)
        let av = await a.items(enabled: [.easels]), bv = await b.items(enabled: [.easels])
        XCTAssertEqual(av, bv)
        XCTAssertEqual(av.count, 2, "Both concurrent boards must remain available")
        XCTAssertEqual(Set(av.compactMap { $0.fields["title"] }), [Data("left".utf8), Data("right".utf8)])
    }
    func testProfileDeletionRetiresKnownChildrenEvenWithChildSwitchOff() async throws {
        let profile = UUID()
        let parent = ICloudItem(category: .profiles, id: profile.uuidString, profileID: profile, parentID: nil, fields: ["name": Data("name".utf8)])
        var child = item("child"); child.profileID = profile
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        try await journal.capture([parent, child], enabled: [.profiles, .bookmarks])
        try await journal.capture([], enabled: [.profiles])
        let children = await journal.items(enabled: [.bookmarks])
        let pending = await journal.pending(enabled: [.bookmarks])
        XCTAssertTrue(children.isEmpty)
        XCTAssertNotNil(pending.first?.deletion)
    }
    func testDuplicateBookmarkIdentityIsRetiredAfterDurableReadback() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        let first = item("page")
        var alias = first; alias.id = "alias"
        try await journal.capture([first, alias], enabled: [.bookmarks])
        try await journal.markApplied([first], enabled: [.bookmarks])
        let items = await journal.items(enabled: [.bookmarks])
        XCTAssertEqual(items.map(\.id), [first.id])
        let pending = await journal.pending(enabled: [.bookmarks])
        XCTAssertNotNil(pending.first(where: { $0.id == alias.id })?.deletion)
    }
    func testFailedCheckpointCannotClearPendingChanges() async throws {
        let directory = try root()
        let journal = try ICloudJournal(directory: directory, deviceID: "a")
        try await journal.capture([item("kept")], enabled: [.bookmarks])
        let pending = await journal.pending(enabled: [.bookmarks])
        let file = directory.appendingPathComponent("icloud-journal.json")
        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("saved-journal.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await journal.acknowledge(pending); XCTFail("Failed disk checkpoint must not acknowledge") } catch { }
        let stillPending = await journal.pending(enabled: [.bookmarks])
        XCTAssertEqual(stillPending, pending)
    }
    func testEqualEditVersionWithDifferentBytesStillMergesDeterministically() {
        let version = ICloudVersion(vector: ["a": 1], writer: "a", counter: 1)
        let a = ICloudRecord(category: .bookmarks, id: "same", profileID: nil, parentID: nil,
            fields: ["title": .init(value: Data("a".utf8), version: version)], deletion: nil)
        var b = a; b.fields["title"]?.value = Data("b".utf8)
        XCTAssertEqual(ICloudRecord.merged(a, b), ICloudRecord.merged(b, a))
    }
    func testInvalidDeletionVersionIsRejected() {
        let value = ICloudRecord(category: .bookmarks, id: "same", profileID: nil, parentID: nil,
            fields: [:], deletion: .init(vector: [:], writer: "", counter: 0))
        XCTAssertThrowsError(try value.validate())
    }
    func testSpaceOwnershipMoveRetiresOldIdentityAndCreatesNewProfileIdentity() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        let first = UUID(), second = UUID(), id = UUID().uuidString
        let space = ICloudItem(category: .spaces, id: id, profileID: first, parentID: nil, fields: ["name": Data("Work".utf8)])
        var moved = space; moved.profileID = second
        try await journal.capture([space], enabled: [.spaces])
        try await journal.capture([moved], enabled: [.spaces])
        let active = await journal.items(enabled: [.spaces])
        let retired = await journal.deleted(enabled: [.spaces])
        XCTAssertEqual(active, [moved])
        XCTAssertEqual(retired.first?.profileID, first)
        XCTAssertNotEqual(space.key, moved.key)
    }
    func testParentMoveVersionsRoutingWithoutChangingPayload() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        var value = item("page"); value.parentID = "one"
        try await journal.capture([value], enabled: [.bookmarks])
        let old = await journal.pending(enabled: [.bookmarks])
        value.parentID = "two"
        try await journal.capture([value], enabled: [.bookmarks])
        let pending = await journal.pending(enabled: [.bookmarks])
        XCTAssertEqual(pending.first?.item.parentID, "two")
        XCTAssertNotEqual(pending.first?.vector, old.first?.vector)
    }
    func testReadbackPromotesLateLocalEditsAndNewItemsInsteadOfSwallowingThem() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        try await journal.capture([item("before")], enabled: [.bookmarks])
        try await journal.acknowledge(await journal.pending(enabled: [.bookmarks]))
        var added = item("new", url: "https://new.example"); added.id = "late-created"
        try await journal.markApplied([item("late edit"), added], enabled: [.bookmarks])
        let current = await journal.items(enabled: [.bookmarks])
        XCTAssertEqual(Set(current.map(\.id)), ["bookmark-1", "late-created"])
        XCTAssertEqual(current.first { $0.id == "bookmark-1" }?.fields["title"], Data("late edit".utf8))
        let pending = await journal.pending(enabled: [.bookmarks])
        XCTAssertEqual(pending.count, 2)
    }
    func testAncestorInventoryFencesDeletionWithAllParentPayloadSwitchesOff() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        let profile = UUID(), space = UUID()
        let inventory = [ICloudDeletionFence(kind: .profile, profileID: profile, id: profile.uuidString),
                         ICloudDeletionFence(kind: .space, profileID: profile, id: space.uuidString)]
        try await journal.observeAncestorInventory(inventory)
        var child = item("page"); child.profileID = profile
        try await journal.capture([child], enabled: [.bookmarks])
        try await journal.observeAncestorInventory([])
        let fences = await journal.deletionFences()
        XCTAssertEqual(Set(fences.map(\.key)), Set(inventory.map(\.key)))
        let children = await journal.items(enabled: [.bookmarks])
        XCTAssertTrue(children.isEmpty)
        let fresh = try ICloudJournal(directory: root(), deviceID: "b")
        try await fresh.mergeFences(fences)
        try await fresh.capture([child], enabled: [.bookmarks])
        let stale = await fresh.items(enabled: [.bookmarks])
        XCTAssertTrue(stale.isEmpty, "A child-only fresh device cannot revive a deleted parent")
    }
    func testOwnerFieldPatchPreservesLateLocalEditAndIndependentRemoteField() async {
        let expected = item("before")
        var current = expected; current.fields["title"] = Data("local edit".utf8)
        let remote = item("before", url: "https://remote.example")
        await ICloudApplyContext.$baseline.withValue([expected.key: expected]) {
            let patch = ICloudApplyContext.reconcile(remote, current: current.fields)
            XCTAssertNil(patch.fields["title"])
            XCTAssertEqual(patch.fields["url"], remote.fields["url"])
        }
    }
    func testReadbackPromotesObservedLateLocalDeletionWithoutDeletingUnknownRemoteItems() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        try await journal.capture([item("observed local")], enabled: [.bookmarks])
        try await journal.acknowledge(await journal.pending(enabled: [.bookmarks]))
        var remote = await journal.pending(enabled: [.bookmarks])
        XCTAssertTrue(remote.isEmpty)
        let unseen = ICloudRecord(category: .bookmarks, id: "new-remote", profileID: nil, parentID: nil,
            fields: ["title": .init(value: Data("new".utf8), version: .init(vector: ["b": 1], writer: "b", counter: 1))], deletion: nil)
        _ = try await journal.merge([unseen])
        try await journal.markApplied([], enabled: [.bookmarks])
        let active = await journal.items(enabled: [.bookmarks])
        XCTAssertEqual(active.map(\.id), ["new-remote"])
        remote = await journal.pending(enabled: [.bookmarks])
        XCTAssertNotNil(remote.first { $0.id == "bookmark-1" }?.deletion)
        XCTAssertNil(remote.first { $0.id == "new-remote" }?.deletion)
    }
    func testIntentionalRecreationAfterObservedAbsenceSurvivesOldTombstone() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        let original = item("before")
        try await journal.capture([original], enabled: [.bookmarks])
        let first = await journal.pending(enabled: [.bookmarks])
        try await journal.capture([], enabled: [.bookmarks])
        let removed = await journal.pending(enabled: [.bookmarks])
        var recreated = item("after"); recreated.fields.removeValue(forKey: "url")
        try await journal.capture([recreated], enabled: [.bookmarks])
        _ = try await journal.merge(removed + first)
        let active = await journal.items(enabled: [.bookmarks])
        XCTAssertEqual(active, [recreated])
        XCTAssertNil(active.first?.fields["url"], "A prior incarnation cannot restore removed fields")
    }
    func testUnappliedFetchedTombstoneDoesNotCountAsObservedLocalAbsence() async throws {
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        let b = try ICloudJournal(directory: root(), deviceID: "b")
        let original = item("before")
        try await a.capture([original], enabled: [.bookmarks])
        _ = try await b.merge(await a.pending(enabled: [.bookmarks]))
        try await b.markApplied([original], enabled: [.bookmarks])
        try await a.capture([], enabled: [.bookmarks])
        _ = try await b.merge(await a.pending(enabled: [.bookmarks]))
        try await b.capture([original], enabled: [.bookmarks])
        let beforeApply = await b.items(enabled: [.bookmarks])
        XCTAssertTrue(beforeApply.isEmpty, "A failed/partial import cannot revive the old native row")
        try await b.markApplied([], enabled: [.bookmarks])
        try await b.capture([item("intentional re-add")], enabled: [.bookmarks])
        let recreated = await b.items(enabled: [.bookmarks])
        XCTAssertEqual(recreated.first?.fields["title"], Data("intentional re-add".utf8))
    }
    func testConcurrentDeleteStillWinsAgainstRebirthButLaterIntentionalAddWins() async throws {
        let a = try ICloudJournal(directory: root(), deviceID: "a")
        let b = try ICloudJournal(directory: root(), deviceID: "b")
        let original = item("before")
        try await a.capture([original], enabled: [.bookmarks])
        _ = try await b.merge(await a.pending(enabled: [.bookmarks]))
        try await b.markApplied([original], enabled: [.bookmarks])
        try await a.capture([], enabled: [.bookmarks])
        try await a.capture([item("re-added")], enabled: [.bookmarks])
        try await b.capture([], enabled: [.bookmarks])
        _ = try await a.merge(await b.pending(enabled: [.bookmarks]))
        let concurrent = await a.items(enabled: [.bookmarks])
        XCTAssertTrue(concurrent.isEmpty)
        try await a.markApplied([], enabled: [.bookmarks])
        try await a.capture([item("re-added after observing all deletes")], enabled: [.bookmarks])
        let later = await a.items(enabled: [.bookmarks])
        XCTAssertEqual(later.first?.fields["title"], Data("re-added after observing all deletes".utf8))
    }
    func testRecreationCannotOverridePermanentAncestorDeletionFence() async throws {
        let journal = try ICloudJournal(directory: root(), deviceID: "a")
        let profile = UUID()
        var child = item("page"); child.profileID = profile
        try await journal.capture([child], enabled: [.bookmarks])
        try await journal.mergeFences([.init(kind: .profile, profileID: profile, id: profile.uuidString)])
        try await journal.markApplied([], enabled: [.bookmarks])
        try await journal.capture([child], enabled: [.bookmarks])
        let active = await journal.items(enabled: [.bookmarks])
        XCTAssertTrue(active.isEmpty)
    }
    func testStaleTombstoneCannotEraseConcurrentDeletionInAnyDeliveryOrder() throws {
        let birth = ICloudVersion(vector: ["a": 11], writer: "a", counter: 11)
        let recreated = ICloudRecord(category: .bookmarks, id: "fixed", profileID: nil, parentID: nil,
            fields: ["title": .init(value: Data("recreated".utf8), version: birth)], deletion: nil, birthVersion: birth)
        var concurrent = recreated
        concurrent.fields = [:]; concurrent.birthVersion = nil
        concurrent.deletion = .init(vector: ["a": 1, "b": 2], writer: "b", counter: 2)
        var stale = concurrent
        stale.deletion = .init(vector: ["a": 10], writer: "a", counter: 10)
        let records = [recreated, concurrent, stale]
        for first in records.indices {
            for second in records.indices where second != first {
                let third = try XCTUnwrap(records.indices.first { $0 != first && $0 != second })
                for merged in [ICloudRecord.merged(ICloudRecord.merged(records[first], records[second]), records[third]),
                               ICloudRecord.merged(records[first], ICloudRecord.merged(records[second], records[third]))] {
                    try merged.validate()
                    XCTAssertNotNil(merged.deletion, "Order \(first),\(second),\(third) must preserve the unobserved concurrent deletion")
                    XCTAssertEqual(merged.deletion?.vector["b"], 2)
                    XCTAssertEqual(merged.vector, ["a": 11, "b": 2])
                }
            }
        }
    }
}
