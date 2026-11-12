import Foundation
import CloudKit
import CryptoKit
import Security

struct ICloudProvisioning: Sendable {
    let container: String
    let environment: String
    let keychainGroup: String

    static func current() throws -> Self {
        guard let task = SecTaskCreateFromSelf(nil) else { throw ICloudFailure.unavailable("This build has no verified signing entitlements.") }
        func value(_ key: String) -> Any? { SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
        return try validate(
            containers: value("com.apple.developer.icloud-container-identifiers") as? [String],
            services: value("com.apple.developer.icloud-services") as? [String],
            environment: value("com.apple.developer.icloud-container-environment") as? String,
            team: value("com.apple.developer.team-identifier") as? String,
            application: value("com.apple.application-identifier") as? String,
            groups: value("keychain-access-groups") as? [String],
            push: value("com.apple.developer.aps-environment") as? String,
            profilePresent: FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/embedded.provisionprofile").path))
    }
    static func validate(containers: [String]?, services: [String]?, environment: String?, team: String?,
                         application: String?, groups: [String]?, push: String?, profilePresent: Bool) throws -> Self {
        guard profilePresent, let containers, containers.count == 1, let container = containers.first,
              container.hasPrefix("iCloud."), !container.contains("*"), services?.contains("CloudKit") == true,
              let environment, ["Development", "Production"].contains(environment),
              let team, !team.isEmpty, !team.contains("*"),
              application == team + ".io.github.notnaki.vane",
              let groups, groups.contains(team + ".io.github.notnaki.vane"),
              let push, ["development", "production"].contains(push) else {
            throw ICloudFailure.unavailable("iCloud sync needs a provisioned Vane build. This local build keeps your data on this Mac.")
        }
        return Self(container: container, environment: environment, keychainGroup: team + ".io.github.notnaki.vane")
    }
}

struct ICloudBackendExchange: Sendable {
    var received: [ICloudRecord]
    var acknowledged: [ICloudRecord]
    var state: Data?
}

@MainActor protocol ICloudTransportBackend: ICloudRemovalService {
    func account() async throws -> String
    func controls(_ categories: Set<ICloudCategory>) async throws -> [ICloudCategory: String]
    func fetch(enabled: Set<ICloudCategory>, epochs: [ICloudCategory: String], state: Data?,
               persist: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudBackendExchange
    func send(_ records: [ICloudRecord], enabled: Set<ICloudCategory>, epochs: [ICloudCategory: String]) async throws -> ICloudBackendExchange
    func discardAccount() async
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence]
    func revoke()
}
extension ICloudTransportBackend {
    func revoke() {}
    func discardAccount() async { revoke() }
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence] { [] }
    func advanceRemoval(_ receipt: ICloudRemovalReceipt) async throws { throw ICloudFailure.unavailable("This transport cannot remove CloudKit data.") }
    func deleteRemoval(_ receipt: ICloudRemovalReceipt) async throws { throw ICloudFailure.unavailable("This transport cannot remove CloudKit data.") }
}

/// Synchronous bulk work runs on this actor's executor, away from the UI actor.
actor ICloudTransportWorker {
    func perform<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> Value { try operation() }
}

enum ICloudTransportConflict {
    struct Resolution: Sendable { var publication: ICloudRecord; var received: [ICloudRecord] }
    static func resolve(local: ICloudRecord, server: ICloudRecord) throws -> Resolution {
        guard local.key == server.key, local.profileID == server.profileID else {
            throw ICloudFailure.invalid("An iCloud conflict changed identity.")
        }
        try local.validate(); try server.validate()
        let merged = ICloudRecord.merged(local, server)
        // Deliver raw branches before the merged publication. The journal needs
        // both concurrent Easels to preserve whichever board loses the tie-break.
        return Resolution(publication: merged, received: [server, local, merged])
    }
}

/// Incremental fetches do not repeat unchanged records. A cache miss therefore
/// needs an explicit lookup; only unknownItem authorizes creating a new record.
@MainActor enum ICloudServerRecordLookup {
    static func load(id: CKRecord.ID, cached: CKRecord?,
                     fetch: (CKRecord.ID) async throws -> CKRecord) async throws -> CKRecord? {
        if let cached { return cached }
        do { return try await fetch(id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }
}

enum ICloudAccountChangeAdmission {
    static func accepts(_ change: CKSyncEngine.Event.AccountChange.ChangeType, expectedAccount: String?) -> Bool {
        guard let expectedAccount else { return false }
        // A new engine announces the account that account() already verified.
        // This initial association is not consent to change an existing binding.
        if case .signIn(let currentUser) = change {
            return ICloudIdentity.digest(currentUser.recordName) == expectedAccount
        }
        return false
    }
}

/// Owns admission and the account envelope. The backend is created lazily only after
/// checking this executable's signed entitlements; even account queries use that gate.
@MainActor final class ICloudKitTransport: ICloudTransport {
    private struct State: Codable, Sendable {
        var schema = 1
        var account: String
        var backend: Data?
    }
    private var backend: (any ICloudTransportBackend)?
    private let provisioning: () throws -> ICloudProvisioning
    private let factory: (ICloudProvisioning) -> any ICloudTransportBackend
    private let rebuildInjected: (() -> any ICloudTransportBackend)?
    private var generation: UInt64 = 0
    private var busy = false
    private let worker = ICloudTransportWorker()
    private let removals: ICloudRemovalCoordinator

    init(removalDirectory: URL = Store.directory) {
        provisioning = ICloudProvisioning.current
        factory = { CloudKitSyncBackend(provisioning: $0) }
        rebuildInjected = nil
        removals = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: removalDirectory))
    }
    init(removalDirectory: URL = Store.directory, provisioning: @escaping () throws -> ICloudProvisioning,
         backend: @escaping (ICloudProvisioning) -> any ICloudTransportBackend) {
        self.provisioning = provisioning; factory = backend
        rebuildInjected = nil
        removals = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: removalDirectory))
    }
    init(backend: any ICloudTransportBackend, removalDirectory: URL = Store.directory) {
        self.backend = backend
        provisioning = { throw ICloudFailure.unavailable("Injected transport has no provisioning.") }
        factory = { _ in backend }
        rebuildInjected = { backend }
        removals = ICloudRemovalCoordinator(journal: ICloudRemovalJournal(directory: removalDirectory))
    }
    private func service() throws -> any ICloudTransportBackend {
        if let backend { return backend }
        if let rebuildInjected {
            let value = rebuildInjected()
            backend = value
            return value
        }
        let configuration = try provisioning()
        let value = factory(configuration)
        backend = value
        return value
    }
    static func capability() -> Result<ICloudProvisioning, ICloudFailure> {
        do { return .success(try .current()) }
        catch let error as ICloudFailure { return .failure(error) }
        catch { return .failure(.unavailable("iCloud signing entitlements could not be verified.")) }
    }
    func revoke() { generation &+= 1; backend?.revoke() }
    func account() async throws -> String { try await service().account() }
    /// The controller calls this only after the user explicitly consents to merge
    /// with a different account and after draining the revoked exchange task.
    func rebindAccount() async throws -> String {
        revoke()
        guard !busy else { throw ICloudFailure.unavailable("Wait for the previous iCloud operation to stop before changing accounts.") }
        busy = true; defer { busy = false }
        let ticket = generation
        if let backend { await backend.discardAccount() }
        try check(ticket)
        backend = nil
        let identity = try await service().account()
        try check(ticket)
        return identity
    }
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence] {
        guard !busy else { throw ICloudFailure.unavailable("An iCloud operation is already running.") }
        busy = true; defer { busy = false }
        let ticket = generation
        let backend = try service()
        let identity = try await backend.account()
        try check(ticket)
        try await worker.perform {
            guard outgoing.count <= ICloudFencePayload.maximumCount else { throw ICloudFailure.limitExceeded }
            for fence in outgoing { try fence.validate() }
        }
        try check(ticket)
        let incoming = try await backend.exchangeFences(outgoing)
        try check(ticket)
        guard try await backend.account() == identity else { revoke(); throw ICloudFailure.accountChanged }
        try check(ticket)
        let validated = try await worker.perform {
            guard incoming.count <= ICloudFencePayload.maximumCount else { throw ICloudFailure.limitExceeded }
            for fence in incoming { try fence.validate() }
            return incoming
        }
        try check(ticket)
        return validated
    }
    func exchange(pending: [ICloudRecord], enabled: Set<ICloudCategory>, state: Data?,
                  epochs: [ICloudCategory: String], persistState: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudExchange {
        guard !busy else { throw ICloudFailure.unavailable("An iCloud operation is already running.") }
        busy = true; defer { busy = false }
        let ticket = generation
        let backend = try service()
        let identity = try await backend.account()
        try check(ticket)
        let old: State?
        if let state {
            old = try await worker.perform { try JSONDecoder().decode(State.self, from: state) }
            try check(ticket)
            guard old?.schema == 1 else { throw ICloudFailure.unsupportedSchema }
            guard old?.account == identity else { throw ICloudFailure.accountChanged }
        } else { old = nil }
        let categories = enabled.filter { !$0.isSecret }
        let current = try await backend.controls(categories)
        try check(ticket)
        let reset = Set(categories.filter { epochs[$0] != nil && epochs[$0] != current[$0] })
        let admitted = categories.subtracting(reset)
        // Persist account binding before any mutation. Engine tokens from fetch are
        // returned to the controller, which commits them only after incoming merges.
        let bound = try await worker.perform { try JSONEncoder().encode(State(account: identity, backend: old?.backend)) }
        try check(ticket)
        try await persistState(bound)
        try check(ticket)
        let fetched = try await backend.fetch(enabled: admitted, epochs: current, state: old?.backend, persist: { _ in })
        try check(ticket)
        guard try await backend.account() == identity else { revoke(); throw ICloudFailure.accountChanged }
        try check(ticket)
        let checked = try await backend.controls(admitted)
        try check(ticket)
        let changed = Set(admitted.filter { checked[$0] != current[$0] })
        let active = admitted.subtracting(changed)
        let outgoing = try await worker.perform {
            var remoteByKey: [String: ICloudRecord] = [:]
            for record in fetched.received where active.contains(record.category) {
                try record.validate()
                remoteByKey[record.key] = remoteByKey[record.key].map { ICloudRecord.merged($0, record) } ?? record
            }
            let outgoing = try pending.filter { active.contains($0.category) }.map { local in
                guard let remote = remoteByKey[local.key] else { return local }
                guard local.profileID == remote.profileID else { throw ICloudFailure.invalid("An iCloud item changed profile ownership.") }
                return ICloudRecord.merged(local, remote)
            }
            var bytes = try fetched.received.reduce(0) { try $0 + JSONEncoder().encode($1).count }
            guard bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            for record in outgoing {
                try record.validate()
                let size = try JSONEncoder().encode(record).count
                guard size <= ICloudLimits.assetBytes else { throw ICloudFailure.limitExceeded }
                bytes += size
                guard bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            }
            return outgoing
        }
        try check(ticket)
        var sent = ICloudBackendExchange(received: [], acknowledged: [], state: fetched.state)
        if !outgoing.isEmpty { sent = try await backend.send(outgoing, enabled: active, epochs: current) }
        try check(ticket)
        let backendState = sent.state ?? fetched.state
        let finalState = try await worker.perform { try JSONEncoder().encode(State(account: identity, backend: backendState)) }
        try check(ticket)
        var finalEpochs = current
        for (category, epoch) in checked { finalEpochs[category] = epoch }
        return ICloudExchange(received: (fetched.received + sent.received).filter { active.contains($0.category) },
                              acknowledged: sent.acknowledged, state: finalState, reset: reset.union(changed), epochs: finalEpochs)
    }
    private func check(_ ticket: UInt64) throws {
        guard ticket == generation else { throw ICloudFailure.unavailable("iCloud choices changed. Pending work has been kept.") }
    }
    func remove(_ categories: Set<ICloudCategory>) async throws {
        revoke()
        guard !busy else { throw ICloudFailure.unavailable("Wait for the current iCloud operation to stop before removing data.") }
        busy = true; defer { busy = false }
        let ticket = generation
        let backend = try service()
        try await removals.request(categories, using: backend, admitted: { try self.check(ticket) })
        try check(ticket)
    }
    func hasPendingRemovals() async throws -> Bool {
        try await removals.hasPending()
    }
    func resumeRemovals() async throws {
        // A fresh/master-off app must not instantiate CKContainer, inspect the
        // Apple Account, or invent a removal request merely to inspect local state.
        guard try await removals.hasPending() else { return }
        revoke()
        guard !busy else { throw ICloudFailure.unavailable("Wait for the current iCloud operation to stop before retrying removal.") }
        busy = true; defer { busy = false }
        let ticket = generation
        let backend = try service()
        try await removals.resume(using: backend, admitted: { try self.check(ticket) })
        try check(ticket)
    }
}

