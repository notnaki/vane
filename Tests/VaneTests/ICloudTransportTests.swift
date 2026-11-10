import XCTest
import CloudKit
@testable import vane

@MainActor
final class ICloudTransportTests: XCTestCase {
    func testIncrementalCursorMissLoadsExistingServerRecordAndPreservesItsRevision() async throws {
        let local = record()
        let zone = CKRecordZone.ID(zoneName: "cursor-test")
        let id = CKRecord.ID(recordName: ICloudIdentity.digest(local.key), zoneID: zone)
        var remote = local
        remote.fields["url"] = .init(value: Data("remote-only".utf8), version: .init(vector: ["b": 1], writer: "b", counter: 1))
        let server = try ICloudCloudRecordPayload.encode(remote, id: id, previous: nil, staging: nil)
        var reads = 0
        let loaded = try await ICloudServerRecordLookup.load(id: id, cached: nil) { requested in
            reads += 1; XCTAssertEqual(requested, id); return server
        }
        XCTAssertTrue(loaded === server)
        XCTAssertEqual(reads, 1)
        var bytes = 0
        let decoded = try ICloudCloudRecordPayload.decode(try XCTUnwrap(loaded), categoryZones: [.bookmarks: zone], transferredBytes: &bytes)
        let resolved = try ICloudTransportConflict.resolve(local: local, server: decoded)
        XCTAssertEqual(resolved.publication.fields["url"], remote.fields["url"])
        let publication = try ICloudCloudRecordPayload.encode(resolved.publication, id: id, previous: loaded, staging: nil)
        XCTAssertTrue(publication === server, "Saving must reuse the server record and its change tag")
        _ = try await ICloudServerRecordLookup.load(id: id, cached: server) { _ in
            XCTFail("A fetched server revision needs no duplicate lookup"); return server
        }
    }
    func testServerRecordLookupOnlyTreatsUnknownItemAsNewRecord() async throws {
        let id = CKRecord.ID(recordName: "new")
        let absent = try await ICloudServerRecordLookup.load(id: id, cached: nil) { _ in throw CKError(.unknownItem) }
        XCTAssertNil(absent)
        do {
            _ = try await ICloudServerRecordLookup.load(id: id, cached: nil) { _ in throw CKError(.networkFailure) }
            XCTFail("A failed lookup cannot become an insert")
        } catch let error as CKError { XCTAssertEqual(error.code, .networkFailure) }
    }
    func testInitialEngineSignInMatchesPreviouslyVerifiedAccountWithoutRevokingIt() {
        let current = CKRecord.ID(recordName: "current-test-account")
        let other = CKRecord.ID(recordName: "other-test-account")
        let expected = ICloudIdentity.digest(current.recordName)
        XCTAssertTrue(ICloudAccountChangeAdmission.accepts(.signIn(currentUser: current), expectedAccount: expected))
        XCTAssertFalse(ICloudAccountChangeAdmission.accepts(.signIn(currentUser: other), expectedAccount: expected))
        XCTAssertFalse(ICloudAccountChangeAdmission.accepts(.signIn(currentUser: current), expectedAccount: nil))
        XCTAssertFalse(ICloudAccountChangeAdmission.accepts(.signOut(previousUser: current), expectedAccount: expected))
        XCTAssertFalse(ICloudAccountChangeAdmission.accepts(.switchAccounts(previousUser: other, currentUser: current), expectedAccount: expected))
    }
    private func record(_ id: String = "one") -> ICloudRecord {
        ICloudRecord(category: .bookmarks, id: id, profileID: nil, parentID: nil,
                     fields: ["title": ICloudField(value: Data("title".utf8), version: ICloudVersion(vector: ["a": 1], writer: "a", counter: 1))], deletion: nil)
    }
    func testMissingEntitlementsNeverConstructsBackend() async {
        var constructed = false
        let transport = ICloudKitTransport(provisioning: { throw ICloudFailure.unavailable("Not provisioned") }, backend: { _ in
            constructed = true
            return MemoryCloudBackend()
        })
        do { _ = try await transport.account(); XCTFail("Unavailable build must fail before CloudKit access") }
        catch { XCTAssertFalse(constructed) }
    }
    func testEntitlementGateRejectsMissingProfileOrWildcardGrants() {
        for (containers, profile) in [(["iCloud.actual"], false), (["iCloud.*"], true)] {
            XCTAssertThrowsError(try ICloudProvisioning.validate(containers: containers, services: ["CloudKit"], environment: "Development",
                team: "ABCDE12345", application: "ABCDE12345.io.github.notnaki.vane", groups: ["ABCDE12345.io.github.notnaki.vane"],
                push: "development", profilePresent: profile))
        }
    }
    func testEntitlementGateAcceptsExactProvisionedApplication() throws {
        let configuration = try ICloudProvisioning.validate(containers: ["iCloud.actual"], services: ["CloudKit"], environment: "Production",
            team: "ABCDE12345", application: "ABCDE12345.io.github.notnaki.vane", groups: ["ABCDE12345.io.github.notnaki.vane"],
            push: "production", profilePresent: true)
        XCTAssertEqual(configuration.container, "iCloud.actual")
        XCTAssertEqual(configuration.keychainGroup, "ABCDE12345.io.github.notnaki.vane")
    }
    func testResetIsFetchedBeforeSendingAndPausesAffectedCategory() async throws {
        let backend = MemoryCloudBackend()
        backend.epochs = [.bookmarks: "new"]
        let transport = ICloudKitTransport(backend: backend)
        let result = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil,
                                                  epochs: [.bookmarks: "old"], persistState: { _ in })
        XCTAssertEqual(result.reset, [.bookmarks])
        XCTAssertTrue(backend.sent.isEmpty)
        XCTAssertEqual(backend.events.prefix(2), ["account", "controls"])
    }
    func testPartialAcknowledgementLeavesOtherRecordsPendingForRetry() async throws {
        let backend = MemoryCloudBackend()
        backend.saveLimit = 1
        let transport = ICloudKitTransport(backend: backend)
        let first = try await transport.exchange(pending: [record("a"), record("b")], enabled: [.bookmarks], state: nil,
                                                 epochs: [:], persistState: { _ in })
        XCTAssertEqual(first.acknowledged.count, 1)
        backend.saveLimit = 200
        let second = try await transport.exchange(pending: [record("b")], enabled: [.bookmarks], state: first.state,
                                                  epochs: first.epochs, persistState: { _ in })
        XCTAssertEqual(second.acknowledged.map(\.id), ["b"])
    }
    func testAccountSwitchBetweenRunsRejectsOldStateBeforeControlsOrSend() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        let initial = try await transport.exchange(pending: [], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
        backend.identity = "different"
        backend.events.removeAll()
        do {
            _ = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: initial.state,
                                              epochs: initial.epochs, persistState: { _ in })
            XCTFail("Account change must require deliberate merge")
        } catch ICloudFailure.accountChanged { }
        XCTAssertEqual(backend.events, ["account"])
    }
    func testRevokedExchangeCannotSendAfterFetchCompletes() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        backend.onFetch = { transport.revoke() }
        do {
            _ = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
            XCTFail("A disabled category cannot publish a stale fetch completion")
        } catch { }
        XCTAssertTrue(backend.sent.isEmpty)
    }
    func testAccountSwitchDuringFetchCannotSend() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        backend.onFetch = { backend.identity = "different" }
        do {
            _ = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
            XCTFail("Changed accounts cannot admit queued records")
        } catch ICloudFailure.accountChanged { }
        XCTAssertTrue(backend.sent.isEmpty)
    }
    func testResetDuringFetchIsRecheckedBeforeSending() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        backend.onFetch = { backend.epochs[.bookmarks] = "new" }
        let result = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
        XCTAssertEqual(result.reset, [.bookmarks])
        XCTAssertEqual(result.epochs[.bookmarks], "new")
        XCTAssertTrue(backend.sent.isEmpty)
    }
    func testUnknownSchemaFailsWithoutAcknowledgingOrSending() async throws {
        let backend = MemoryCloudBackend()
        backend.fetchError = ICloudFailure.unsupportedSchema
        let transport = ICloudKitTransport(backend: backend)
        do {
            _ = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
            XCTFail("Newer schema must remain visible")
        } catch ICloudFailure.unsupportedSchema { }
        XCTAssertTrue(backend.sent.isEmpty)
    }
    func testDisabledAndSecretCategoriesCannotReachBackend() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        var secret = record("secret"); secret.category = .passwords
        _ = try await transport.exchange(pending: [record(), secret], enabled: [.passwords], state: nil, epochs: [:], persistState: { _ in })
        XCTAssertTrue(backend.sent.isEmpty)
        XCTAssertTrue(backend.enabled.isEmpty)
    }
    func testStatePersistenceFailureStopsBeforeSending() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        do {
            _ = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in
                throw ICloudFailure.storage("Disk unavailable")
            })
            XCTFail("Durability failure must stop admission")
        } catch { }
        XCTAssertTrue(backend.sent.isEmpty)
    }
    func testFetchedFieldsAreMergedBeforePublishingWithCurrentServerRevision() async throws {
        let backend = MemoryCloudBackend()
        var remote = record()
        remote.fields["url"] = ICloudField(value: Data("remote".utf8), version: .init(vector: ["b": 1], writer: "b", counter: 1))
        backend.incoming = [remote]
        let transport = ICloudKitTransport(backend: backend)
        _ = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
        XCTAssertEqual(backend.sent.first?.fields["url"], remote.fields["url"])
    }
    func testInlinePayloadUsesEncryptedFieldsAndRejectsNewSchemaAndDamagedDigest() throws {
        let value = record()
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: ICloudIdentity.digest(value.key), zoneID: zone)
        let cloud = try ICloudCloudRecordPayload.encode(value, id: id, previous: nil, staging: nil)
        XCTAssertNil(cloud["payload"])
        XCTAssertNotNil(cloud.encryptedValues["payload"])
        var bytes = 0
        XCTAssertEqual(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.bookmarks: zone], transferredBytes: &bytes), value)
        cloud["schema"] = 3 as CKRecordValue
        XCTAssertThrowsError(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.bookmarks: zone], transferredBytes: &bytes)) { error in
            XCTAssertEqual(error as? ICloudFailure, .unsupportedSchema)
        }
        cloud["schema"] = 2 as CKRecordValue
        cloud.encryptedValues["digest"] = Data([0]) as CKRecordValue
        XCTAssertThrowsError(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.bookmarks: zone], transferredBytes: &bytes))
    }
    func testAssetPayloadIsContentAddressedAndValidatedBeforeDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var value = record()
        value.fields["title"]?.value = Data(repeating: 42, count: ICloudLimits.inlineBytes)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: ICloudIdentity.digest(value.key), zoneID: zone)
        let cloud = try ICloudCloudRecordPayload.encode(value, id: id, previous: nil, staging: directory)
        XCTAssertNil(cloud.encryptedValues["payload"])
        let asset = try XCTUnwrap(cloud["asset"] as? CKAsset)
        let path = try XCTUnwrap(asset.fileURL)
        XCTAssertEqual(path.lastPathComponent.count, 64)
        var bytes = 0
        XCTAssertEqual(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.bookmarks: zone], transferredBytes: &bytes), value)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try Data("damaged".utf8).write(to: path)
        XCTAssertThrowsError(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.bookmarks: zone], transferredBytes: &bytes))
    }
    func testPayloadCannotCrossCategoryZones() throws {
        let value = record()
        let zone = CKRecordZone.ID(zoneName: "wrong", ownerName: CKCurrentUserDefaultName)
        let cloud = try ICloudCloudRecordPayload.encode(value, id: .init(recordName: ICloudIdentity.digest(value.key), zoneID: zone), previous: nil, staging: nil)
        var bytes = 0
        XCTAssertThrowsError(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.history: zone], transferredBytes: &bytes))
    }
    func testEntityPayloadAdvertisesBirthAwareSchemaWhileReadingLegacyPayloads() throws {
        let value = record()
        let zone = CKRecordZone.ID(zoneName: "schema-test", ownerName: CKCurrentUserDefaultName)
        let id = CKRecord.ID(recordName: ICloudIdentity.digest(value.key), zoneID: zone)
        let cloud = try ICloudCloudRecordPayload.encode(value, id: id, previous: nil, staging: nil)
        XCTAssertEqual(cloud["schema"] as? Int, 2)
        cloud["schema"] = 1 as CKRecordValue
        var bytes = 0
        XCTAssertEqual(try ICloudCloudRecordPayload.decode(cloud, categoryZones: [.bookmarks: zone], transferredBytes: &bytes), value)
    }
    func testServerSaveConflictExposesBothRawEaselBranchesRegardlessOfWinner() async throws {
        for localWriter in ["a", "z"] {
            var local = record(); local.category = .easels
            local.fields["title"] = .init(value: Data("local board".utf8), version: .init(vector: [localWriter: 1], writer: localWriter, counter: 1))
            var server = local
            server.fields["title"] = .init(value: Data("server board".utf8), version: .init(vector: ["m": 1], writer: "m", counter: 1))
            let conflict = try ICloudTransportConflict.resolve(local: local, server: server)
            XCTAssertTrue(conflict.received.contains(local))
            XCTAssertTrue(conflict.received.contains(server))
            XCTAssertEqual(conflict.publication, ICloudRecord.merged(local, server))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let journal = try ICloudJournal(directory: directory, deviceID: "test")
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try await journal.merge([local])
            _ = try await journal.merge(conflict.received)
            let boards = await journal.items(enabled: [.easels])
            XCTAssertEqual(boards.count, 2)
            XCTAssertEqual(Set(boards.compactMap { $0.fields["title"] }), [Data("local board".utf8), Data("server board".utf8)])
        }
    }
    func testExplicitAccountRebindCanMergeWithoutRestartingTransport() async throws {
        let backend = MemoryCloudBackend()
        backend.enforceBinding = true
        let transport = ICloudKitTransport(backend: backend)
        let originalAccount = try await transport.account()
        XCTAssertEqual(originalAccount, "test-account")
        backend.identity = "different"
        do { _ = try await transport.account(); XCTFail("Implicit account changes must stay blocked") }
        catch ICloudFailure.accountChanged { }
        let rebound = try await transport.rebindAccount()
        XCTAssertEqual(rebound, "different")
        XCTAssertEqual(backend.discards, 1)
        let exchanged = try await transport.exchange(pending: [record()], enabled: [.bookmarks], state: nil, epochs: [:], persistState: { _ in })
        XCTAssertEqual(exchanged.acknowledged.count, 1)
    }
    func testOpaqueDeletionFencesExchangeWithoutParentPayloadCategories() async throws {
        let backend = MemoryCloudBackend()
        let transport = ICloudKitTransport(backend: backend)
        let fence = ICloudDeletionFence(kind: .space, profileID: UUID(), id: UUID().uuidString.lowercased())
        backend.fences = [fence]
        let received = try await transport.exchangeFences([])
        XCTAssertEqual(received, [fence])
        XCTAssertTrue(backend.enabled.isEmpty)
        XCTAssertTrue(backend.sent.isEmpty)
    }
    func testFenceCodecRejectsReadableIdentityOrDamagedRouting() throws {
        let invalid = ICloudDeletionFence(kind: .space, profileID: UUID(), id: "private space name")
        XCTAssertThrowsError(try ICloudFencePayload.encode(invalid))
        let profileID = UUID()
        let valid = ICloudDeletionFence(kind: .profile, profileID: profileID, id: profileID.uuidString.lowercased())
        let record = try ICloudFencePayload.encode(valid)
        XCTAssertNil(record["payload"])
        XCTAssertNotNil(record.encryptedValues["payload"])
        XCTAssertEqual(try ICloudFencePayload.decode(record), valid)
        record.encryptedValues["payload"] = Data("damaged".utf8) as CKRecordValue
        XCTAssertThrowsError(try ICloudFencePayload.decode(record))
    }
    func testHoldingBulkWorkerDoesNotBlockMainActor() async throws {
        let worker = ICloudTransportWorker()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        // A background deadline makes an accidental main-thread implementation fail
        // this assertion instead of leaving the test process permanently blocked.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { release.signal() }
        let operation = Task {
            await worker.perform {
                let wasMain = Thread.isMainThread
                started.signal()
                _ = release.wait(timeout: .now() + 3)
                return wasMain
            }
        }
        let waitForStarted: @Sendable () -> Void = { _ = started.wait(timeout: .now() + 1) }
        await Task.detached { waitForStarted() }.value
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        let workerWasMain = await operation.value
        XCTAssertFalse(workerWasMain)
    }
    private func removalDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRemovalPersistsReceiptBeforeCASAndResumesSameOldZoneAfterRestart() async throws {
        for failure in [RemovalServiceFailure.beforeCAS, .afterCAS, .beforeDelete, .afterDelete] {
            let directory = try removalDirectory()
            let service = MemoryRemovalService()
            let original = service.epoch
            service.fail = failure
            let journal = ICloudRemovalJournal(directory: directory)
            let coordinator = ICloudRemovalCoordinator(journal: journal)
            do { try await coordinator.request([.bookmarks], using: service); XCTFail("Injected interruption must remain pending") }
            catch { }
            let saved = try await journal.receipts()
            XCTAssertEqual(saved.count, 1)
            XCTAssertEqual(saved.first?.oldEpoch, original)
            let chosen = try XCTUnwrap(saved.first?.newEpoch)
            service.fail = nil
            let restarted = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: directory))
            try await restarted.request([.bookmarks], using: service)
            let pending = try await restarted.hasPending()
            XCTAssertFalse(pending)
            XCTAssertFalse(service.zones.contains(original))
            XCTAssertEqual(service.epoch, chosen)
            XCTAssertEqual(service.chosenEpochs, [chosen])
        }
    }
    func testRemovalReceiptSaveFailurePreventsEpochAdvanceOrDelete() async throws {
        let directory = try removalDirectory()
        let fault = RemovalWriteFault(); fault.arm()
        let journal = ICloudRemovalJournal(directory: directory, writer: { data, url in try fault.write(data, url) })
        let service = MemoryRemovalService()
        let coordinator = ICloudRemovalCoordinator(journal: journal)
        do { try await coordinator.request([.bookmarks], using: service); XCTFail("Receipt must be durable first") }
        catch { }
        XCTAssertTrue(service.chosenEpochs.isEmpty)
        XCTAssertTrue(service.deletedEpochs.isEmpty)
    }
    func testRemovalFinalCheckpointFailureRetriesIdempotentDeleteBeforeSuccess() async throws {
        let directory = try removalDirectory()
        let fault = RemovalWriteFault()
        let journal = ICloudRemovalJournal(directory: directory, writer: { data, url in try fault.write(data, url) })
        let service = MemoryRemovalService()
        let original = service.epoch
        service.afterDelete = { fault.arm() }
        let coordinator = ICloudRemovalCoordinator(journal: journal)
        do { try await coordinator.request([.bookmarks], using: service); XCTFail("Failed checkpoint cannot report success") }
        catch { }
        let pending = try await coordinator.hasPending()
        XCTAssertTrue(pending)
        XCTAssertFalse(service.zones.contains(original))
        service.afterDelete = nil
        let restarted = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: directory))
        try await restarted.resume(using: service)
        let remains = try await restarted.hasPending()
        XCTAssertFalse(remains)
        XCTAssertEqual(service.deletedEpochs, [original, original])
        XCTAssertEqual(service.chosenEpochs.count, 1)
    }
    func testRemovalAccountSwitchPreservesReceiptAndCannotDeleteAnotherAccount() async throws {
        let directory = try removalDirectory()
        let service = MemoryRemovalService()
        service.fail = .afterCAS
        let coordinator = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: directory))
        do { try await coordinator.request([.bookmarks], using: service); XCTFail("CAS interruption") } catch { }
        service.fail = nil
        service.identity = String(repeating: "b", count: 64)
        let restarted = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: directory))
        do { try await restarted.resume(using: service); XCTFail("Account mismatch must remain paused") }
        catch ICloudFailure.accountChanged { }
        let pending = try await restarted.hasPending()
        XCTAssertTrue(pending)
        XCTAssertTrue(service.deletedEpochs.isEmpty)
    }
    func testRemovalAccountSwitchDuringCASCannotDeleteInTheNewAccount() async throws {
        let directory = try removalDirectory()
        let service = MemoryRemovalService()
        service.afterAdvance = { service.identity = String(repeating: "b", count: 64) }
        let coordinator = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: directory))
        do { try await coordinator.request([.bookmarks], using: service); XCTFail("Account changed after CAS") }
        catch ICloudFailure.accountChanged { }
        XCTAssertTrue(service.deletedEpochs.isEmpty)
        let pending = try await coordinator.hasPending()
        XCTAssertTrue(pending)
    }
    func testNewRemovalAlsoFinishesEarlierPendingCategoriesBeforeSuccess() async throws {
        let directory = try removalDirectory()
        let service = MemoryRemovalService()
        let original = service.epoch
        service.fail = .beforeCAS
        let coordinator = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: directory))
        do { try await coordinator.request([.history], using: service); XCTFail("First removal interrupted") } catch { }
        service.fail = nil
        try await coordinator.request([.bookmarks], using: service)
        let pending = try await coordinator.hasPending()
        XCTAssertFalse(pending)
        XCTAssertFalse(service.zones.contains(original))
        XCTAssertEqual(service.deletedEpochs.count, 2)
    }
    func testEmptyRemovalInspectionAndResumeNeverCreatesBackend() async throws {
        var constructed = false
        let transport = ICloudKitTransport(removalDirectory: try removalDirectory(), provisioning: {
            throw ICloudFailure.unavailable("No provisioning")
        }, backend: { _ in constructed = true; return MemoryCloudBackend() })
        let pending = try await transport.hasPendingRemovals()
        XCTAssertFalse(pending)
        try await transport.resumeRemovals()
        XCTAssertFalse(constructed)
    }
}

