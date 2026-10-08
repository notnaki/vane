import Foundation
import WebKit
import SwiftUI

/// Records remain attached to the store which fetched them. Names are WebKit's site groups,
/// not origins; neither filesystem inspection nor private size APIs belong in this view.
struct WebsiteDataEntry: Identifiable {
    var id: String { name }
    let name: String
    let types: Set<String>
    var diskUsage: Int64? { nil } // No public WKWebsiteDataRecord size API, including macOS 27.
    fileprivate var records: [WKWebsiteDataRecord] = []
    fileprivate var owner: UUID?

    init(name: String, types: Set<String>) { self.name = name; self.types = types }
    fileprivate init(name: String, types: Set<String>, records: [WKWebsiteDataRecord], owner: UUID) {
        self.name = name; self.types = types; self.records = records; self.owner = owner
    }
}

enum WebsiteDataCategory {
    static func title(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: "Cookies"
        case WKWebsiteDataTypeLocalStorage: "Local storage"
        case WKWebsiteDataTypeSessionStorage: "Session storage"
        case WKWebsiteDataTypeIndexedDBDatabases: "IndexedDB databases"
        case WKWebsiteDataTypeWebSQLDatabases: "WebSQL databases"
        case WKWebsiteDataTypeFileSystem: "File system storage"
        case WKWebsiteDataTypeServiceWorkerRegistrations: "Service workers"
        case WKWebsiteDataTypeDiskCache: "Disk cache"
        case WKWebsiteDataTypeMemoryCache: "Memory cache"
        case WKWebsiteDataTypeFetchCache: "Offline fetch cache"
        case WKWebsiteDataTypeOfflineWebApplicationCache: "Offline application cache"
        case WKWebsiteDataTypeSearchFieldRecentSearches: "Recent searches"
        case WKWebsiteDataTypeMediaKeys: "Media licenses"
        case WKWebsiteDataTypeHashSalt: "Device identifier salt"
        case WKWebsiteDataTypeScreenTime: "Screen Time data"
        default: "Other website data (\(type))"
        }
    }

    @MainActor static func effects(_ types: Set<String>) -> String {
        var effects: [String] = []
        if !types.isDisjoint(with: BrowsingData.dataTypes(cookies: true, cache: false)) {
            effects.append("You may be signed out, and site preferences, offline work or saved website files may be lost.")
        }
        if !types.isDisjoint(with: BrowsingData.dataTypes(cookies: false, cache: true)) {
            effects.append("Cached resources will need to download again; offline pages may stop working.")
        }
        if types.contains(WKWebsiteDataTypeMediaKeys) {
            effects.append("Protected media may need a new license.")
        }
        return effects.joined(separator: " ")
    }
}

@MainActor protocol WebsiteDataBackend: AnyObject {
    func fetch(_ completion: @escaping (Result<[WebsiteDataEntry], Error>) -> Void)
    func remove(_ entry: WebsiteDataEntry, types: Set<String>, completion: @escaping (Result<Void, Error>) -> Void)
}

@MainActor final class WebKitWebsiteDataBackend: WebsiteDataBackend {
    private let store: WKWebsiteDataStore
    private let owner = UUID()
    private enum StoreKey: Hashable {
        case named(UUID), defaultStore, ephemeral(ObjectIdentifier)
    }
    private static var clearing: Set<StoreKey> = []
    private let key: StoreKey
    init(store: WKWebsiteDataStore) {
        self.store = store
        key = store.identifier.map(StoreKey.named)
            ?? (store.isPersistent ? .defaultStore : .ephemeral(ObjectIdentifier(store)))
    }