@MainActor private final class CloudKitSyncBackend: ICloudTransportBackend, CKSyncEngineDelegate {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private var engine: CKSyncEngine?
    private var received: [ICloudRecord] = []
    private var acknowledged: [ICloudRecord] = []
    private var queued: [CKRecord.ID: CKRecord] = [:]
    private var originals: [CKRecord.ID: ICloudRecord] = [:]
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]
    private var engineState: Data?
    private var failure: (any Error)?
    private var transferredBytes = 0
    private var admittedZones = Set<CKRecordZone.ID>()
    private var categoryZones: [ICloudCategory: CKRecordZone.ID] = [:]
    private var activeAccount: String?
    private var revoked = false
    private var generation: UInt64 = 0
    private var expectedEpochs: [ICloudCategory: String] = [:]
    private var staging: URL?
    private let worker = ICloudTransportWorker()
    private static let controlZone = ICloudFencePayload.zone

    init(provisioning: ICloudProvisioning) {
        // This initializer is reached only through the verified entitlement gate.
        container = CKContainer(identifier: provisioning.container)
    }
    func revoke() {
        generation &+= 1
        revoked = true
        queued.removeAll(); originals.removeAll()
        if let engine { Task { await engine.cancelOperations() } }
    }
    func discardAccount() async {
        revoke()
        if let engine { await engine.cancelOperations() }
        engine = nil; engineState = nil; activeAccount = nil
        received = []; acknowledged = []; queued = [:]; originals = [:]; serverRecords = [:]
        admittedZones = []; categoryZones = [:]; expectedEpochs = [:]; failure = nil
    }
    func account() async throws -> String {
        let ticket = generation
        let status = try await container.accountStatus()
        try check(ticket)
        guard status == .available else {
            throw ICloudFailure.unavailable("Sign in to an Apple Account with iCloud available, then retry.")
        }
        let id = try await container.userRecordID()
        try check(ticket)
        let identity = await worker.perform { ICloudIdentity.digest(id.recordName) }
        try check(ticket)
        if let activeAccount, activeAccount != identity { revoke(); throw ICloudFailure.accountChanged }
        activeAccount = identity
        return identity
    }
    private static func controlID(_ category: ICloudCategory) -> CKRecord.ID {
        CKRecord.ID(recordName: ICloudIdentity.digest(category.rawValue), zoneID: controlZone)
    }
    private static func zone(_ category: ICloudCategory, epoch: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "vane-" + ICloudIdentity.digest(category.rawValue + ":" + epoch), ownerName: CKCurrentUserDefaultName)
    }
    private func control(_ category: ICloudCategory) async throws -> CKRecord {
        let ticket = generation
        let id = Self.controlID(category)
        do {
            let record = try await database.record(for: id)
            try check(ticket)
            try validateControl(record)
            return record
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: "VaneControl", recordID: id)
            record["schema"] = 1 as CKRecordValue
            record["epoch"] = UUID().uuidString as CKRecordValue
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            try check(ticket)
            guard let saved = result.saveResults[id] else { throw ICloudFailure.storage("CloudKit did not acknowledge namespace creation.") }
            do { return try saved.get() }
            catch let conflict as CKError where conflict.code == .serverRecordChanged {
                guard let current = conflict.serverRecord else { throw conflict }
                try validateControl(current); return current
            }
        }
    }
    private func validateControl(_ record: CKRecord) throws {
        guard record.recordType == "VaneControl", record["schema"] as? Int == 1 else { throw ICloudFailure.unsupportedSchema }
        guard let epoch = record["epoch"] as? String, UUID(uuidString: epoch) != nil else {
            throw ICloudFailure.invalid("An iCloud namespace marker is invalid.")
        }
    }
    func controls(_ categories: Set<ICloudCategory>) async throws -> [ICloudCategory: String] {
        let ticket = generation
        guard !categories.isEmpty else { return [:] }
        _ = try await database.save(CKRecordZone(zoneID: Self.controlZone))
        try check(ticket)
        var result: [ICloudCategory: String] = [:]
        for category in categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            let record = try await control(category)
            try check(ticket)
            result[category] = record["epoch"] as? String
        }
        return result
    }
    func fetch(enabled: Set<ICloudCategory>, epochs: [ICloudCategory: String], state: Data?,
               persist: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudBackendExchange {
        let ticket = generation
        if let engine { await engine.cancelOperations() }
        try check(ticket)
        received = []; acknowledged = []; queued = [:]; originals = [:]; serverRecords = [:]
        failure = nil; transferredBytes = 0; revoked = false; engineState = state
        categoryZones = Dictionary(uniqueKeysWithValues: enabled.compactMap { category in epochs[category].map { (category, Self.zone(category, epoch: $0)) } })
        admittedZones = Set(categoryZones.values)
        let serialized = try await worker.perform {
            try state.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        }
        try check(ticket)
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialized, delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        // Persisted pending changes are reconstructed from the durable journal only;
        // stale engine saves must never be admitted by a newly enabled namespace.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        guard !admittedZones.isEmpty else { return result() }
        for zone in admittedZones {
            try check(ticket)
            _ = try await database.save(CKRecordZone(zoneID: zone))
            try check(ticket)
        }
        try await engine.fetchChanges(.init(scope: .zoneIDs(Array(admittedZones))))
        try check(ticket)
        try throwFailure()
        return result()
    }
    func send(_ records: [ICloudRecord], enabled: Set<ICloudCategory>, epochs: [ICloudCategory: String]) async throws -> ICloudBackendExchange {
        let ticket = generation
        guard let engine, !revoked else { throw ICloudFailure.unavailable("iCloud work was cancelled.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-cloud-assets-" + UUID().uuidString, isDirectory: true)
        defer {
            let worker = worker
            Task { await worker.perform { try? FileManager.default.removeItem(at: directory) } }
            staging = nil; queued = [:]; originals = [:]
        }
        try await worker.perform {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try check(ticket)
        staging = directory
        expectedEpochs = epochs.filter { enabled.contains($0.key) }
        for record in records {
            guard enabled.contains(record.category), let epoch = epochs[record.category] else { continue }
            let name = await worker.perform { ICloudIdentity.digest(record.key) }
            try check(ticket)
            let id = CKRecord.ID(recordName: name, zoneID: Self.zone(record.category, epoch: epoch))
            guard admittedZones.contains(id.zoneID) else { throw ICloudFailure.invalid("iCloud namespace admission changed.") }
            let previous = try await ICloudServerRecordLookup.load(id: id, cached: serverRecords[id]) {
                try await self.database.record(for: $0)
            }
            try check(ticket)
            var publication = record
            if let previous {
                let remote = try await decode(previous)
                try check(ticket)
                let conflict = try await worker.perform { try ICloudTransportConflict.resolve(local: record, server: remote) }
                try check(ticket)
                received += conflict.received
                publication = conflict.publication
            }
            originals[id] = publication
            queued[id] = try await encode(publication, id: id, previous: previous)
            try check(ticket)
        }
        engine.state.add(pendingRecordZoneChanges: queued.keys.map { .saveRecord($0) })
        try await engine.sendChanges(.init(scope: .zoneIDs(Array(admittedZones))))
        try check(ticket)
        try throwFailure()
        return result()
    }
    private func result() -> ICloudBackendExchange { .init(received: received, acknowledged: acknowledged, state: engineState) }
    private func throwFailure() throws {
        if let failure { throw failure }
        guard !revoked else { throw ICloudFailure.unavailable("iCloud work was cancelled.") }
    }
    private func check(_ ticket: UInt64) throws {
        guard ticket == generation else { throw ICloudFailure.unavailable("iCloud choices changed. Pending work has been kept.") }
    }
    private func encode(_ value: ICloudRecord, id: CKRecord.ID, previous: CKRecord?) async throws -> CKRecord {
        let staging = staging
        let prepared = try await worker.perform {
            let record = try ICloudCloudRecordPayload.encode(value, id: id, previous: previous, staging: staging)
            return (record, try JSONEncoder().encode(value).count)
        }
        transferredBytes += prepared.1
        guard transferredBytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
        return prepared.0
    }
    private func decode(_ record: CKRecord) async throws -> ICloudRecord {
        let zones = categoryZones
        let decoded = try await worker.perform {
            var bytes = 0
            let value = try ICloudCloudRecordPayload.decode(record, categoryZones: zones, transferredBytes: &bytes)
            return (value, bytes)
        }
        transferredBytes += decoded.1
        guard transferredBytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
        return decoded.0
    }
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await consume(event, engine: syncEngine)
    }
    private func consume(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard self.engine === engine else { return }
        let ticket = generation
        do {
            switch event {
            case .stateUpdate(let update):
                let data = try await worker.perform { try JSONEncoder().encode(update.stateSerialization) }
                try check(ticket)
                engineState = data
            case .accountChange(let change):
                if !ICloudAccountChangeAdmission.accepts(change.changeType, expectedAccount: activeAccount) {
                    failure = ICloudFailure.accountChanged; revoke()
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications {
                    let value = try await decode(modification.record)
                    try check(ticket)
                    received.append(value); serverRecords[modification.record.recordID] = modification.record
                }
                // Entity deletions are tombstones. Physical deletions are only legal
                // after an epoch reset; active-zone deletion cannot erase local data.
                if !changes.deletions.isEmpty { throw ICloudFailure.invalid("iCloud contains an unexpected physical deletion. Pending data was kept.") }
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    if let value = originals[record.recordID] { acknowledged.append(value) }
                    queued.removeValue(forKey: record.recordID)
                }
                for failed in changes.failedRecordSaves {
                    if failed.error.code == .serverRecordChanged, let server = failed.error.serverRecord,
                       let local = originals[failed.record.recordID] {
                        let remote = try await decode(server)
                        try check(ticket)
                        let conflict = try await worker.perform { try ICloudTransportConflict.resolve(local: local, server: remote) }
                        try check(ticket)
                        received += conflict.received
                        originals[failed.record.recordID] = conflict.publication
                        queued[failed.record.recordID] = try await encode(conflict.publication, id: failed.record.recordID, previous: server)
                        try check(ticket)
                        engine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    } else { failure = failed.error }
                }
                if let error = changes.failedRecordDeletes.values.first { failure = error }
            case .sentDatabaseChanges(let changes):
                if let error = changes.failedZoneSaves.first?.error ?? changes.failedZoneDeletes.values.first { failure = error }
            case .didFetchRecordZoneChanges(let change): if let error = change.error { failure = error }
            default: break
            }
        } catch { failure = error }
    }
    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await batch(context, engine: syncEngine)
    }
    private func batch(_ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard self.engine === engine, !revoked, failure == nil else { return nil }
        let ticket = generation
        do {
            _ = try await account()
            try check(ticket)
            let current = try await controls(Set(expectedEpochs.keys))
            try check(ticket)
            guard current == expectedEpochs else {
                throw ICloudFailure.unavailable("iCloud data was removed on another Mac. Re-enable the affected categories after review.")
            }
        } catch { failure = error; return nil }
        let records = engine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord? in
            guard context.options.scope.contains(change), case .saveRecord(let id) = change, admittedZones.contains(id.zoneID) else { return nil }
            return queued[id]
        }
        guard !records.isEmpty else { return nil }
        return .init(recordsToSave: Array(records.prefix(ICloudLimits.batchCount)), atomicByZone: false)
    }
    func exchangeFences(_ outgoing: [ICloudDeletionFence]) async throws -> [ICloudDeletionFence] {
        let ticket = generation
        let identity = try await account()
        try check(ticket)
        let prepared = try await worker.perform {
            guard outgoing.count <= ICloudFencePayload.maximumCount else { throw ICloudFailure.limitExceeded }
            return try outgoing.map { try ICloudFencePayload.encode($0) }
        }
        try check(ticket)
        _ = try await database.save(CKRecordZone(zoneID: Self.controlZone))
        try check(ticket)
        var fences: [String: ICloudDeletionFence] = [:]
        var bytes = 0
        var cursor: CKQueryOperation.Cursor?
        var pageCount = 0
        repeat {
            guard try await account() == identity else { throw ICloudFailure.accountChanged }
            try check(ticket)
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await database.records(continuingMatchFrom: cursor, resultsLimit: ICloudLimits.batchCount)
            } else {
                let query = CKQuery(recordType: "VaneDeletionFence", predicate: NSPredicate(value: true))
                page = try await database.records(matching: query, inZoneWith: Self.controlZone, resultsLimit: ICloudLimits.batchCount)
            }
            try check(ticket)
            let records = try page.matchResults.map { try $0.1.get() }
            let decoded = try await worker.perform {
                try records.map { (try ICloudFencePayload.decode($0), ($0.encryptedValues["payload"] as? Data)?.count ?? 0) }
            }
            try check(ticket)
            for (fence, size) in decoded {
                fences[fence.key] = fence; bytes += size
                guard fences.count <= ICloudFencePayload.maximumCount, bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            }
            pageCount += 1
            guard pageCount <= 1_000 else { throw ICloudFailure.limitExceeded }
            cursor = page.queryCursor
        } while cursor != nil
        let existingKeys = Set(fences.keys)
        let fetchedBytes = bytes
        try await worker.perform {
            let allKeys = existingKeys.union(outgoing.map(\.key))
            let sendBytes = prepared.reduce(0) { $0 + (($1.encryptedValues["payload"] as? Data)?.count ?? 0) }
            guard allKeys.count <= ICloudFencePayload.maximumCount,
                  fetchedBytes + sendBytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
        }
        try check(ticket)
        // Permanent fences are immutable. A concurrent identical creation is safe;
        // any mismatched record remains a visible validation failure.
        for offset in stride(from: 0, to: prepared.count, by: ICloudLimits.batchCount) {
            guard try await account() == identity else { throw ICloudFailure.accountChanged }
            try check(ticket)
            let batch = Array(prepared[offset..<min(offset + ICloudLimits.batchCount, prepared.count)])
            let result = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            try check(ticket)
            var confirmed: [CKRecord] = []
            for record in batch {
                guard let saved = result.saveResults[record.recordID] else { throw ICloudFailure.storage("CloudKit did not acknowledge a deletion fence.") }
                do { confirmed.append(try saved.get()) }
                catch let error as CKError where error.code == .serverRecordChanged {
                    guard let server = error.serverRecord, server.recordID == record.recordID else { throw error }
                    confirmed.append(server)
                }
            }
            let confirmations = confirmed
            let decoded = try await worker.perform {
                try confirmations.map { (try ICloudFencePayload.decode($0), ($0.encryptedValues["payload"] as? Data)?.count ?? 0) }
            }
            try check(ticket)
            for (fence, size) in decoded {
                fences[fence.key] = fence; bytes += size
                guard fences.count <= ICloudFencePayload.maximumCount, bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            }
        }
        guard try await account() == identity else { throw ICloudFailure.accountChanged }
        try check(ticket)
        return fences.values.sorted { $0.key < $1.key }
    }
    func prepareRemoval() async throws {
        let ticket = generation
        if let engine { await engine.cancelOperations() }
        try check(ticket)
        engine = nil; engineState = nil
        queued = [:]; originals = [:]; serverRecords = [:]; received = []; acknowledged = []
    }
    func advanceRemoval(_ receipt: ICloudRemovalReceipt) async throws {
        let ticket = generation
        try receipt.validate()
        guard try await account() == receipt.account else { throw ICloudFailure.accountChanged }
        try check(ticket)
        let record = try await control(receipt.category)
        try check(ticket)
        // A successful earlier CAS or another Mac's later reset already fenced
        // the old namespace. Never roll that control marker backwards on retry.
        guard record["epoch"] as? String == receipt.oldEpoch else { return }
        record["epoch"] = receipt.newEpoch as CKRecordValue
        guard try await account() == receipt.account else { throw ICloudFailure.accountChanged }
        try check(ticket)
        let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        try check(ticket)
        guard let saved = result.saveResults[record.recordID] else { throw ICloudFailure.storage("The reset was not acknowledged. Cleanup remains pending.") }
        do { _ = try saved.get() }
        catch let error as CKError where error.code == .serverRecordChanged {
            guard let current = error.serverRecord else { throw error }
            try validateControl(current)
            guard current["epoch"] as? String != receipt.oldEpoch else { throw error }
        }
    }
    func deleteRemoval(_ receipt: ICloudRemovalReceipt) async throws {
        let ticket = generation
        try receipt.validate()
        guard try await account() == receipt.account else { throw ICloudFailure.accountChanged }
        try check(ticket)
        let current = try await control(receipt.category)
        try check(ticket)
        guard current["epoch"] as? String != receipt.oldEpoch else {
            throw ICloudFailure.storage("The old iCloud namespace is still active. Cleanup remains pending.")
        }
        guard try await account() == receipt.account else { throw ICloudFailure.accountChanged }
        try check(ticket)
        do { _ = try await database.deleteRecordZone(withID: Self.zone(receipt.category, epoch: receipt.oldEpoch)) }
        catch let error as CKError where error.code == .zoneNotFound { }
        try check(ticket)
        guard try await account() == receipt.account else { throw ICloudFailure.accountChanged }
        try check(ticket)
    }
}

