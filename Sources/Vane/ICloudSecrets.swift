import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// The only boundary permitted to handle the synchronizable secret payloads. Tests inject
/// an in-memory implementation; neither the journal nor CloudKit sees these values.
protocol ICloudSecretsKeychain: Sendable {
    func read(_ query: [String: Any]) throws -> [Data]
    func add(_ attributes: [String: Any]) throws
    func replace(_ query: [String: Any], data: Data) throws
    func remove(_ query: [String: Any]) throws
}

@MainActor protocol ICloudSecretsLocalStore: AnyObject {
    func snapshot(kind: ICloudSecrets.Kind, admission: @escaping @Sendable () throws -> Void) async throws -> [ICloudSecrets.Identity: Data]
    func apply(_ identity: ICloudSecrets.Identity, value: Data?, expected: Data?, admission: @escaping @Sendable () throws -> Void) async throws -> Bool
}

extension Notification.Name {
    static let vaneSecretsChanged = Notification.Name("VaneSecretsChanged")
}

@MainActor final class ICloudSecrets {
    enum Kind: String, Codable, Sendable { case passwords, aiKeys
        var category: ICloudCategory { self == .passwords ? .passwords : .aiKeys }
    }

    struct Identity: Hashable, Codable, Sendable {
        var kind: Kind
        var profileID: UUID?
        var origin: String?
        var account: String
        static func password(profileID: UUID, origin: String, account: String) -> Self {
            .init(kind: .passwords, profileID: profileID, origin: origin, account: account)
        }
        static func aiKey(account: String) -> Self { .init(kind: .aiKeys, account: account) }
        func validate() throws {
            guard account.utf8.count <= 4096 else { throw Failure.invalidData }
            switch kind {
            case .passwords:
                guard let profileID, profileID != Profile.incognito.id,
                      let origin, let url = URL(string: origin), let parsed = PasswordOrigin(url: url),
                      parsed.url.absoluteString == origin, parsed != IntegrationTokens.legacyOrigin else {
                    throw Failure.invalidData
                }
            case .aiKeys:
                guard profileID == nil, origin == nil, !account.isEmpty else { throw Failure.invalidData }
            }
        }
    }

    struct Configuration: Sendable {
        var accessGroup: String
        var namespace: String
        // On real Macs nonsynchronizable items already have distinct local Keychains.
        // A separate discriminator lets fixtures share a simulated cloud safely.
        var localDeviceID: String = "this-mac"
        func query(kind: Kind, account: String? = nil, baseline: String? = nil, epoch: String? = nil, control: Bool = false, payload: Bool = false) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "io.github.notnaki.vane.icloud-secrets.v1." + digest(Data(namespace.utf8)) + "." + kind.rawValue
                    + (baseline.map { ".baseline." + digest(Data(($0 + ":" + localDeviceID).utf8)) } ?? (control ? ".reset-control" : payload ? ".payloads" : ".revisions")),
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: baseline == nil,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            if let epoch { query[kSecAttrGeneric as String] = Data(epoch.utf8) }
            return query
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, accountRequired, revoked, keychain(OSStatus), verification, invalidData, resetRequired(ICloudCategory), staleReview, authenticationDenied
        var errorDescription: String? {
            switch self {
            case .unavailable: "iCloud Keychain sync needs a signed Vane build with its provisioned Keychain access group."
            case .accountRequired: "Confirm the Apple Account and review the local merge before syncing secrets."
            case .revoked: "Secret sync paused because its account or category changed."
            case .keychain: "Keychain could not complete secret sync. Unlock this Mac's Keychain and check iCloud Passwords & Keychain in System Settings, then try again."
            case .verification: "The iCloud Keychain copy could not be verified. Your local original was kept. Try syncing again."
            case .invalidData: "An iCloud Keychain item is unsupported or damaged. Your local credentials were kept."
            case .resetRequired(let category): "\(category.title) were removed from iCloud Keychain on another Mac. Sync is paused; deliberately enable this category again to merge local copies."
            case .staleReview: "This credential changed after it was reviewed. Sync again and review the current versions before choosing one."
            case .authenticationDenied: "Authentication was not completed. Try again and use your Mac login password if Touch ID is unavailable."
            }
        }
    }
    struct CloudVersion: Identifiable, Equatable, Sendable {
        var id: UUID
        var isDeletion: Bool
    }
    struct Conflict: Identifiable, Equatable, Sendable {
        var id: UUID
        var identity: Identity
        var reviewedHeads: [CloudVersion]
        var reviewedHeadIDs: Set<UUID> { Set(reviewedHeads.map(\.id)) }
        var category: ICloudCategory { identity.kind.category }
    }
    enum Resolution: Equatable, Sendable {
        case keepThisMac
        case useCloudVersion(UUID)
    }
    /// Returned directly to the comparison sheet's temporary state. Never serialized or
    /// passed through the controller, diagnostics, preferences, CloudKit, or journal.
    enum Inspection: Equatable, Sendable {
        case credential(value: String, matchesThisMac: Bool)
        case deletion
    }