private enum RemovalServiceFailure: Equatable { case beforeCAS, afterCAS, beforeDelete, afterDelete }
@MainActor private final class MemoryRemovalService: ICloudRemovalService {
    var identity = String(repeating: "a", count: 64)
    var epoch = UUID().uuidString
    var zones = Set<String>()
    var fail: RemovalServiceFailure?
    var chosenEpochs = Set<String>()
    var deletedEpochs: [String] = []
    var afterDelete: (() -> Void)?
    var afterAdvance: (() -> Void)?
    init() { zones.insert(epoch) }
    func account() async throws -> String { identity }
    func controls(_ categories: Set<ICloudCategory>) async throws -> [ICloudCategory: String] {
        Dictionary(uniqueKeysWithValues: categories.map { ($0, epoch) })
    }
    func advanceRemoval(_ receipt: ICloudRemovalReceipt) async throws {
        if fail == .beforeCAS { throw ICloudFailure.storage("Interrupted before CAS") }
        if epoch == receipt.oldEpoch { epoch = receipt.newEpoch; chosenEpochs.insert(epoch); zones.insert(epoch) }
        afterAdvance?()
        if fail == .afterCAS { throw ICloudFailure.storage("Interrupted after CAS") }
    }
    func deleteRemoval(_ receipt: ICloudRemovalReceipt) async throws {
        if fail == .beforeDelete { throw ICloudFailure.storage("Interrupted before delete") }
        zones.remove(receipt.oldEpoch); deletedEpochs.append(receipt.oldEpoch)
        afterDelete?()
        if fail == .afterDelete { throw ICloudFailure.storage("Interrupted after delete") }
    }
}
private final class RemovalWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func write(_ data: Data, _ url: URL) throws {
        let fail = lock.withLock { let result = armed; armed = false; return result }
        if fail { throw ICloudFailure.storage("Interrupted journal write") }
        try BackupIO.write(data, url)
    }
}