/// Contains only opaque ancestor identities. Category reset never removes these
/// permanent records from the account's private control zone.
enum ICloudFencePayload {
    static let zone = CKRecordZone.ID(zoneName: "vane-control-v1", ownerName: CKCurrentUserDefaultName)
    static let maximumCount = 100_000
    static let maximumBytes = 4 * 1024
    static func encode(_ fence: ICloudDeletionFence) throws -> CKRecord {
        try fence.validate()
        var canonical = fence
        canonical.id = UUID(uuidString: fence.id)!.uuidString.lowercased()
        let payload = try JSONEncoder().encode(canonical)
        guard payload.count <= maximumBytes else { throw ICloudFailure.limitExceeded }
        let id = CKRecord.ID(recordName: ICloudIdentity.digest("fence:" + canonical.key), zoneID: zone)
        let record = CKRecord(recordType: "VaneDeletionFence", recordID: id)
        record["schema"] = 1 as CKRecordValue
        record.encryptedValues["payload"] = payload as CKRecordValue
        record.encryptedValues["digest"] = Data(SHA256.hash(data: payload)) as CKRecordValue
        return record
    }
    static func decode(_ record: CKRecord) throws -> ICloudDeletionFence {
        guard record.recordType == "VaneDeletionFence", record["schema"] as? Int == 1 else { throw ICloudFailure.unsupportedSchema }
        guard record.recordID.zoneID == zone, let payload = record.encryptedValues["payload"] as? Data,
              payload.count <= maximumBytes,
              record.encryptedValues["digest"] as? Data == Data(SHA256.hash(data: payload)) else {
            throw ICloudFailure.invalid("An iCloud ancestor deletion fence failed validation.")
        }
        let fence = try JSONDecoder().decode(ICloudDeletionFence.self, from: payload)
        try fence.validate()
        guard record.recordID.recordName == ICloudIdentity.digest("fence:" + fence.key) else {
            throw ICloudFailure.invalid("An iCloud ancestor deletion fence changed identity.")
        }
        return fence
    }
}