    /// Immutable revisions avoid read/update races overwriting a different Mac's secret.
    /// Parent IDs describe causality; concurrent heads remain in Keychain for review.
    private struct Revision: Codable, Equatable, Sendable {
        var schema = 1
        var id: UUID
        var identity: Identity
        var parents: Set<UUID>
        var valueDigest: String?
        // Plaintext is ephemeral. Only its digest and causal identity are encoded in
        // revision metadata; payloads have separate removable Keychain items.
        var value: Data? = nil
        enum CodingKeys: String, CodingKey { case schema, id, identity, parents, valueDigest }
        init(id: UUID, identity: Identity, parents: Set<UUID>, value: Data?) {
            self.id = id; self.identity = identity; self.parents = parents
            self.value = value; self.valueDigest = value.map(digest)
        }
    }
    private struct Baseline: Codable, Sendable {
        var digest: String?
        var heads: Set<UUID>
    }
    private struct Baselines: Codable, Sendable {
        var schema = 1
        var epoch: String
        var values: [Identity: Baseline] = [:]
        var erasedPayloads: Set<UUID> = []
    }
    private struct ResetMarker: Codable, Sendable {
        var schema = 1
        var id: UUID
    }
    private struct Review: Sendable {
        var conflict: Conflict
        var localDigest: String?
        var account: String
        var epoch: String
        var permit: Admission
    }

    private let configuration: Configuration?
    private let worker: Worker
    private let local: any ICloudSecretsLocalStore
    private let authorizer: @MainActor (String) async -> Bool
    private var accountNamespace: String?
    private var enabled: Set<ICloudCategory> = []
    private var generation: (@MainActor () -> Bool)?
    private var admission = Admission()
    private var observer: ObserverToken?
    private var refresh: Task<Void, Never>?
    private var running = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshNeeded = false
    private(set) var conflicts: [Conflict] = []
    private var reviewedConflicts: [UUID: Review] = [:]
    private(set) var resetObserved: Set<ICloudCategory> = []
    private var acknowledgedResets: Set<ICloudCategory> = []
    private(set) var lastError: String?
    var onStatusChange: (@MainActor () -> Void)?
    /// New passes must revalidate the Apple Account through the controller.
    var onSyncRequested: (@MainActor () async -> Void)?
    var isAvailable: Bool { configuration != nil }

