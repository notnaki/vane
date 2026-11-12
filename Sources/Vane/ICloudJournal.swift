import Foundation

/// The journal is independent of MainActor and owns every disk operation. An atomic
/// checkpoint precedes acknowledgement or publication to callers.
actor ICloudJournal {
    private struct State: Codable {
        var schema = 3
        var deviceID: String
        var accountID: String?
        var counter: UInt64 = 0
        var records: [String: ICloudRecord] = [:]
        var baseline: [String: ICloudItem] = [:]
        var pending: Set<String> = []
        var engineState: Data?
        var epochs: [ICloudCategory: String] = [:]
        var ancestorInventory: [ICloudDeletionFence]?
        var observedAbsences: Set<String>?
    }
    private let file: URL
    private var state: State
    var deviceID: String { state.deviceID }
    var accountID: String? { state.accountID }
    var engineState: Data? { state.engineState }
    var epochs: [ICloudCategory: String] { state.epochs }

    init(directory: URL, deviceID: String = UUID().uuidString) throws {
        file = directory.appendingPathComponent("icloud-journal.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? .max <= 512 * 1024 * 1024 else { throw ICloudFailure.limitExceeded }
            var saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            if saved.schema == 1 {
                let old = saved.records
                saved.records = Dictionary(old.values.map { ($0.key, $0) }, uniquingKeysWith: ICloudRecord.merged)
                saved.baseline = Dictionary(saved.baseline.values.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
                saved.pending = Set(saved.pending.compactMap { old[$0]?.key })
                saved.schema = 2
            }
            if saved.schema == 2 { saved.schema = 3 }
            guard saved.schema == 3 else { throw ICloudFailure.unsupportedSchema }
            state = saved
        } else { state = State(deviceID: deviceID) }
    }

    private func save(_ next: State) throws {
        do {
            let data = try JSONEncoder().encode(next)
            guard data.count <= 512 * 1024 * 1024 else { throw ICloudFailure.limitExceeded }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            state = next
        } catch let error as ICloudFailure { throw error }
        catch { throw ICloudFailure.storage("Vane could not save pending iCloud changes. Your local library has been kept.") }
    }

    func checkpoint() throws { try save(state) }
    func setEngineState(_ data: Data) throws { var next = state; next.engineState = data; try save(next) }
    func setEngineState(_ data: Data, expectedAccount: String) throws {
        guard state.accountID == ICloudIdentity.digest(expectedAccount) else { throw ICloudFailure.accountChanged }
        try setEngineState(data)
    }
    func setEpochs(_ epochs: [ICloudCategory: String]) throws { var next = state; next.epochs = epochs; try save(next) }

    func bindAccount(_ account: String, allowMerge: Bool) throws {
        guard !account.isEmpty else { throw ICloudFailure.unavailable("Sign in to iCloud to start syncing.") }
        let identity = ICloudIdentity.digest(account)
        guard state.accountID != identity else { return }
        if state.accountID != nil {
            guard allowMerge else { throw ICloudFailure.accountChanged }
            // Keep the previous account's unsent work recoverable, never replay it to
            // the new account. Fresh capture requires deliberate account consent.
            let archive = file.deletingLastPathComponent().appendingPathComponent("icloud-account-" + UUID().uuidString + ".json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: file, to: archive) }
            var next = State(deviceID: state.deviceID)
            next.accountID = identity
            try save(next)
        } else { var next = state; next.accountID = identity; try save(next) }
    }

    func capture(_ items: [ICloudItem], enabled: Set<ICloudCategory>) throws {
        var captured: [String: ICloudItem] = [:]
        for item in items {
            try item.validate()
            guard enabled.contains(item.category) else { throw ICloudFailure.invalid("A disabled category attempted to upload data.") }
            guard captured.updateValue(item, forKey: item.key) == nil else { throw ICloudFailure.invalid("An iCloud category produced duplicate identities.") }
        }
        var next = state
        for item in items {
            let old = next.baseline[item.key]
            guard old != item else { continue }
            let recreating = next.records[item.key]?.deletion != nil
            if recreating {
                // A received tombstone alone is not permission to revive stale
                // native state. Require successful, durable observed absence and
                // subsequent new presence. Ancestor identities stay permanent.
                guard old == nil, next.observedAbsences?.contains(item.key) == true,
                      item.category != .profiles, item.category != .spaces else { continue }
            }
            var record = next.records[item.key] ?? ICloudRecord(category: item.category, id: item.id,
                profileID: item.profileID, parentID: item.parentID, fields: [:], deletion: nil)
            next.counter += 1
            var vector = record.vector
            vector[next.deviceID] = next.counter
            let version = ICloudVersion(vector: vector, writer: next.deviceID, counter: next.counter)
            if recreating {
                record.fields = [:]; record.deletion = nil; record.birthVersion = version
                next.observedAbsences?.remove(item.key)
            }
            if record.parentID != item.parentID || old == nil {
                record.parentID = item.parentID; record.parentVersion = version
            }
            for key in Set(item.fields.keys).union(old?.fields.keys ?? Dictionary<String, Data>().keys) {
                if old?.fields[key] != item.fields[key] {
                    record.fields[key] = ICloudField(value: item.fields[key], version: version)
                }
            }
            next.records[item.key] = record
            next.pending.insert(item.key)
            next.baseline[item.key] = item
            next.observedAbsences?.remove(item.key)
        }
        for (key, old) in next.baseline where enabled.contains(old.category) && captured[key] == nil {
            guard var record = next.records[key], record.deletion == nil else { continue }
            next.counter += 1
            var vector = record.vector; vector[next.deviceID] = next.counter
            record.deletion = ICloudVersion(vector: vector, writer: next.deviceID, counter: next.counter)
            next.records[key] = record; next.pending.insert(key)
            next.baseline.removeValue(forKey: key)
            if next.observedAbsences == nil { next.observedAbsences = [] }
            next.observedAbsences?.insert(key)
        }
        retireDescendants(in: &next)
        try save(next)
    }

    @discardableResult func merge(_ incoming: [ICloudRecord]) throws -> [ICloudRecord] {
        var next = state
        var changed: [ICloudRecord] = []
        for remote in incoming {
            try remote.validate()
            let merged: ICloudRecord
            if let old = next.records[remote.key] {
                guard old.profileID == remote.profileID else { throw ICloudFailure.invalid("An iCloud entity changed profile ownership.") }
                if let copy = try Self.conflictCopy(old, remote), next.records[copy.key] == nil {
                    next.records[copy.key] = copy; next.pending.insert(copy.key); changed.append(copy)
                }
                merged = ICloudRecord.merged(old, remote)
            } else { merged = remote }
            if next.records[remote.key] != merged { changed.append(merged) }
            next.records[remote.key] = merged
            if merged != remote { next.pending.insert(remote.key) }
            next.counter = max(next.counter, merged.vector.values.max() ?? 0)
        }
        retireDescendants(in: &next)
        try save(next)
        return changed
    }

    func markApplied(_ items: [ICloudItem], enabled: Set<ICloudCategory>) throws {
        var next = state
        let observedBeforeApply = state.baseline
        next.baseline = next.baseline.filter { !enabled.contains($0.value.category) }
        for item in items where enabled.contains(item.category) {
            try item.validate()
            // Readback may include genuine user edits/new entities made while an
            // asynchronous import was queued. They become local revisions rather
            // than being accepted as an unjournaled baseline.
            var record = next.records[item.key] ?? ICloudRecord(category: item.category, id: item.id,
                profileID: item.profileID, parentID: item.parentID, fields: [:], deletion: nil)
            if record.deletion == nil && record.item != item {
                next.counter += 1
                var vector = record.vector; vector[next.deviceID] = next.counter
                let version = ICloudVersion(vector: vector, writer: next.deviceID, counter: next.counter)
                for key in Set(record.item.fields.keys).union(item.fields.keys) where record.item.fields[key] != item.fields[key] {
                    record.fields[key] = ICloudField(value: item.fields[key], version: version)
                }
                if record.parentID != item.parentID { record.parentID = item.parentID; record.parentVersion = version }
                next.records[item.key] = record; next.pending.insert(item.key)
            }
            next.baseline[item.key] = item
            next.observedAbsences?.remove(item.key)
        }
        let readback = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, original) in observedBeforeApply where enabled.contains(original.category) && readback[key] == nil {
            // Absence is a deletion only when this Mac actually observed the entity
            // immediately before apply. Unknown incoming/placeholder omissions are
            // never evidence of a local deletion.
            retire(key, in: &next)
        }
        for (key, record) in next.records where enabled.contains(.bookmarks) && record.category == .bookmarks
            && record.deletion == nil && readback[key] == nil {
            guard let url = record.item.fields["url"], items.contains(where: {
                $0.category == .bookmarks && $0.profileID == record.profileID && $0.fields["url"] == url
            }) else { continue }
            retire(key, in: &next)
        }
        retireDescendants(in: &next)
        if next.observedAbsences == nil { next.observedAbsences = [] }
        for (key, record) in next.records where enabled.contains(record.category) && record.deletion != nil && readback[key] == nil {
            next.observedAbsences?.insert(key)
        }
        try save(next)
    }

    func deletionFences() -> [ICloudDeletionFence] {
        state.records.values.compactMap { record in
            guard record.deletion != nil, let profile = record.profileID else { return nil }
            if record.category == .profiles { return ICloudDeletionFence(kind: .profile, profileID: profile, id: record.id) }
            if record.category == .spaces { return ICloudDeletionFence(kind: .space, profileID: profile, id: record.id) }
            return nil
        }.sorted { $0.key < $1.key }
    }
    func mergeFences(_ fences: [ICloudDeletionFence]) throws {
        var next = state
        for fence in fences { try addFence(fence, to: &next) }
        retireDescendants(in: &next)
        try save(next)
    }
    func observeAncestorInventory(_ inventory: [ICloudDeletionFence]) throws {
        for item in inventory { try item.validate() }
        var next = state
        if let previous = state.ancestorInventory {
            let present = Set(inventory.map(\.key))
            for missing in previous where !present.contains(missing.key) { try addFence(missing, to: &next) }
        }
        next.ancestorInventory = inventory
        retireDescendants(in: &next)
        try save(next)
    }
    private func addFence(_ fence: ICloudDeletionFence, to next: inout State) throws {
        try fence.validate()
        let category: ICloudCategory = fence.kind == .profile ? .profiles : .spaces
        let id = UUID(uuidString: fence.id)!.uuidString
        let key = ICloudIdentity.recordKey(category: category, id: id, profileID: fence.profileID)
        if next.records[key]?.deletion != nil { return }
        var record = next.records[key] ?? ICloudRecord(category: category, id: id,
            profileID: fence.profileID, parentID: nil, fields: [:], deletion: nil)
        next.counter += 1
        var vector = record.vector; vector[next.deviceID] = next.counter
        record.deletion = ICloudVersion(vector: vector, writer: next.deviceID, counter: next.counter)
        next.records[key] = record; next.baseline.removeValue(forKey: key)
    }

    private func retire(_ key: String, in next: inout State) {
        guard var record = next.records[key], record.deletion == nil else { return }
        next.counter += 1
        var vector = record.vector; vector[next.deviceID] = next.counter
        record.deletion = ICloudVersion(vector: vector, writer: next.deviceID, counter: next.counter)
        next.records[key] = record; next.pending.insert(key); next.baseline.removeValue(forKey: key)
    }
    private func retireDescendants(in next: inout State) {
        let parents = next.records.values.filter { $0.deletion != nil && ($0.category == .profiles || $0.category == .spaces) }
        for record in Array(next.records.values) where record.deletion == nil {
            let removedParent = parents.contains { parent in
                if parent.category == .profiles { return record.category != .profiles && record.profileID == parent.profileID }
                guard record.category != .spaces, record.profileID == parent.profileID else { return false }
                if record.parentID?.lowercased() == parent.id.lowercased() { return true }
                guard let field = record.item.fields["spaceID"], let space = try? JSONDecoder().decode(UUID.self, from: field) else { return false }
                return space.uuidString.lowercased() == parent.id.lowercased()
            }
            if removedParent { retire(record.key, in: &next) }
        }
    }
    private static func conflictCopy(_ left: ICloudRecord, _ right: ICloudRecord) throws -> ICloudRecord? {
        guard left.category == .easels, left.deletion == nil, right.deletion == nil else { return nil }
        let concurrent = left.fields.contains { key, field in
            guard let other = right.fields[key], field.value != other.value else { return false }
            return !field.version.dominates(other.version) && !other.version.dominates(field.version)
        }
        guard concurrent else { return nil }
        func latest(_ record: ICloudRecord) -> ICloudVersion? {
            record.fields.values.map(\.version).reduce(nil) { current, version in current.map { ICloudVersion.preferred($0, version) } ?? version }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let loser: ICloudRecord
        if let l = latest(left), let r = latest(right), l != r {
            loser = ICloudVersion.preferred(l, r) == l ? right : left
        } else { loser = try encoder.encode(left).lexicographicallyPrecedes(encoder.encode(right)) ? left : right }
        let identity = ICloudIdentity.uuid("easel-conflict:" + ICloudIdentity.digest(String(decoding: try encoder.encode(loser), as: UTF8.self)))
        var copy = loser
        copy.id = loser.profileID.map { $0.uuidString.lowercased() + "/" } ?? ""
        copy.id += identity.uuidString.lowercased()
        if var id = copy.fields["id"] { id.value = try encoder.encode(identity); copy.fields["id"] = id }
        return copy
    }
    func pending(enabled: Set<ICloudCategory>) -> [ICloudRecord] {
        state.pending.compactMap { state.records[$0] }.filter { enabled.contains($0.category) }.sorted { $0.key < $1.key }
    }
    func items(enabled: Set<ICloudCategory>) -> [ICloudItem] {
        state.records.values.filter { enabled.contains($0.category) && $0.deletion == nil }.map(\.item).sorted { $0.key < $1.key }
    }
    func deleted(enabled: Set<ICloudCategory>) -> [ICloudItem] {
        state.records.values.filter { enabled.contains($0.category) && $0.deletion != nil }.map(\.item).sorted { $0.key < $1.key }
    }
    func acknowledge(_ sent: [ICloudRecord]) throws {
        var next = state
        for record in sent where next.records[record.key] == record { next.pending.remove(record.key) }
        try save(next)
    }
    func reset(_ categories: Set<ICloudCategory>) throws {
        var next = state
        next.records = next.records.filter { !categories.contains($0.value.category) }
        next.baseline = next.baseline.filter { !categories.contains($0.value.category) }
        next.pending = next.pending.filter { next.records[$0] != nil }
        next.observedAbsences = next.observedAbsences?.filter { next.records[$0] != nil }
        try save(next)
    }
}