/// Stateless record boundary, usable without constructing a CloudKit container.
enum ICloudCloudRecordPayload {
    static func encode(_ value: ICloudRecord, id: CKRecord.ID, previous: CKRecord?, staging: URL?) throws -> CKRecord {
        let data = try JSONEncoder().encode(value)
        guard data.count <= ICloudLimits.assetBytes else { throw ICloudFailure.limitExceeded }
        let record = previous ?? CKRecord(recordType: "VaneEntity", recordID: id)
        // Schema 2 carries causal birth/incarnation semantics. Older clients must
        // stop instead of silently discarding those versions and re-deleting data.
        record["schema"] = 2 as CKRecordValue
        record.encryptedValues["digest"] = Data(SHA256.hash(data: data)) as CKRecordValue
        record.encryptedValues["payload"] = nil
        record["asset"] = nil
        if data.count > ICloudLimits.inlineBytes {
            guard let staging else { throw ICloudFailure.storage("The asset staging directory is unavailable.") }
            let url = staging.appendingPathComponent(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            guard try Data(contentsOf: url) == data else { throw ICloudFailure.invalid("A staged iCloud asset failed integrity validation.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            record["asset"] = CKAsset(fileURL: url)
        } else { record.encryptedValues["payload"] = data as CKRecordValue }
        return record
    }
    static func decode(_ record: CKRecord, categoryZones: [ICloudCategory: CKRecordZone.ID], transferredBytes: inout Int) throws -> ICloudRecord {
        guard record.recordType == "VaneEntity", let schema = record["schema"] as? Int,
              schema == 1 || schema == 2 else { throw ICloudFailure.unsupportedSchema }
        let data: Data
        if let inline = record.encryptedValues["payload"] as? Data {
            guard inline.count <= ICloudLimits.inlineBytes, record["asset"] == nil else { throw ICloudFailure.limitExceeded }
            data = inline
        } else if let asset = record["asset"] as? CKAsset, let url = asset.fileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= ICloudLimits.assetBytes else { throw ICloudFailure.limitExceeded }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count == size else { throw ICloudFailure.invalid("An iCloud asset changed during validation.") }
        } else { throw ICloudFailure.invalid("An iCloud item is missing its encrypted payload.") }
        transferredBytes += data.count
        guard data.count <= ICloudLimits.assetBytes, transferredBytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
        guard record.encryptedValues["digest"] as? Data == Data(SHA256.hash(data: data)) else { throw ICloudFailure.invalid("An iCloud asset failed integrity validation.") }
        let value = try JSONDecoder().decode(ICloudRecord.self, from: data)
        try value.validate()
        guard record.recordID.recordName == ICloudIdentity.digest(value.key), categoryZones[value.category] == record.recordID.zoneID else {
            throw ICloudFailure.invalid("An iCloud item has an invalid routing identity.")
        }
        return value
    }
}