    convenience init() {
        self.init(configuration: Self.provisionedConfiguration(), keychain: SystemKeychain(), local: SystemLocalStore())
    }
    init(configuration: Configuration?, keychain: any ICloudSecretsKeychain, local: any ICloudSecretsLocalStore,
         authorizer: (@MainActor (String) async -> Bool)? = nil) {
        self.configuration = configuration
        self.worker = Worker(keychain: keychain)
        self.local = local
        self.authorizer = authorizer ?? Self.authorizeInspection
        observer = ObserverToken(NotificationCenter.default.addObserver(forName: .vaneSecretsChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.localChanged() }
        })
    }
    deinit { refresh?.cancel() }

    func setAccountNamespace(_ opaqueIdentity: String) {
        let namespace = digest(Data(opaqueIdentity.utf8))
        if accountNamespace != namespace {
            pause(); accountNamespace = namespace
            acknowledgedResets = []
            resetObserved = []
            reviewedConflicts = [:]
        }
    }

    /// Called only by an explicit setup approval or deliberate category re-enablement.
    func acknowledgeReset(enabled categories: Set<ICloudCategory>) {
        acknowledgedResets.formUnion(categories.filter(\.isSecret))
        resetObserved.subtract(categories)
    }

    /// Stops Vane's admissions. Apple may still transport items already marked syncable.
    func pause() {
        admission.revoke()
        admission = Admission()
        enabled = []
        generation = nil
        refresh?.cancel()
        refresh = nil
        refreshNeeded = false
    }

    func sync(enabled categories: Set<ICloudCategory>, generationIsCurrent: @escaping @MainActor () -> Bool) async throws {
        let categories = categories.filter(\.isSecret)
        guard categories.isEmpty || generationIsCurrent() else { throw Failure.revoked }
        if enabled != categories { pause() }
        enabled = categories
        generation = generationIsCurrent
        guard !categories.isEmpty else { return }
        guard let configuration, !configuration.accessGroup.isEmpty else { throw Failure.unavailable }
        guard let accountNamespace else { throw Failure.accountRequired }
        guard generationIsCurrent() else { throw Failure.revoked }
        if running {
            await withCheckedContinuation { idleWaiters.append($0) }
            try Task.checkCancellation()
            return try await sync(enabled: categories, generationIsCurrent: generationIsCurrent)
        }
        running = true
        let permit = admission
        defer { finishPass() }
        conflicts = []
        do {
            for kind in [Kind.passwords, .aiKeys] where categories.contains(kind.category) {
                try check(permit, generationIsCurrent)
                let resetAcknowledged = acknowledgedResets.remove(kind.category) != nil
                guard !resetObserved.contains(kind.category) || resetAcknowledged else {
                    throw Failure.resetRequired(kind.category)
                }
                let epoch = try await currentEpoch(configuration, kind: kind, permit: permit)
                try check(permit, generationIsCurrent)
                let stored = try await worker.read(configuration, kind: kind, baseline: accountNamespace, permit: permit)
                try check(permit, generationIsCurrent)
                guard stored.count <= 1 else { throw Failure.invalidData }
                var baselines = try stored.first.map { try JSONDecoder().decode(Baselines.self, from: $0) } ?? Baselines(epoch: epoch)
                guard baselines.schema == 1 else { throw Failure.invalidData }
                if baselines.epoch != epoch {
                    guard resetAcknowledged else {
                        resetObserved.insert(kind.category)
                        throw Failure.resetRequired(kind.category)
                    }
                    baselines = Baselines(epoch: epoch)
                }
                // Persist first admission before migration: a reset during the first
                // attempt must still quarantine this Mac after a crash/restart.
                if stored.isEmpty {
                    try check(permit, generationIsCurrent)
                    try await worker.baseline(configuration, kind: kind, namespace: accountNamespace,
                                              data: JSONEncoder().encode(baselines), permit: permit)
                    try check(permit, generationIsCurrent)
                }
                let raw = try await worker.read(configuration, kind: kind, epoch: epoch, permit: permit)
                try check(permit, generationIsCurrent)
                guard raw.count <= 20_000 else { throw Failure.invalidData }
                var versions = try decodeRevisions(raw, kind: kind)
                let snapshot = try await local.snapshot(kind: kind, admission: { try permit.check() })
                try check(permit, generationIsCurrent)
                guard snapshot.count <= 20_000, snapshot.values.allSatisfy({ $0.count <= 64 * 1024 }) else { throw Failure.invalidData }
                for identity in Set(snapshot.keys).union(versions.map(\.identity)).union(baselines.values.keys) {
                    try identity.validate()
                    try check(permit, generationIsCurrent)
                    let localValue = snapshot[identity]
                    let localDigest = localValue.map(digest)
                    let baseline = baselines.values[identity]
                    var heads = try await loadedHeads(versions.filter { $0.identity == identity }, configuration: configuration,
                                                      kind: kind, epoch: epoch, permit: permit, current: generationIsCurrent)
                    // Publish only a real local edit, or a first local-only credential.
                    // Parenting the last acknowledged heads preserves unseen remote edits.
                    if (baseline != nil && baseline?.digest != localDigest) || (baseline == nil && heads.isEmpty && localValue != nil) {
                        let revision = Revision(id: UUID(), identity: identity, parents: baseline?.heads ?? [], value: localValue)
                        try await publish(revision, configuration: configuration, epoch: epoch, permit: permit, current: generationIsCurrent)
                        versions.append(revision)
                        // Acknowledge our own verified immutable publication even when an
                        // unseen remote branch remains in conflict. Otherwise every refresh
                        // would append another copy of the same unresolved local edit.
                        baselines.values[identity] = Baseline(digest: localDigest, heads: [revision.id])
                        heads = try await loadedHeads(versions.filter { $0.identity == identity }, configuration: configuration,
                                                      kind: kind, epoch: epoch, permit: permit, current: generationIsCurrent)
                    }
                    guard let head = heads.first else { continue }
                    // Equal concurrent values are safe to acknowledge together. Different
                    // values, including a concurrent delete, are deliberately retained.
                    guard heads.allSatisfy({ $0.value == head.value }) else {
                        conflicts.append(rememberConflict(identity: identity, heads: heads, localValue: localValue,
                                                          account: accountNamespace, epoch: epoch, permit: permit)); continue
                    }
                    if localValue != head.value {
                        guard baseline != nil && baseline?.digest == localDigest || baseline == nil && localValue == nil else {
                            conflicts.append(rememberConflict(identity: identity, heads: heads, localValue: localValue,
                                                              account: accountNamespace, epoch: epoch, permit: permit)); continue
                        }
                        try check(permit, generationIsCurrent)
                        try await verifyEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: generationIsCurrent)
                        guard try await local.apply(identity, value: head.value, expected: localValue, admission: { try permit.check() }) else {
                            conflicts.append(rememberConflict(identity: identity, heads: heads, localValue: localValue,
                                                              account: accountNamespace, epoch: epoch, permit: permit)); continue
                        }
                        try check(permit, generationIsCurrent)
                    }
                    baselines.values[identity] = Baseline(digest: head.value.map(digest), heads: Set(heads.map(\.id)))
                }
                // Keep the immutable causal skeleton, but erase secret bytes from
                // revisions superseded by verified descendants. Concurrent heads retain
                // their own payloads until the credential conflict is explicitly resolved.
                let superseded = versions.reduce(into: Set<UUID>()) { $0.formUnion($1.parents) }
                guard superseded.count <= 20_000 else { throw Failure.invalidData }
                for identifier in superseded.subtracting(baselines.erasedPayloads) {
                    try await verifyEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: generationIsCurrent)
                    try await worker.removePayload(configuration, kind: kind, account: identifier.uuidString, epoch: epoch, permit: permit)
                    try check(permit, generationIsCurrent)
                    baselines.erasedPayloads.insert(identifier)
                }
                try check(permit, generationIsCurrent)
                try await verifyEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: generationIsCurrent)
                try await worker.baseline(configuration, kind: kind, namespace: accountNamespace,
                                          data: JSONEncoder().encode(baselines), permit: permit)
                try check(permit, generationIsCurrent)
                acknowledgedResets.remove(kind.category)
                resetObserved.remove(kind.category)
            }
            lastError = nil
            let retained = Set(conflicts.map(\.id))
            reviewedConflicts = reviewedConflicts.filter { retained.contains($0.key) }
            onStatusChange?()
            scheduleRefresh()
        } catch {
            let failure = safeFailure(error)
            lastError = failure.localizedDescription
            onStatusChange?()
            throw failure
        }
    }

    /// Reads only an explicitly selected, currently reviewed cloud version after system
    /// authentication. The returned plaintext belongs solely to the comparison sheet.
    func inspectReviewedVersion(_ conflict: Conflict, versionID: UUID,
                                generationIsCurrent: @escaping @MainActor () -> Bool) async throws -> Inspection {
        do {
            let review = try admittedReview(conflict, current: generationIsCurrent)
            guard conflict.reviewedHeadIDs.contains(versionID) else { throw Failure.staleReview }
            guard let configuration else { throw Failure.unavailable }
            _ = try await validatedInspectionVersion(review, versionID: versionID, configuration: configuration, current: generationIsCurrent)
            let allowed = await authorizer(conflict.category == .passwords
                ? "compare an iCloud version of this saved password" : "compare an iCloud version of this API key")
            // Authentication can outlive an account change, a local edit, or the sheet.
            // Re-read the live review before touching any cloud secret payload.
            _ = try admittedReview(conflict, current: generationIsCurrent)
            guard allowed else { throw Failure.authenticationDenied }
            let selected = try await validatedInspectionVersion(review, versionID: versionID, configuration: configuration, current: generationIsCurrent)
            let result: Inspection
            if let expected = selected.valueDigest {
                let payloads = try await worker.read(configuration, kind: conflict.identity.kind, account: versionID.uuidString,
                                                    epoch: review.epoch, payload: true, permit: review.permit)
                try check(review.permit, generationIsCurrent)
                guard payloads.count == 1, let bytes = payloads.first, bytes.count <= 64 * 1024,
                      digest(bytes) == expected, let text = String(data: bytes, encoding: .utf8) else { throw Failure.verification }
                result = .credential(value: text, matchesThisMac: expected == review.localDigest)
            } else { result = .deletion }
            // A successful worker read cannot authorize a stale completion. No value is
            // returned if local/account/category/epoch/head state changed while reading.
            let refreshed = try await validatedInspectionVersion(review, versionID: versionID, configuration: configuration, current: generationIsCurrent)
            guard refreshed.valueDigest == selected.valueDigest, refreshed.parents == selected.parents else { throw Failure.staleReview }
            return result
        } catch {
            if !resetObserved.isEmpty { onStatusChange?() }
            throw safeFailure(error)
        }
    }

    private func validatedInspectionVersion(_ review: Review, versionID: UUID, configuration: Configuration,
                                            current: @escaping @MainActor () -> Bool) async throws -> Revision {
        _ = try admittedReview(review.conflict, current: current)
        let kind = review.conflict.identity.kind
        let epoch = try await currentEpoch(configuration, kind: kind, permit: review.permit)
        try check(review.permit, current)
        guard epoch == review.epoch else { resetObserved.insert(kind.category); throw Failure.staleReview }
        let raw = try await worker.read(configuration, kind: kind, epoch: epoch, permit: review.permit)
        try check(review.permit, current)
        let heads = Self.heads(try decodeRevisions(raw, kind: kind).filter { $0.identity == review.conflict.identity })
        guard review.conflict.reviewedHeadIDs.isSubset(of: Set(heads.map(\.id))),
              let selected = heads.first(where: { $0.id == versionID }) else { throw Failure.staleReview }
        let snapshot = try await local.snapshot(kind: kind, admission: { try review.permit.check() })
        try check(review.permit, current)
        guard snapshot[review.conflict.identity].map(digest) == review.localDigest else { throw Failure.staleReview }
        _ = try admittedReview(review.conflict, current: current)
        return selected
    }

    private static func authorizeInspection(_ reason: String) async -> Bool {
        let authentication = InspectionAuthentication()
        guard authentication.context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Match Passwords.authenticate's system policy and login-password fallback.
                authentication.context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { allowed, _ in
                    continuation.resume(returning: allowed)
                }
            }
        } onCancel: { authentication.context.invalidate() }
    }

    private final class InspectionAuthentication: @unchecked Sendable {
        // LAContext permits invalidating an outstanding evaluation from cancellation.
        let context = LAContext()
    }

    /// Resolves only the versions represented by an opaque, current review token.
    /// New concurrent heads are never adopted as parents by an old UI decision.
    func resolve(_ conflict: Conflict, choosing resolution: Resolution,
                 generationIsCurrent: @escaping @MainActor () -> Bool) async throws {
        let review = try admittedReview(conflict, current: generationIsCurrent)
        if running {
            await withCheckedContinuation { idleWaiters.append($0) }
            try Task.checkCancellation()
            return try await resolve(conflict, choosing: resolution, generationIsCurrent: generationIsCurrent)
        }
        guard let configuration else { throw Failure.unavailable }
        if case .useCloudVersion(let identifier) = resolution,
           !conflict.reviewedHeadIDs.contains(identifier) { throw Failure.staleReview }
        let categories = enabled
        do {
            try await resolveAdmitted(review, choosing: resolution, configuration: configuration, current: generationIsCurrent)
            // Fetch again after publication so any unreviewed branch remains visible.
            // The verified resolution baseline prevents an echo of the chosen value.
            try await sync(enabled: categories, generationIsCurrent: generationIsCurrent)
        } catch {
            let failure = safeFailure(error)
            lastError = failure.localizedDescription
            onStatusChange?()
            throw failure
        }
    }

    private func resolveAdmitted(_ review: Review, choosing resolution: Resolution, configuration: Configuration,
                                 current: @escaping @MainActor () -> Bool) async throws {
        running = true
        defer { finishPass() }
        let conflict = review.conflict
        let identity = conflict.identity
        let kind = identity.kind
        let permit = review.permit
        try check(permit, current)
        let epoch = try await currentEpoch(configuration, kind: kind, permit: permit)
        try check(permit, current)
        guard epoch == review.epoch else {
            resetObserved.insert(kind.category)
            throw Failure.staleReview
        }
        let raw = try await worker.read(configuration, kind: kind, epoch: epoch, permit: permit)
        try check(permit, current)
        let versions = try decodeRevisions(raw, kind: kind).filter { $0.identity == identity }
        let heads = Self.heads(versions)
        // Extra concurrent heads are allowed. A reviewed head that has already been
        // superseded makes the old decision stale and must be reviewed again.
        guard conflict.reviewedHeadIDs.isSubset(of: Set(heads.map(\.id))) else { throw Failure.staleReview }
        let stored = try await worker.read(configuration, kind: kind, baseline: review.account, permit: permit)
        try check(permit, current)
        guard stored.count <= 1 else { throw Failure.invalidData }
        var baselines = try stored.first.map { try JSONDecoder().decode(Baselines.self, from: $0) } ?? Baselines(epoch: epoch)
        guard baselines.schema == 1, baselines.epoch == epoch else { throw Failure.staleReview }
        let snapshot = try await local.snapshot(kind: kind, admission: { try permit.check() })
        try check(permit, current)
        let localValue = snapshot[identity]
        guard localValue.map(digest) == review.localDigest, (localValue?.count ?? 0) <= 64 * 1024 else { throw Failure.staleReview }
        let chosen: Data?
        switch resolution {
        case .keepThisMac: chosen = localValue
        case .useCloudVersion(let identifier):
            guard let selected = heads.first(where: { $0.id == identifier }), conflict.reviewedHeadIDs.contains(identifier) else { throw Failure.staleReview }
            let loaded = try await loadedHeads([selected], configuration: configuration, kind: kind, epoch: epoch, permit: permit, current: current)
            chosen = loaded.first?.value
        }
        try await verifyResolutionEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: current)
        // The local owner compares and writes in its existing serial secret lane.
        // A password edit made after the review must not be overwritten by the sheet.
        guard try await local.apply(identity, value: chosen, expected: localValue, admission: { try permit.check() }) else { throw Failure.staleReview }
        try check(permit, current)
        let revision = Revision(id: UUID(), identity: identity, parents: conflict.reviewedHeadIDs, value: chosen)
        do { try await publish(revision, configuration: configuration, epoch: epoch, permit: permit, current: current) }
        catch Failure.resetRequired { throw Failure.staleReview }
        baselines.values[identity] = Baseline(digest: chosen.map(digest), heads: [revision.id])
        try await verifyResolutionEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: current)
        try await worker.baseline(configuration, kind: kind, namespace: review.account, data: JSONEncoder().encode(baselines), permit: permit)
        try check(permit, current)
        reviewedConflicts.removeValue(forKey: conflict.id)
        conflicts.removeAll { $0.id == conflict.id }
    }

    private func admittedReview(_ conflict: Conflict, current: @MainActor () -> Bool) throws -> Review {
        guard let review = reviewedConflicts[conflict.id], review.conflict == conflict,
              accountNamespace == review.account else { throw Failure.staleReview }
        try check(review.permit, current)
        guard enabled.contains(conflict.category), admission === review.permit else { throw Failure.revoked }
        return review
    }

    private func rememberConflict(identity: Identity, heads: [Revision], localValue: Data?, account: String,
                                  epoch: String, permit: Admission) -> Conflict {
        let descriptors = heads.map { CloudVersion(id: $0.id, isDeletion: $0.valueDigest == nil) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let localDigest = localValue.map(digest)
        if let existing = reviewedConflicts.values.first(where: {
            $0.conflict.identity == identity && $0.conflict.reviewedHeads == descriptors
                && $0.localDigest == localDigest && $0.account == account && $0.epoch == epoch && $0.permit === permit
        }) { return existing.conflict }
        reviewedConflicts = reviewedConflicts.filter { $0.value.conflict.identity != identity }
        let conflict = Conflict(id: UUID(), identity: identity, reviewedHeads: descriptors)
        reviewedConflicts[conflict.id] = Review(conflict: conflict, localDigest: localDigest, account: account, epoch: epoch, permit: permit)
        return conflict
    }

    private func finishPass() {
        running = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if refreshNeeded { refreshNeeded = false; localChanged() }
    }

    private func safeFailure(_ error: Error) -> Failure {
        if let value = error as? Failure { return value }
        if let value = error as? Passwords.Failure { return .keychain(value.status) }
        if error is CancellationError { return .revoked }
        return .invalidData
    }

    private func decodeRevisions(_ raw: [Data], kind: Kind) throws -> [Revision] {
        guard raw.count <= 20_000 else { throw Failure.invalidData }
        let versions = try raw.map { data -> Revision in
            guard data.count <= 128 * 1024 else { throw Failure.invalidData }
            let revision = try JSONDecoder().decode(Revision.self, from: data)
            guard revision.schema == 1, revision.identity.kind == kind, revision.parents.count <= 20_000,
                  !revision.parents.contains(revision.id),
                  revision.valueDigest.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else { throw Failure.invalidData }
            try revision.identity.validate()
            return revision
        }
        guard Set(versions.map(\.id)).count == versions.count else { throw Failure.invalidData }
        return versions
    }

    private func publish(_ revision: Revision, configuration: Configuration, epoch: String, permit: Admission,
                         current: @MainActor () -> Bool) async throws {
        let kind = revision.identity.kind
        let bytes = try JSONEncoder().encode(revision)
        guard bytes.count <= 128 * 1024, (revision.value?.count ?? 0) <= 64 * 1024 else { throw Failure.invalidData }
        try await verifyEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: current)
        // Verify the immutable dependency before publishing metadata. Apple can deliver
        // items in another order, so readers preserve local copies until it arrives.
        if let value = revision.value {
            try await worker.add(configuration, kind: kind, account: revision.id.uuidString,
                                 data: value, epoch: epoch, payload: true, permit: permit)
            try check(permit, current)
            let payload = try await worker.read(configuration, kind: kind, account: revision.id.uuidString,
                                                epoch: epoch, payload: true, permit: permit)
            try check(permit, current)
            guard payload == [value] else { throw Failure.verification }
            try await verifyEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: current)
        }
        try await worker.add(configuration, kind: kind, account: revision.id.uuidString, data: bytes, epoch: epoch, permit: permit)
        try check(permit, current)
        let readback = try await worker.read(configuration, kind: kind, account: revision.id.uuidString, epoch: epoch, permit: permit)
        try check(permit, current)
        guard readback == [bytes] else { throw Failure.verification }
    }

    private func verifyResolutionEpoch(_ configuration: Configuration, kind: Kind, epoch: String, permit: Admission,
                                       current: @MainActor () -> Bool) async throws {
        do { try await verifyEpoch(configuration, kind: kind, epoch: epoch, permit: permit, current: current) }
        catch Failure.resetRequired { throw Failure.staleReview }
    }

    /// Caller has confirmed the separate Keychain-removal wording and paused the controller.
    /// An immutable reset marker fences old clients before any secret copies are deleted.
    /// Local originals and baselines are retained; deletion is never a switch side effect.
    func removeCloudData(enabled categories: Set<ICloudCategory>) async throws {
        pause()
        guard let configuration else { throw Failure.unavailable }
        let permit = admission
        for kind in [Kind.passwords, .aiKeys] where categories.contains(kind.category) {
            let marker = ResetMarker(id: UUID())
            let bytes = try JSONEncoder().encode(marker)
            try await worker.add(configuration, kind: kind, account: marker.id.uuidString, data: bytes, control: true, permit: permit)
            let verified = try await worker.read(configuration, kind: kind, account: marker.id.uuidString, control: true, permit: permit)
            guard verified == [bytes] else { throw Failure.verification }
            try await worker.remove(configuration, kind: kind, permit: permit)
            resetObserved.insert(kind.category)
        }
        onStatusChange?()
    }

    private func currentEpoch(_ configuration: Configuration, kind: Kind, permit: Admission) async throws -> String {
        let raw = try await worker.read(configuration, kind: kind, control: true, permit: permit)
        guard raw.count <= 4096 else { throw Failure.invalidData }
        let markers = try raw.map { bytes -> ResetMarker in
            guard bytes.count <= 1024 else { throw Failure.invalidData }
            let marker = try JSONDecoder().decode(ResetMarker.self, from: bytes)
            guard marker.schema == 1 else { throw Failure.invalidData }
            return marker
        }
        guard Set(markers.map(\.id)).count == markers.count else { throw Failure.invalidData }
        return markers.isEmpty ? "initial" : digest(Data(markers.map { $0.id.uuidString }.sorted().joined(separator: ":").utf8))
    }
    private func verifyEpoch(_ configuration: Configuration, kind: Kind, epoch: String, permit: Admission, current: @MainActor () -> Bool) async throws {
        try check(permit, current)
        let refreshed = try await currentEpoch(configuration, kind: kind, permit: permit)
        try check(permit, current)
        guard refreshed == epoch else {
            resetObserved.insert(kind.category)
            throw Failure.resetRequired(kind.category)
        }
    }

    private func check(_ permit: Admission, _ current: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard current(), permit.valid else { throw Failure.revoked }
    }
    private static func heads(_ revisions: [Revision]) -> [Revision] {
        let superseded = revisions.reduce(into: Set<UUID>()) { $0.formUnion($1.parents) }
        return revisions.filter { !superseded.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private func loadedHeads(_ versions: [Revision], configuration: Configuration, kind: Kind, epoch: String,
                             permit: Admission, current: @MainActor () -> Bool) async throws -> [Revision] {
        var heads = Self.heads(versions)
        guard versions.isEmpty || !heads.isEmpty else { throw Failure.invalidData }
        for index in heads.indices {
            guard let expectedDigest = heads[index].valueDigest else { continue }
            try check(permit, current)
            let payloads = try await worker.read(configuration, kind: kind, account: heads[index].id.uuidString,
                                                epoch: epoch, payload: true, permit: permit)
            try check(permit, current)
            guard payloads.count == 1, let value = payloads.first,
                  value.count <= 64 * 1024, digest(value) == expectedDigest else { throw Failure.verification }
            heads[index].value = value
        }
        return heads
    }
    private func localChanged() {
        guard !enabled.isEmpty, let generation, generation() else { return }
        if running { refreshNeeded = true; return }
        let permit = admission
        Task { @MainActor [weak self] in
            guard let self, self.admission === permit, permit.valid, generation() else { return }
            await self.onSyncRequested?()
        }
    }
    private func scheduleRefresh() {
        guard refresh == nil, !enabled.isEmpty, generation?() == true else { return }
        refresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                self.localChanged()
            }
        }
    }

    private static func provisionedConfiguration() -> Configuration? {
        // Provisioning validates this executable's signed group before any secret query.
        // Test copies never gain access to the production mirror merely by being signed.
        guard Store.overrideDirectory == nil, let provisioning = try? ICloudProvisioning.current() else { return nil }
        return Configuration(accessGroup: provisioning.keychainGroup, namespace: "production")
    }

    private final class Admission: @unchecked Sendable {
        private let lock = NSLock()
        private var admitted = true
        var valid: Bool { lock.withLock { admitted } }
        func revoke() { lock.withLock { admitted = false } }
        func check() throws { guard valid else { throw Failure.revoked } }
    }
    private final class ObserverToken: @unchecked Sendable {
        let value: NSObjectProtocol
        init(_ value: NSObjectProtocol) { self.value = value }
        deinit { NotificationCenter.default.removeObserver(value) }
    }
    private actor Worker {
        let keychain: any ICloudSecretsKeychain
        init(keychain: any ICloudSecretsKeychain) { self.keychain = keychain }
        func read(_ configuration: Configuration, kind: Kind, account: String? = nil, baseline: String? = nil, epoch: String? = nil, control: Bool = false, payload: Bool = false, permit: Admission) throws -> [Data] {
            try permit.check()
            return try keychain.read(configuration.query(kind: kind, account: baseline == nil ? account : "baseline", baseline: baseline, epoch: epoch, control: control, payload: payload))
        }
        func add(_ configuration: Configuration, kind: Kind, account: String, data: Data, epoch: String? = nil, control: Bool = false, payload: Bool = false, permit: Admission) throws {
            try permit.check()
            var attributes = configuration.query(kind: kind, account: account, epoch: epoch, control: control, payload: payload)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecValueData as String] = data
            try keychain.add(attributes)
        }
        func baseline(_ configuration: Configuration, kind: Kind, namespace: String, data: Data, permit: Admission) throws {
            try permit.check()
            try keychain.replace(configuration.query(kind: kind, account: "baseline", baseline: namespace), data: data)
        }
        func remove(_ configuration: Configuration, kind: Kind, permit: Admission) throws {
            try permit.check()
            try keychain.remove(configuration.query(kind: kind))
            try permit.check()
            try keychain.remove(configuration.query(kind: kind, payload: true))
        }
        func removePayload(_ configuration: Configuration, kind: Kind, account: String, epoch: String, permit: Admission) throws {
            try permit.check()
            try keychain.remove(configuration.query(kind: kind, account: account, epoch: epoch, payload: true))
        }
    }

    private struct SystemKeychain: ICloudSecretsKeychain {
        func read(_ query: [String: Any]) throws -> [Data] {
            var query = query
            query[kSecReturnAttributes as String] = true
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
            guard let rows = result as? [[String: Any]] else { throw Failure.invalidData }
            return try rows.map { row in
                guard let data = row[kSecValueData as String] as? Data else { throw Failure.invalidData }
                return data
            }
        }
        func add(_ attributes: [String: Any]) throws {
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }
        func replace(_ query: [String: Any], data: Data) throws {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try add(attributes)
            } else if status != errSecSuccess { throw Failure.keychain(status) }
        }
        func remove(_ query: [String: Any]) throws {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
        }
    }

    private final class SystemLocalStore: ICloudSecretsLocalStore {
        func snapshot(kind: Kind, admission: @escaping @Sendable () throws -> Void) async throws -> [Identity: Data] {
            switch kind {
            case .passwords:
                return try await Passwords.perform { try Passwords.iCloudSnapshot(admission: admission) }
            case .aiKeys:
                let namespace = Store.overrideDirectory.map { UserDefaults.suiteName(forDataDir: $0) }
                let mapping = try ICloudAIConnections.cloudAccounts(in: ICloudAIConnections.local(UserDefaults.vane))
                let accounts = Set(mapping.values)
                let local = try await Task.detached { try AIKeys.iCloudSnapshot(namespace: namespace, accounts: accounts, admission: admission) }.value
                var result: [Identity: Data] = [:]
                for (cloud, account) in mapping {
                    if let value = local[.aiKey(account: account)] { result[.aiKey(account: cloud)] = value }
                }
                return result
            }
        }
        func apply(_ identity: Identity, value: Data?, expected: Data?, admission: @escaping @Sendable () throws -> Void) async throws -> Bool {
            switch identity.kind {
            case .passwords:
                guard let profileID = identity.profileID, let origin = identity.origin,
                      let url = URL(string: origin), let parsed = PasswordOrigin(url: url) else { throw Failure.invalidData }
                return try await Passwords.perform {
                    try admission()
                    let current = try Passwords.passwordCheckedForSync(origin: parsed, account: identity.account, profileID: profileID, admission: admission).map { Data($0.utf8) }
                    guard current == expected else { return false }
                    if current == value { return true }
                    try admission()
                    if let value {
                        guard let text = String(data: value, encoding: .utf8) else { throw Failure.invalidData }
                        try Passwords.saveChecked(origin: parsed, account: identity.account, password: text, profileID: profileID, admission: admission)
                    } else if current != nil { try Passwords.deleteChecked(origin: parsed, account: identity.account, profileID: profileID, admission: admission) }
                    return true
                }
            case .aiKeys:
                let namespace = Store.overrideDirectory.map { UserDefaults.suiteName(forDataDir: $0) }
                let accounts = try ICloudAIConnections.cloudAccounts(in: ICloudAIConnections.local(UserDefaults.vane))
                guard let localAccount = accounts[identity.account] else {
                    throw ICloudFailure.unavailable("This AI key awaits its API connection. Enable portable preferences or restore that connection before retrying. ChatGPT credentials stay local.")
                }
                let applied = try await Task.detached { try AIKeys.iCloudApply(account: localAccount, namespace: namespace, value: value, expected: expected, admission: admission) }.value
                if applied { BrowserAI.settingsChanged() }
                return applied
            }
        }
    }
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