    func fetch(_ completion: @escaping (Result<[WebsiteDataEntry], Error>) -> Void) {
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [self] records in
            var grouped: [String: WebsiteDataEntry] = [:]
            for record in records {
                let previous = grouped[record.displayName]
                grouped[record.displayName] = WebsiteDataEntry(
                    name: record.displayName, types: (previous?.types ?? []).union(record.dataTypes),
                    records: (previous?.records ?? []) + [record], owner: owner)
            }
            completion(.success(Array(grouped.values)))
        }
    }

    func remove(_ entry: WebsiteDataEntry, types: Set<String>, completion: @escaping (Result<Void, Error>) -> Void) {
        guard entry.owner == owner, !entry.records.isEmpty, !types.isEmpty,
              types.isSubset(of: entry.types) else {
            completion(.failure(NSError(domain: "VaneWebsiteData", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected data no longer belongs to this view. Refresh and try again."])))
            return
        }
        guard Self.clearing.insert(key).inserted else {
            completion(.failure(NSError(domain: "VaneWebsiteData", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Another clear operation is still running in this profile. Wait, then refresh before trying again."])))
            return
        }
        // Retain the store and its lock even if the user closes the view mid-operation.
        // WebKit provides no error argument here. The controller verifies a new snapshot.
        store.removeData(ofTypes: types, for: entry.records) { [self] in
            Self.clearing.remove(key)
            completion(.success(()))
        }
    }
}

@MainActor final class WebsiteDataModel: ObservableObject {
    let profileID: UUID
    @Published private(set) var entries: [WebsiteDataEntry] = []
    @Published var query = "" {
        didSet {
            if let selectedName, !filteredEntries.contains(where: { $0.name == selectedName }), !isBusy {
                select(nil)
            }
        }
    }
    @Published private(set) var selectedName: String?
    @Published var selectedTypes: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var activity = "Loading website data…"
    private let backend: any WebsiteDataBackend
    private let isValid: () -> Bool
    private let timeout: Duration
    private var token: UUID?
    private var watchdog: Task<Void, Never>?
    private var initialHost: String?

    init(profileID: UUID, backend: any WebsiteDataBackend, isValid: @escaping () -> Bool = { true },
         timeout: Duration = .seconds(20), initialHost: String? = nil) {
        self.profileID = profileID
        self.backend = backend
        self.isValid = isValid
        self.timeout = timeout
        self.initialHost = initialHost
    }

    convenience init(profileID: UUID, store: WKWebsiteDataStore, isValid: @escaping () -> Bool,
                     initialHost: String? = nil) {
        self.init(profileID: profileID, backend: WebKitWebsiteDataBackend(store: store),
                  isValid: isValid, initialHost: initialHost)
    }

    var filteredEntries: [WebsiteDataEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }
    var selectedEntry: WebsiteDataEntry? { entries.first { $0.name == selectedName } }
    var canClear: Bool { !isBusy && selectedEntry.map { !$0.types.intersection(selectedTypes).isEmpty } == true }

    func select(_ name: String?) {
        guard !isBusy else { return }
        selectedName = name
        selectedTypes = selectedEntry?.types ?? []
        message = nil
    }

    func refresh() {
        guard !isBusy, validate() else { return }
        let operation = begin("Loading website data…", removing: false)
        backend.fetch { [weak self] result in
            guard let self, self.token == operation else { return }
            guard self.validate() else { self.finish(); return }
            switch result {
            case .failure(let failure): self.error = "Couldn’t load website data. \(failure.localizedDescription)"
            case .success(let entries):
                self.apply(entries)
                if let host = self.initialHost {
                    self.selectedName = self.entries.first { SiteControlModel.covers(record: $0.name, host: host) }?.name
                    self.selectedTypes = self.selectedEntry?.types ?? []
                    self.initialHost = nil
                }
            }
            self.finish()
        }
    }

    func clearSelection() {
        guard canClear, validate(), let entry = selectedEntry else { return }
        let types = entry.types.intersection(selectedTypes)
        let operation = begin("Clearing data for \(entry.name)…", removing: true)
        backend.remove(entry, types: types) { [weak self] result in
            guard let self, self.token == operation else { return }
            guard self.validate() else { self.finish(); return }
            switch result {
            case .failure(let failure):
                self.error = "Couldn’t clear website data. \(failure.localizedDescription)"
                self.finish()
            case .success:
                self.activity = "Checking remaining website data…"
                self.watch(operation, removing: false, verifying: true)
                self.backend.fetch { [weak self] result in
                    guard let self, self.token == operation else { return }
                    guard self.validate() else { self.finish(); return }
                    switch result {
                    case .failure(let failure):
                        self.error = "Clearing finished, but the result couldn’t be verified. Refresh to check. \(failure.localizedDescription)"
                    case .success(let entries):
                        self.apply(entries)
                        let remaining = self.entries.first { $0.name == entry.name }?.types ?? []
                        if !remaining.isDisjoint(with: types) {
                            self.error = "Some selected data is still reported for \(entry.name). Open pages may have recreated it, or WebKit may have retained it. Close this site’s tabs, refresh and try again."
                        } else {
                            self.error = nil
                            self.message = "Selected stored data cleared for \(entry.name). Reload open pages to use the updated data; pages can store new data again."
                        }
                    }
                    self.finish()
                }
            }
        }
    }

    private func validate() -> Bool {
        guard isValid() else {
            error = "This profile is no longer available. Close this view."
            message = nil
            return false
        }
        return true
    }

    private func apply(_ entries: [WebsiteDataEntry]) {
        Motion.list {
            self.entries = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            hasLoaded = true
            selectedTypes.formIntersection(selectedEntry?.types ?? [])
            if selectedEntry == nil { selectedName = nil }
        }
    }

    private func begin(_ activity: String, removing: Bool) -> UUID {
        let operation = UUID()
        token = operation
        isBusy = true
        error = nil
        message = nil
        self.activity = activity
        watch(operation, removing: removing)
        return operation
    }

    private func watch(_ operation: UUID, removing: Bool, verifying: Bool = false) {
        watchdog?.cancel()
        watchdog = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.token == operation else { return }
            if removing {
                self.error = "WebKit is taking longer than expected. Clearing may still be running; its result has not been verified."
                // A timeout does not cancel WebKit. Prevent overlapping destructive retries.
            } else {
                self.error = verifying
                    ? "Clearing finished, but WebKit hasn’t returned updated data. Refresh to verify the result."
                    : "WebKit hasn’t returned website data. Refresh to try again."
                self.finish() // Late read callbacks are ignored by the operation token.
            }
        }
    }

    private func finish() {
        watchdog?.cancel()
        watchdog = nil
        token = nil
        isBusy = false
    }
}