@MainActor
private final class MemoryCloudBackend: ICloudTransportBackend {
    var identity = "test-account"
    var epochs: [ICloudCategory: String] = [:]
    var sent: [ICloudRecord] = []
    var events: [String] = []
    var enabled = Set<ICloudCategory>()
    var saveLimit = 200
    var fetchError: ICloudFailure?
    var incoming: [ICloudRecord] = []
    var onFetch: (() -> Void)?
    var enforceBinding = false
    var boundIdentity: String?
    var discards = 0
    var fences: [ICloudDeletionFence] = []
    func discardAccount() async { discards += 1; boundIdentity = nil }
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence] { fences += outgoing; return fences }
    func account() async throws -> String {
        events.append("account")
        if enforceBinding, let boundIdentity, boundIdentity != identity { throw ICloudFailure.accountChanged }
        boundIdentity = identity
        return identity
    }
    func controls(_ categories: Set<ICloudCategory>) async throws -> [ICloudCategory: String] {
        events.append("controls"); enabled = categories
        return Dictionary(uniqueKeysWithValues: categories.map { ($0, epochs[$0] ?? "initial") })
    }
    func fetch(enabled: Set<ICloudCategory>, epochs: [ICloudCategory: String], state: Data?, persist: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudBackendExchange {
        events.append("fetch")
        onFetch?()
        if let fetchError { throw fetchError }
        try await persist(Data("state".utf8))
        return ICloudBackendExchange(received: incoming, acknowledged: [], state: Data("state".utf8))
    }
    func send(_ records: [ICloudRecord], enabled: Set<ICloudCategory>, epochs: [ICloudCategory: String]) async throws -> ICloudBackendExchange {
        events.append("send"); sent += records
        return ICloudBackendExchange(received: [], acknowledged: Array(records.prefix(saveLimit)), state: Data("state".utf8))
    }
    func remove(_ categories: Set<ICloudCategory>) async throws { events.append("remove") }
}
