import Foundation

/// Owns only canonical storage.sync JSON and pending cloud mutations. No WebKit
/// files, permissions, vendor vault databases, or local/session namespaces enter it.
actor ICloudExtensionStorageCache {
    struct Entry: Codable, Equatable, Sendable {
        var namespace: ICloudExtensionNamespace
        var installationID: String?
        var nativeBaseline: [String: Data]?
        var values: [String: Data] = [:]
        var pending: [String: ICloudExtensionStorageMutation] = [:]
    }
    private struct State: Codable, Equatable {
        var schema = 1
        var entries: [String: Entry] = [:]
        var profiles: Set<UUID> = []
        var retiredProfiles: Set<UUID> = []
        var retiredNamespaces: Set<ICloudExtensionNamespace> = []
    }
    private let file: URL
    private let marker: URL
    private var state: State?
    init(directory: URL) {
        file = directory.appendingPathComponent("icloud-extension-storage.json")
        marker = directory.appendingPathComponent("icloud-extension-storage.initialized")
    }

    private func loaded() throws -> State {
        if let state { return state }
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            guard !fm.fileExists(atPath: marker.path) else {
                throw ICloudFailure.storage("The prior extension sync baseline is missing. Pending extension data has not been applied; restore its local cache before retrying.")
            }
            let fresh = State(); state = fresh; return fresh
        }
        do {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? .max <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
            guard saved.schema == 1 else { throw ICloudFailure.unsupportedSchema }
            for (key, entry) in saved.entries {
                try entry.namespace.validate()
                guard key == entry.namespace.key else { throw ICloudFailure.invalid("Invalid extension cache identity.") }
                _ = try ICloudExtensionStorageJSON.snapshot(entry.values)
                if let native = entry.nativeBaseline { _ = try ICloudExtensionStorageJSON.snapshot(native) }
                guard entry.pending.count <= ICloudExtensionStorageJSON.keyCount else { throw ICloudFailure.limitExceeded }
                for (key, mutation) in entry.pending {
                    guard key == mutation.key else { throw ICloudFailure.invalid("Invalid pending extension key.") }
                    if let value = mutation.value { _ = try ICloudExtensionStorageJSON.value(value, key: key) }
                    if case .value(let expected) = mutation.expected { _ = try ICloudExtensionStorageJSON.value(expected, key: key) }
                }
            }
            state = saved
            return saved
        } catch let error as ICloudFailure { throw error }
        catch { throw ICloudFailure.storage("The prior extension sync baseline could not be read. Its pending data has been retained; repair or restore the cache before retrying.") }
    }

    private func save(_ next: State) throws {
        try ICloudApplyContext.check()
        do {
            let data = try JSONEncoder().encode(next)
            guard data.count <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ICloudApplyContext.check()
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("1".utf8).write(to: marker, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            }
            state = next
        } catch let error as ICloudFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ICloudFailure.storage("Extension sync data could not be saved. Pending mutations have not been acknowledged.") }
    }

    func inventory(profiles: Set<UUID>, installed: [ICloudExtensionInstallation]) throws {
        let old = try loaded(); var next = old
        let regular = profiles.subtracting([Profile.incognito.id])
        let removedProfiles = next.profiles.subtracting(regular)
        next.retiredProfiles.formUnion(removedProfiles)
        next.entries = next.entries.filter { !next.retiredProfiles.contains($0.value.namespace.profileID) }
        next.profiles.formUnion(regular)
        var installations: [String: ICloudExtensionInstallation] = [:]
        for installation in installed {
            try installation.namespace.validate()
            guard UUID(uuidString: installation.installationID) != nil,
                  regular.contains(installation.namespace.profileID),
                  installations.updateValue(installation, forKey: installation.namespace.key) == nil else {
                throw ICloudFailure.invalid("The accepted extension inventory is incomplete or duplicated.")
            }
        }
        for (key, entry) in next.entries where entry.installationID != nil && installations[key] == nil {
            next.retiredNamespaces.insert(entry.namespace)
            next.entries.removeValue(forKey: key)
        }
        for (key, installation) in installations where !next.retiredProfiles.contains(installation.namespace.profileID) {
            next.retiredNamespaces.remove(installation.namespace)
            var entry = next.entries[key] ?? Entry(namespace: installation.namespace)
            if let oldInstallation = entry.installationID, oldInstallation != installation.installationID {
                entry.nativeBaseline = nil
                entry.values = entry.pending.compactMapValues(\.value)
                entry.pending = entry.pending.mapValues { .init(key: $0.key, value: $0.value, expected: .unknown) }
            }
            entry.installationID = installation.installationID
            next.entries[key] = entry
        }
        if next != old { try save(next) }
    }

    func retired(_ profile: UUID) throws -> Bool { try loaded().retiredProfiles.contains(profile) }
    func entries() throws -> [Entry] { try loaded().entries.values.sorted { $0.namespace.key < $1.namespace.key } }
    func entry(_ namespace: ICloudExtensionNamespace) throws -> Entry? { try loaded().entries[namespace.key] }
    func stage(_ items: [ICloudItem], deleted: [ICloudItem], profiles: Set<UUID>) throws {
        let old = try loaded(); var next = old
        for (rows, deleting) in [(items, false), (deleted, true)] {
            for item in rows {
                let (ns, key, value) = try ICloudExtensionStorageJSON.decode(item)
                guard profiles.contains(ns.profileID), !next.retiredProfiles.contains(ns.profileID),
                      !next.retiredNamespaces.contains(ns) else { continue }
                var entry = next.entries[ns.key] ?? Entry(namespace: ns)
                let expected: ICloudExtensionStorageExpected
                if let baseline = entry.nativeBaseline { expected = baseline[key].map(ICloudExtensionStorageExpected.value) ?? .absent }
                else { expected = .unknown }
                entry.pending[key] = .init(key: key, value: deleting ? nil : value, expected: expected)
                if deleting { entry.values.removeValue(forKey: key) } else { entry.values[key] = value }
                _ = try ICloudExtensionStorageJSON.snapshot(entry.values)
                next.entries[ns.key] = entry
                next.profiles.insert(ns.profileID)
            }
        }
        if next != old { try save(next) }
    }
    func recordNative(_ namespace: ICloudExtensionNamespace, installationID: String, values: [String: Data]) throws {
        let old = try loaded(); var next = old
        guard !next.retiredProfiles.contains(namespace.profileID), !next.retiredNamespaces.contains(namespace),
              next.entries[namespace.key]?.installationID == installationID else { throw CancellationError() }
        var entry = next.entries[namespace.key] ?? Entry(namespace: namespace)
        entry.values = try ICloudExtensionStorageJSON.snapshot(values)
        entry.nativeBaseline = entry.values
        entry.pending = [:]
        next.entries[namespace.key] = entry
        if next != old { try save(next) }
    }
}
