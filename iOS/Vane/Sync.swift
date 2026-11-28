import Foundation

/// The Mac's `ICloudController.performSync`, minus Keychain secrets, extensions and removal UI.
/// The journal, transport and conflict rules are the Mac's own files.
@MainActor @Observable final class Sync {
    private(set) var status = "iCloud sync is off"
    private(set) var busy = false
    private(set) var lastSuccess: Date?
    let available: Bool
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "icloud.enabled")
            status = enabled ? "Waiting to sync" : "iCloud sync is off"
            if enabled { Task { await run() } }
        }
    }
    private let library: Library
    private let transport = ICloudKitTransport(removalDirectory: Store.directory)
    private var journal: ICloudJournal?
    private var again = false
    private var debounce: Task<Void, Never>?

    init(library: Library) {
        self.library = library
        enabled = UserDefaults.standard.bool(forKey: "icloud.enabled")
        switch ICloudKitTransport.capability() {
        case .success: available = true
        case .failure(let error): available = false; status = error.localizedDescription
        }
        if available && enabled { status = "Waiting to sync" }
    }

    /// Coalesces a burst of local edits into one exchange.
    func soon() {
        debounce?.cancel()
        debounce = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { await run() } }
    }

    /// Every record iCloud has exchanged with this phone, live or deleted. One of these that
    /// the library no longer holds was deleted here, so an import must not bring it back.
    func knownKeys() async throws -> Set<String> {
        let directory = Store.directory, device = library.deviceID
        var journal = journal
        if journal == nil, FileManager.default.fileExists(atPath: directory.appending(path: "icloud-journal.json").path) {
            journal = try await Task.detached { try ICloudJournal(directory: directory, deviceID: device) }.value
        }
        guard let journal else { return [] }
        let all = Set(ICloudCategory.allCases)
        return Set((await journal.items(enabled: all) + journal.deleted(enabled: all)).map(\.key))
    }

    func run() async {
        guard enabled, available else { return }
        guard !busy else { again = true; return }
        busy = true
        defer { busy = false; if again { again = false; Task { await run() } } }
        let enabled = library.categories
        do {
            status = "Checking iCloud…"
            if journal == nil {
                let directory = Store.directory, device = library.deviceID
                journal = try await Task.detached { try ICloudJournal(directory: directory, deviceID: device) }.value
            }
            let journal = journal!
            if try await transport.hasPendingRemovals() { status = "Finish removing iCloud data on your Mac first"; return }
            let account = try await transport.account()
            // A different Apple Account never receives the previous account's library.
            if await journal.resets(for: account) { library.dropSynced(enabled) }
            try await journal.bindAccount(account, allowMerge: true)
            try await journal.capture(try await library.capture(enabled), enabled: enabled)
            try await journal.mergeFences(try await transport.exchangeFences(await journal.deletionFences()))
            status = "Syncing…"
            let result = try await transport.exchange(
                pending: await journal.pending(enabled: enabled), enabled: enabled,
                state: await journal.engineState, epochs: await journal.epochs,
                persistState: { data in try await journal.setEngineState(data, expectedAccount: account) })
            guard try await transport.account() == account else { throw ICloudFailure.accountChanged }
            if !result.reset.isEmpty {
                // Removed from iCloud on a Mac: drop the copies here rather than upload them again.
                try await journal.reset(result.reset)
                try await journal.setEpochs(result.epochs)
                library.dropSynced(result.reset)
                status = "iCloud data was removed on another device"
                return
            }
            let before = try await library.capture(enabled)
            try await journal.capture(before, enabled: enabled)
            _ = try await journal.merge(result.received)
            let items = await journal.items(enabled: enabled), deleted = await journal.deleted(enabled: enabled)
            try await ICloudApplyContext.$baseline.withValue(Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })) {
                try await library.apply(items, deleted: deleted, enabled: enabled)
            }
            try await journal.markApplied(try await library.capture(enabled), enabled: enabled)
            try await journal.acknowledge(result.acknowledged)
            if let state = result.state { try await journal.setEngineState(state, expectedAccount: account) }
            try await journal.setEpochs(result.epochs)
            lastSuccess = .now
            status = "Up to date"
        } catch ICloudFailure.accountChanged {
            _ = try? await transport.rebindAccount()
            status = "Your Apple Account changed. Syncing again with the new account."
            again = true
        } catch is CancellationError {
            status = "iCloud sync is paused"
        } catch {
            status = error.localizedDescription
        }
    }
}
