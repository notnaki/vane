import Foundation

/// Syncs only WebExtension storage.sync. Inactive namespaces have a durable shadow
/// and pending mutations; absence of an executing runtime is never a deletion.
@MainActor final class ICloudExtensionStorageAdapter: ICloudAdapter {
    let categories: Set<ICloudCategory> = [.extensionSyncData]
    private(set) var pendingExtensionCount = 0
    private let profiles: @MainActor () -> [UUID]
    private let ensureProfile: @MainActor (UUID) throws -> Void
    private let installed: @MainActor () async throws -> [ICloudExtensionInstallation]
    private let open: @MainActor (ICloudExtensionInstallation) async throws -> (any ICloudExtensionStorageSession)?
    private let cache: ICloudExtensionStorageCache
    private var working = false

    init(directory: URL = Store.directory,
         profileIDs: (@MainActor () -> [UUID])? = nil,
         ensureProfile: (@MainActor (UUID) throws -> Void)? = nil,
         installed: (@MainActor () async throws -> [ICloudExtensionInstallation])? = nil,
         open: (@MainActor (ICloudExtensionInstallation) async throws -> (any ICloudExtensionStorageSession)?)? = nil) {
        let profileSource = profileIDs ?? { ProfileManager.shared.profiles.map(\.id) }
        profiles = profileSource
        if let ensureProfile { self.ensureProfile = ensureProfile }
        else if profileIDs == nil { self.ensureProfile = { try ProfileManager.shared.ensureICloudProfile($0) } }
        else { self.ensureProfile = { _ in } }
        cache = ICloudExtensionStorageCache(directory: directory)
        self.installed = installed ?? {
            let ids = profileSource().filter { $0 != Profile.incognito.id }
            return try await Task.detached(priority: .utility) {
                try ids.flatMap { profile in
                    let store = ExtensionCodeStore(profileID: profile, directory: directory)
                    return try store.records().values.map { record in
                        ICloudExtensionInstallation(namespace: ICloudExtensionNamespace(profileID: profile,
                            extensionID: ICloudExtensionIdentity.portableID(record, profile: profile)), installationID: record.identity.lowercased())
                    }
                }
            }.value
        }
        self.open = open ?? { installation in
            guard let lease = try ExtensionHost.existingICloudStorageLease(for: installation) else { return nil }
            return ICloudExtensionStorageBridge(lease: lease)
        }
    }

    static func wake() { ICloudController.requestSyncIfRunning() }
    nonisolated static func item(namespace: ICloudExtensionNamespace, key: String, value: Data) throws -> ICloudItem {
        try ICloudExtensionStorageJSON.item(namespace: namespace, key: key, value: value)
    }
    private var regularProfiles: Set<UUID> { Set(profiles()).subtracting([Profile.incognito.id]) }
    private func check(_ namespace: ICloudExtensionNamespace? = nil) throws {
        try ICloudApplyContext.check()
        if let namespace {
            guard namespace.profileID != Profile.incognito.id, regularProfiles.contains(namespace.profileID) else { throw CancellationError() }
        }
    }
    private func inventory() async throws -> [ICloudExtensionInstallation] {
        try check()
        let admitted = regularProfiles
        let result = try await installed()
        try check()
        guard admitted == regularProfiles else { throw CancellationError() }
        try await cache.inventory(profiles: admitted, installed: result)
        try check()
        return result
    }
    private func countPending() async throws {
        let entries = try await cache.entries()
        try check()
        pendingExtensionCount = entries.filter { !$0.pending.isEmpty }.count
    }

    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem] {
        guard enabled.contains(.extensionSyncData) else { return [] }
        guard !working else { throw ICloudFailure.unavailable("An extension sync operation is already in progress. Retry after it finishes.") }
        working = true; defer { working = false }
        let installations = try await inventory()
        try await countPending()
        for installation in installations {
            let ns = installation.namespace
            let cached = try await cache.entry(ns)
            try check(ns)
            // A genuinely new activation must receive its staged remote settings
            // before initial vendor defaults can become a captured native baseline.
            guard cached?.pending.isEmpty != false else { continue }
            guard let session = try await open(installation) else { continue }
            defer { session.close() }
            try check(ns); try session.check()
            let values = try await session.read()
            try check(ns); try session.check()
            try await cache.recordNative(ns, installationID: installation.installationID,
                values: ICloudExtensionStorageJSON.snapshot(values))
            try check(ns)
        }
        let entries = try await cache.entries()
        try check()
        var result: [ICloudItem] = [], bytes = 0
        for entry in entries where regularProfiles.contains(entry.namespace.profileID) {
            for key in entry.values.keys.sorted() {
                let item = try Self.item(namespace: entry.namespace, key: key, value: entry.values[key]!)
                bytes += item.fields.values.reduce(0) { $0 + $1.count }
                guard bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
                result.append(item)
            }
        }
        try await countPending()
        return result
    }

    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        guard enabled.contains(.extensionSyncData) else { return }
        guard !working else { throw ICloudFailure.unavailable("An extension sync operation is already in progress. Retry after it finishes.") }
        working = true; defer { working = false }
        var installations = try await inventory()
        let incoming = items.filter { $0.category == .extensionSyncData }
        let tombstones = deleted.filter { $0.category == .extensionSyncData }
        let validated = try await Task.detached(priority: .utility) {
            var bytes = 0
            for item in incoming + tombstones {
                bytes += item.fields.values.reduce(0) { $0 + $1.count }
                guard bytes <= ICloudLimits.cycleBytes else { throw ICloudFailure.limitExceeded }
                _ = try ICloudExtensionStorageJSON.decode(item)
            }
            return incoming + tombstones
        }.value
        try check()
        for item in validated {
            let (ns, _, _) = try ICloudExtensionStorageJSON.decode(item)
            if try await cache.retired(ns.profileID) { continue }
            try check()
            if !regularProfiles.contains(ns.profileID) {
                try check()
                try ensureProfile(ns.profileID)
            }
        }
        // Profile creation is limited to opaque parents; it never opens an extension
        // host. Refresh the committed install roster before admitting cache writes.
        installations = try await inventory()
        try await cache.stage(incoming, deleted: tombstones, profiles: regularProfiles)
        try check()
        try await countPending()
        for installation in installations {
            let ns = installation.namespace
            guard let entry = try await cache.entry(ns), !entry.pending.isEmpty else { continue }
            try check(ns)
            guard let session = try await open(installation) else { continue }
            defer { session.close() }
            try check(ns); try session.check()
            // This read is a real revocable boundary, including before first activation
            // defaults are replaced. Previously observed keys retain expected values.
            _ = try await session.read()
            try check(ns); try session.check()
            let mutations = entry.pending.values.sorted { $0.key < $1.key }
            let readback = try await session.apply(mutations)
            try check(ns); try session.check()
            try await cache.recordNative(ns, installationID: installation.installationID,
                values: ICloudExtensionStorageJSON.snapshot(readback))
            try check(ns)
        }
        try await countPending()
    }
}
