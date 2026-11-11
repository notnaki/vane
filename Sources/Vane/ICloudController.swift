import AppKit
import Combine
import CloudKit
import Foundation

@MainActor final class ICloudController: ObservableObject {
    private static var activeInstance: ICloudController?
    static let shared: ICloudController = {
        let controller = ICloudController()
        activeInstance = controller
        return controller
    }()
    static func quiesceIfRunning() { activeInstance?.revoke(); activeInstance?.stopped = true }
    static func suspendIfRunning() async { await activeInstance?.suspend() }
    static func finishIfRunning() async -> Bool { await activeInstance?.flushAndStop() ?? true }
    static func resumeIfRunning() { activeInstance?.start() }
    static func requestSyncIfRunning() {
        guard let controller = activeInstance, controller.masterEnabled, !controller.stopped else { return }
        Task { @MainActor in await controller.syncNow() }
    }
    @Published private(set) var masterEnabled: Bool
    @Published private(set) var enabledCategories: Set<ICloudCategory>
    @Published private(set) var busy = false
    @Published private(set) var status = "iCloud sync is off"
    @Published private(set) var lastError: String?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var needsAccountConsent = false
    @Published private(set) var secretConflicts: [ICloudSecrets.Conflict] = []
    @Published private(set) var pendingRemoval = false
    let canEnable: Bool
    let library: ICloudLibraryAdapter?
    var credentialReviewBridge: ICloudSecrets? { secrets }
    func credentialReviewAdmission(for conflict: ICloudSecrets.Conflict) -> @MainActor () -> Bool {
        let token = generation
        return { [weak self] in
            guard let self else { return false }
            return self.admitted(token) && self.enabledCategories.contains(conflict.category)
        }
    }
    private let directory: URL
    private let defaults: UserDefaults
    private let transport: any ICloudTransport
    private let adapters: [any ICloudAdapter]
    private let secrets: ICloudSecrets?
    private let recovery: @MainActor () async throws -> Void
    private let deviceID: String
    private var journal: ICloudJournal?
    private var generation: UInt64 = 0
    private var stopped = false
    private var started = false
    private var polling: Task<Void, Never>?
    private var activeSync: Task<Void, Never>?
    private var activeAdmission: ICloudAdmission?
    private var activeSyncID: UUID?
    private var removalInProgress = false
    private var wake: NSObjectProtocol?
    private var accountChange: AnyCancellable?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(directory: URL = Store.directory, defaults: UserDefaults = .vane,
         transport: (any ICloudTransport)? = nil, adapters: [any ICloudAdapter]? = nil,
         secrets: ICloudSecrets? = nil, recovery: (@MainActor () async throws -> Void)? = nil) {
        self.directory = directory; self.defaults = defaults
        deviceID = defaults.string(forKey: "icloud.deviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "icloud.deviceID")
        masterEnabled = defaults.bool(forKey: "icloud.enabled")
        enabledCategories = Set(ICloudCategory.allCases.filter { category in
            defaults.object(forKey: Self.key(category)) as? Bool ?? category.defaultEnabled
        })
        if let transport {
            self.transport = transport; canEnable = true
        } else {
            self.transport = ICloudKitTransport()
            switch ICloudKitTransport.capability() {
            case .success: canEnable = true
            case .failure(let error): canEnable = false; status = error.localizedDescription
            }
        }
        if let adapters {
            self.adapters = adapters
            library = adapters.compactMap { $0 as? ICloudLibraryAdapter }.first
            self.secrets = secrets
        } else {
            let library = ICloudLibraryAdapter(directory: directory, defaults: defaults, deviceID: deviceID)
            self.library = library
            self.adapters = [library, ICloudContentAdapter(manager: library.profiles, defaults: defaults),
                             ICloudPreferencesAdapter(directory: directory, defaults: defaults),
                             ICloudExtensionStorageAdapter(directory: directory,
                                 profileIDs: { library.profiles.profiles.map(\.id) },
                                 ensureProfile: { try library.profiles.ensureICloudProfile($0) })]
            self.secrets = secrets ?? ICloudSecrets()
        }
        self.recovery = recovery ?? {
            await ImportOperations.drain()
            await PendingSessionTransactions.drain()
            await ProfileManager.shared.waitForTransactions()
            await Library.waitForMoves()
            try await Store.flushAllPendingWrites()
            try await EaselStore.flushAll(directory: directory)
            guard ProfileManager.shared.retryProfileSave(), Session.enqueueSave(), await Session.flushPersistence() else {
                throw ICloudFailure.storage("Your current library could not be saved before enabling iCloud sync.")
            }
            let library = BackupLibrary(directory: directory, defaults: defaults, domain: UserDefaults.vaneDomain)
            try await BackupWorker.shared.run {
                let archive = try library.capture(reason: .automatic)
                _ = try BackupRecovery(library: library).save(archive)
            }
        }
        lastSuccess = defaults.object(forKey: "icloud.lastSuccess") as? Date
        self.secrets?.onStatusChange = { [weak self] in self?.refreshSecretStatus() }
        self.secrets?.onSyncRequested = { [weak self] in await self?.syncNow() }
        let observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.masterEnabled else { return }
                self.requireAccountReview()
            }
        }
        accountChange = AnyCancellable { NotificationCenter.default.removeObserver(observer) }
    }

    private func refreshSecretStatus() {
        guard let secrets else { return }
        Motion.list { secretConflicts = secrets.conflicts }
        if !secrets.resetObserved.isEmpty {
            let removed = secrets.resetObserved
            revoke(); enabledCategories.subtract(removed); saveSwitches()
            status = "Credentials were removed from iCloud. Review the affected categories before merging again."
        } else if let error = secrets.lastError { lastError = error }
        else if !secrets.conflicts.isEmpty {
            lastError = "Conflicting credential changes were kept. Review saved credentials before relying on the synced copy."
        }
    }

    private static func key(_ category: ICloudCategory) -> String { "icloud.category." + category.rawValue }
    private func revoke() {
        generation &+= 1
        activeAdmission?.revoke()
        activeSync?.cancel()
        transport.revoke()
        secrets?.pause()
    }
    private func requireAccountReview() {
        revoke(); masterEnabled = false; needsAccountConsent = true; saveSwitches()
        lastError = ICloudFailure.accountChanged.localizedDescription; status = "Review your Apple Account"
    }
    private func saveSwitches() {
        defaults.set(masterEnabled, forKey: "icloud.enabled")
        for category in ICloudCategory.allCases { defaults.set(enabledCategories.contains(category), forKey: Self.key(category)) }
        if !defaults.synchronize() { lastError = "Vane could not save your iCloud choices. Sync is paused."; masterEnabled = false }
    }

    func start() {
        stopped = false
        guard !started else { return }
        started = true
        wake = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, !self.stopped else { return }
                await self.syncNow()
            }
        }
        Task {
            do { if !(try await checkPendingRemoval()) { await syncNow() } }
            catch {
                revoke(); masterEnabled = false; pendingRemoval = true; saveSwitches()
                lastError = error.localizedDescription; status = "An unfinished iCloud removal needs attention"
            }
        }
    }

    func setEnabled(_ enabled: Bool, for category: ICloudCategory) {
        revoke()
        if enabled { enabledCategories.insert(category) } else { enabledCategories.remove(category) }
        if enabled && category.isSecret { secrets?.acknowledgeReset(enabled: [category]) }
        saveSwitches()
        if !enabled { status = "\(category.title) sync is off; existing copies are kept" }
    }
    func selectAll() {
        revoke()
        enabledCategories = Set(ICloudCategory.allCases)
        secrets?.acknowledgeReset(enabled: enabledCategories.filter(\.isSecret))
        saveSwitches()
    }
    func setMasterEnabled(_ enabled: Bool) async {
        if enabled && removalInProgress { return }
        revoke()
        if !enabled { masterEnabled = false; status = "iCloud sync is off"; saveSwitches(); return }
        let admitted = generation
        if busy { await withCheckedContinuation { completionWaiters.append($0) } }
        guard !removalInProgress, generation == admitted else { return }
        guard canEnable else { lastError = "This Vane build is not provisioned for iCloud. Use an iCloud-enabled signed build."; return }
        do {
            if try await checkPendingRemoval() { return }
            guard generation == admitted else { return }
            try await recovery()
            guard generation == admitted else { return }
            secrets?.acknowledgeReset(enabled: enabledCategories.filter(\.isSecret))
            masterEnabled = true; stopped = false; lastError = nil
            saveSwitches()
            await syncNow()
        } catch {
            guard generation == admitted else { return }
            lastError = error.localizedDescription; status = "iCloud sync is paused"
        }
    }

    private func prepareJournal() async throws -> ICloudJournal {
        if let journal { return journal }
        let directory = directory, deviceID = deviceID
        let opened = try await Task.detached(priority: .utility) { try ICloudJournal(directory: directory, deviceID: deviceID) }.value
        journal = opened
        return opened
    }
    private func checkPendingRemoval() async throws -> Bool {
        let pending = try await transport.hasPendingRemovals()
        pendingRemoval = pending
        if pending {
            revoke(); masterEnabled = false; saveSwitches()
            status = "Finish the previously confirmed iCloud removal before enabling sync"
        }
        return pending
    }
    private func admitted(_ value: UInt64) -> Bool { generation == value && masterEnabled && !stopped && !Task.isCancelled }

    @discardableResult private func capture(_ enabled: Set<ICloudCategory>, into journal: ICloudJournal, admitted token: UInt64) async throws -> [ICloudItem] {
        if let library {
            let inventory = try await library.ancestorInventory()
            guard admitted(token) else { throw CancellationError() }
            try await journal.observeAncestorInventory(inventory)
        }
        var items: [ICloudItem] = []
        for adapter in adapters {
            let categories = enabled.intersection(adapter.categories)
            guard !categories.isEmpty else { continue }
            let captured = try await adapter.capture(categories)
            guard admitted(token) else { throw CancellationError() }
            items.append(contentsOf: captured)
        }
        guard admitted(token) else { throw CancellationError() }
        try await journal.capture(items, enabled: enabled.filter { !$0.isSecret })
        return items
    }

    func syncNow() async {
        guard activeSync == nil, masterEnabled, canEnable, !stopped, !removalInProgress else { return }
        let identity = UUID()
        let admission = ICloudAdmission()
        activeAdmission = admission
        activeSyncID = identity
        let work = Task { await ICloudApplyContext.$admission.withValue(admission) { await performSync() } }
        activeSync = work
        await work.value
        if activeSyncID == identity { activeSync = nil; activeSyncID = nil; activeAdmission = nil }
    }

    private func performSync() async {
        guard masterEnabled, canEnable, !busy, !stopped else { return }
        let token = generation
        let enabled = enabledCategories
        guard !enabled.isEmpty else { status = "Choose at least one category to sync"; return }
        busy = true; lastError = nil; status = "Checking iCloud…"
        defer {
            busy = false
            let waiters = completionWaiters; completionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            if try await checkPendingRemoval() { return }
            guard admitted(token) else { return }
            let journal = try await prepareJournal()
            let account = try await transport.account()
            guard admitted(token) else { return }
            try await journal.bindAccount(account, allowMerge: false)
            guard admitted(token) else { return }
            try library?.setAccountNamespace(account)
            secrets?.setAccountNamespace(account)
            try await capture(enabled, into: journal, admitted: token)
            guard admitted(token) else { return }
            if enabled.contains(where: { !$0.isSecret }) {
                let fences = try await transport.exchangeFences(await journal.deletionFences())
                guard admitted(token) else { return }
                try await journal.mergeFences(fences)
                try library?.applyAncestorFences(fences, enabled: enabled)
                guard admitted(token) else { return }
            }
            let pending = await journal.pending(enabled: enabled)
            status = "Syncing your selected data…"
            let result = try await transport.exchange(pending: pending, enabled: enabled.filter { !$0.isSecret },
                state: await journal.engineState, epochs: await journal.epochs,
                persistState: { [weak self] data in
                    guard await self?.admitted(token) == true else { throw CancellationError() }
                    try await journal.setEngineState(data, expectedAccount: account)
                })
            guard admitted(token) else { return }
            let currentAccount = try await transport.account()
            guard admitted(token) else { return }
            guard currentAccount == account else { throw ICloudFailure.accountChanged }
            if !result.reset.isEmpty {
                revoke()
                enabledCategories.subtract(result.reset)
                try await journal.reset(result.reset)
                try await journal.setEpochs(result.epochs)
                saveSwitches()
                status = "iCloud data was removed on another Mac. Review your choices to resume."
                return
            }
            guard result.received.allSatisfy({ enabled.contains($0.category) && !$0.category.isSecret }) else {
                throw ICloudFailure.invalid("iCloud returned a disabled data category.")
            }
            // Include edits made while the network was awaiting its response before
            // applying remote fields over the live local owners.
            let beforeApply = try await capture(enabled, into: journal, admitted: token)
            _ = try await journal.merge(result.received)
            guard admitted(token) else { return }
            let items = await journal.items(enabled: enabled)
            let deleted = await journal.deleted(enabled: enabled)
            for adapter in adapters {
                let categories = enabled.intersection(adapter.categories)
                guard !categories.isEmpty else { continue }
                try Task.checkCancellation()
                try await ICloudApplyContext.$baseline.withValue(Dictionary(beforeApply.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })) {
                    try await adapter.apply(items.filter { categories.contains($0.category) },
                        deleted: deleted.filter { categories.contains($0.category) }, enabled: categories)
                }
                guard admitted(token) else { return }
            }
            // Read back exactly what each local owner durably accepted. Redacted
            // permissions and local-only details must not turn into echo writes.
            var applied: [ICloudItem] = []
            for adapter in adapters {
                let categories = enabled.intersection(adapter.categories)
                if !categories.isEmpty { applied += try await adapter.capture(categories) }
                guard admitted(token) else { return }
            }
            try await journal.markApplied(applied, enabled: enabled.filter { !$0.isSecret })
            try await journal.acknowledge(result.acknowledged)
            if let state = result.state { try await journal.setEngineState(state, expectedAccount: account) }
            try await journal.setEpochs(result.epochs)
            guard admitted(token) else { return }
            if !enabled.filter(\.isSecret).isEmpty {
                guard let secrets, secrets.isAvailable else { throw ICloudFailure.unavailable("iCloud Keychain is unavailable in this build. Your local passwords and API keys have been kept.") }
                try await secrets.sync(enabled: enabled.filter(\.isSecret), generationIsCurrent: { [weak self] in self?.admitted(token) == true })
                if !secrets.conflicts.isEmpty {
                    throw ICloudFailure.unavailable("Some saved credentials have conflicting changes from another Mac. Both versions have been kept; review them before relying on the synced copy.")
                }
            }
            guard admitted(token) else { return }
            lastSuccess = .now; defaults.set(lastSuccess, forKey: "icloud.lastSuccess")
            let pendingExtensions = enabled.contains(.extensionSyncData)
                ? adapters.compactMap { $0 as? ICloudExtensionStorageAdapter }.reduce(0) { $0 + $1.pendingExtensionCount } : 0
            status = pendingExtensions > 0
                ? "Library synced; data for \(pendingExtensions) extension(s) awaits local activation"
                : "Your selected data is up to date"
        } catch is CancellationError {
            if generation == token { status = "iCloud sync is paused" }
        } catch ICloudSecrets.Failure.resetRequired(let category) {
            revoke(); enabledCategories.remove(category); saveSwitches()
            status = "\(category.title) were removed from iCloud. Turn this category on deliberately to merge local copies again."
        } catch ICloudFailure.accountChanged {
            requireAccountReview()
        } catch {
            guard generation == token else { return }
            lastError = error.localizedDescription; status = "iCloud sync needs attention"
        }
    }

    func mergeWithCurrentAccount() async {
        guard !removalInProgress, canEnable else { return }
        revoke()
        let token = generation
        if busy { await withCheckedContinuation { completionWaiters.append($0) } }
        guard !removalInProgress, generation == token else { return }
        do {
            if try await checkPendingRemoval() { return }
            guard generation == token else { return }
            try await recovery()
            guard generation == token else { return }
            let journal = try await prepareJournal()
            guard generation == token else { return }
            let account = try await transport.rebindAccount()
            guard generation == token else { return }
            try await journal.bindAccount(account, allowMerge: true)
            guard generation == token else { return }
            needsAccountConsent = false; masterEnabled = true; stopped = false; saveSwitches()
            await syncNow()
        } catch {
            guard generation == token else { return }
            lastError = error.localizedDescription
        }
    }
    func resolveSecretConflict(_ conflict: ICloudSecrets.Conflict, choosing choice: ICloudSecrets.Resolution) async {
        guard masterEnabled, enabledCategories.contains(conflict.category), !busy, let secrets else { return }
        let token = generation
        busy = true; lastError = nil; status = "Resolving the selected credential…"
        defer {
            busy = false
            let waiters = completionWaiters; completionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            try await secrets.resolve(conflict, choosing: choice, generationIsCurrent: { [weak self] in self?.admitted(token) == true })
            refreshSecretStatus()
            if admitted(token) { status = secretConflicts.isEmpty ? "Credential choice saved" : "Additional credential changes need review" }
        } catch {
            refreshSecretStatus()
            if generation == token { lastError = error.localizedDescription; status = "Credential choice needs review" }
        }
    }
    func resumeCloudRemoval() async {
        guard !busy, !removalInProgress, canEnable else { return }
        removalInProgress = true
        revoke(); masterEnabled = false; saveSwitches()
        busy = true; lastError = nil; status = "Finishing the previously confirmed iCloud removal…"
        defer {
            removalInProgress = false
            busy = false
            let waiters = completionWaiters; completionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            try await transport.resumeRemovals()
            pendingRemoval = try await transport.hasPendingRemovals()
            guard !pendingRemoval else { throw ICloudFailure.storage("Some iCloud removals remain pending. Retry with the original Apple Account.") }
            status = "Previously confirmed removal finished. Local copies are kept; sync remains off."
        } catch {
            pendingRemoval = (try? await transport.hasPendingRemovals()) ?? true
            lastError = error.localizedDescription; status = "iCloud removal needs attention"
        }
    }
    func removeCloudData(_ categories: Set<ICloudCategory>) async {
        guard !removalInProgress else { return }
        // Own admission before the first await: no receipt exists yet while
        // account/namespace lookup runs, but re-enabling could already reupload.
        removalInProgress = true
        defer { removalInProgress = false }
        revoke(); masterEnabled = false; saveSwitches()
        if busy { await withCheckedContinuation { completionWaiters.append($0) } }
        busy = true; lastError = nil; status = "Removing selected iCloud data…"
        defer {
            busy = false
            let waiters = completionWaiters; completionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            let journal = try await prepareJournal()
            let account = try await transport.account()
            try await journal.bindAccount(account, allowMerge: false)
            let ordinary = categories.filter { !$0.isSecret }
            if !ordinary.isEmpty { try await transport.remove(ordinary) }
            else { try await transport.resumeRemovals() }
            if !categories.filter(\.isSecret).isEmpty { try await secrets?.removeCloudData(enabled: categories.filter(\.isSecret)) }
            try await journal.reset(categories)
            pendingRemoval = try await transport.hasPendingRemovals()
            guard !pendingRemoval else { throw ICloudFailure.storage("Earlier iCloud removals are still pending. Finish removal with the original Apple Account.") }
            status = "Selected iCloud data removed. Local copies are kept."
            lastSuccess = nil; defaults.removeObject(forKey: "icloud.lastSuccess")
        } catch {
            pendingRemoval = (try? await transport.hasPendingRemovals()) ?? true
            lastError = error.localizedDescription; status = "iCloud removal needs attention"
        }
    }

    /// Stop applying cloud mutations before restore or quit takes local persistence
    /// ownership. Checkpointing does not wait for network availability.
    func suspend() async {
        revoke(); stopped = true
        if busy { await withCheckedContinuation { completionWaiters.append($0) } }
        polling?.cancel(); polling = nil
        if let wake { NotificationCenter.default.removeObserver(wake); self.wake = nil }
        started = false
    }
    func pauseAfterRestore() {
        revoke(); masterEnabled = false; saveSwitches()
        status = "Your backup was restored. Review your iCloud categories before merging this library."
    }
    func flushAndStop() async -> Bool {
        await suspend()
        polling?.cancel(); polling = nil
        if let wake { NotificationCenter.default.removeObserver(wake); self.wake = nil }
        started = false
        guard masterEnabled else { return true }
        do {
            let journal = try await prepareJournal()
            var items: [ICloudItem] = []
            for adapter in adapters {
                let categories = enabledCategories.intersection(adapter.categories)
                if !categories.isEmpty { items += try await adapter.capture(categories) }
            }
            try await journal.capture(items, enabled: enabledCategories.filter { !$0.isSecret })
            try await journal.checkpoint()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
}
