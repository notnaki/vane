import Combine
import SwiftUI

/// Own the snapshot without forwarding its loading/editor notifications to the
/// entire browser window. Only SpacesPane observes the catalog's presentation.
@MainActor final class LibrarySpaceCatalogLifetime: ObservableObject {
    let catalog = LibrarySpaceCatalog()
}

/// A presentation-only snapshot. Space switching, saving, drops and authentication
/// still revalidate against their existing synchronous stores.
@MainActor final class LibrarySpaceCatalog: ObservableObject {
    struct Entry: Equatable {
        let space: Space
        let pinned: Pins?
        let today: Pins?

        var visibleToday: [URL] {
            space.tabURLs.filter {
                today?.lockedFolders(for: $0.absoluteString, unlocked: []).isEmpty ?? true
            }
        }
    }
    typealias Loader = @Sendable (URL, [UUID]) -> [Entry]

    private struct Key: Equatable {
        let directory: URL
        let profiles: [UUID]
        let revision: Int
        @MainActor init(_ manager: ProfileManager) {
            directory = manager.directory
            profiles = manager.profiles.map(\.id)
            revision = manager.spacesRevision
        }
    }
    private struct Metadata: Equatable {
        let profiles: [Profile]
        let revision: Int
    }

    @Published private(set) var generation = 0
    @Published private(set) var protectionEpoch = 0
    @Published private(set) var loading = false
    @Published private(set) var editEpoch = 0
    // Retain identity rather than storing an ObjectIdentifier that could be reused.
    private var owner: ProfileManager?
    private var loadedKey: Key?
    private var requestedKey: Key?
    private var persisted: [Entry] = []
    private var contentValid = false
    private var request = 0
    private var task: Task<Void, Never>?
    private let load: Loader
    private weak var observedManager: ProfileManager?
    private var changes: AnyPublisher<Void, Never>?

    private var registryObservation: AnyCancellable?
    private var storeObservations: [AnyCancellable] = []
    private var observingContents = false
    private var protectionRefresh: Task<Void, Never>?

    init(load: @escaping Loader = LibrarySpaceCatalog.read) {
        self.load = load
        registryObservation = TabStore.storesChanged.sink { [weak self] in
            guard let self, self.observingContents else { return }
            let before = self.observedStores
            self.observeStores()
            // A store leaving (window closed, parked store released) can hand its card
            // back to a saved snapshot that predates its latest shape. New stores only rebind.
            if !before.isSubset(of: self.observedStores) { self.revokeProtection() }
        }
    }

    /// Cards can read any profile's live owner, independently of their hosting window.
    /// Rebind when windows appear/disappear; revoke before the next render or disk read.
    private var observedStores: Set<ObjectIdentifier> = []
    private func observeStores() {
        observedStores = Set(TabStore.all.map(ObjectIdentifier.init))
        storeObservations = TabStore.all.flatMap { store in
            [store.sidebarSnapshotChanges.sink { [weak self] in self?.generation &+= 1 },
             // Protection changes revoke retained rows. So does a Space switch: while a
             // store owns a Space its card reads the live shape, so the saved snapshot can
             // be stale (e.g. a tab moved into an unlocked protected folder) exactly when
             // the card falls back to it. Ordinary shape edits reload nothing.
             Publishers.Merge(store.sidebarRowsProtectionRevoked,
                              store.$currentSpaceID.dropFirst().removeDuplicates().map { _ in () })
                .sink { [weak self] in self?.revokeProtection() }]
        }
    }

    private func revokeProtection() {
        guard observingContents else { return }
        request &+= 1
        task?.cancel(); task = nil; requestedKey = nil
        contentValid = false
        protectionEpoch &+= 1
        generation &+= 1
        protectionRefresh?.cancel()
        // @Published shapes emit in willSet; lockFolder also saves legacy defaults
        // after revoking its grants. Reload only after that synchronous mutation ends.
        protectionRefresh = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.observingContents, let manager = self.owner else { return }
            self.protectionRefresh = nil
            self.prepare(manager: manager, force: true, resetEditors: false)
        }
    }

    /// Read each profile's metadata once, then resolve both shapes from that same
    /// Space. UserDefaults.vane is explicitly thread-safe/nonisolated in Store.swift.
    /// A matching valid layout wins; missing/invalid defaults retain savedShape's nil fallback.
    nonisolated static func read(directory: URL, profiles: [UUID]) -> [Entry] {
        profiles.flatMap { profile -> [Entry] in
            guard !Task.isCancelled,
                  let data = try? Data(contentsOf: ProfileManager.spacesURL(for: profile, in: directory)),
                  let spaces = try? JSONDecoder().decode([Space].self, from: data)
            else { return [] }
            return spaces.filter { $0.profileID == profile }.map { space in
                if let layout = space.layout, layout.matches(space), (try? layout.validate()) != nil {
                    let urls = Dictionary(uniqueKeysWithValues: layout.tabs.map {
                        ($0.id.uuidString, $0.savedURL.absoluteString)
                    })
                    return Entry(space: space, pinned: layout.pins.mapped { urls[$0] },
                                 today: layout.today.mapped { urls[$0] })
                }
                func shape(_ kind: TabKind) -> Pins? {
                    guard let data = UserDefaults.vane.data(forKey:
                        TabStore.shapeKey(kind, space: space.id, profileID: profile)) else { return nil }
                    return try? JSONDecoder().decode(Pins.self, from: data)
                }
                return Entry(space: space, pinned: shape(.pinned), today: shape(.today))
            }
        }
    }

    /// Published emits in willSet. Read the completed manager state after its burst,
    /// rather than enqueueing work with an old revision/profile list.
    func metadataChanges(manager: ProfileManager) -> AnyPublisher<Void, Never> {
        if observedManager === manager, let changes { return changes }
        observedManager = manager
        let changes = manager.$profiles.removeDuplicates()
            .combineLatest(manager.$spacesRevision.removeDuplicates())
            .map { Metadata(profiles: $0.0, revision: $0.1) }
            .removeDuplicates()
            .debounce(for: .zero, scheduler: DispatchQueue.main)
            .map { _ in () }.eraseToAnyPublisher()
        self.changes = changes
        return changes
    }

    /// force starts a new open epoch even if only an external writer changed disk.
    /// During refresh retain card metadata, but not saved rows whose lock shape may
    /// have changed. Live-owner cards bypass the saved snapshot on the main actor.
    /// `resetEditors: false` reloads rows for a protection change without revoking an open
    /// Space editor: the editor edits Space metadata, not the rows being re-gated.
    @discardableResult func prepare(manager: ProfileManager = .shared,
                                    force: Bool = false, resetEditors: Bool = true) -> Task<Void, Never>? {
        let key = Key(manager)
        if owner !== manager {
            cancel()
            owner = manager; persisted = []; loadedKey = nil
        }
        if !observingContents {
            observingContents = true
            observeStores()
        }
        if !force, requestedKey == key { return task }
        if !force, loadedKey == key, contentValid { return nil }
        task?.cancel()
        if force, resetEditors { editEpoch &+= 1 }
        request &+= 1
        let ticket = request, load = load
        requestedKey = key
        contentValid = false
        if !loading { loading = true }
        task = Task { [weak self, weak manager] in
            let worker = Task.detached(priority: .userInitiated) { load(key.directory, key.profiles) }
            let entries = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.request == ticket, self.requestedKey == key else { return }
            self.requestedKey = nil; self.task = nil
            guard let manager, self.owner === manager, Key(manager) == key else {
                self.loading = false
                return
            }
            self.persisted = entries
            self.loadedKey = key
            self.contentValid = true
            self.loading = false
            self.generation &+= 1
        }
        return task
    }

    /// Dismissal revokes worker publication/new saved-row admission, retaining card
    /// metadata for reopening. A still-current editor may finish its normal disappearance
    /// commit; a force-reopen epoch or external revision revokes that editor separately.
    func cancel() {
        observingContents = false
        storeObservations.removeAll(); observedStores = []
        protectionRefresh?.cancel(); protectionRefresh = nil
        request &+= 1
        task?.cancel(); task = nil; requestedKey = nil
        contentValid = false
        if loading { loading = false }
    }
    deinit { task?.cancel(); protectionRefresh?.cancel() }

    func hasSnapshot(manager: ProfileManager = .shared) -> Bool { owner === manager && loadedKey != nil }

    func spaces(manager: ProfileManager = .shared, preview: Space? = nil) -> [Space] {
        guard owner === manager else { return [] }
        // Filter removed owners immediately, even before the metadata observer fires.
        let owners = Set(manager.profiles.map(\.id))
        // Cards stand in the live strip's order, the footer's and the swipe's, rather than
        // the snapshot's: a reorder shows at once, not when the reload it may cause lands.
        let rank = Dictionary(manager.allSpaces.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var spaces = persisted.map(\.space).filter { owners.contains($0.profileID) }.enumerated().sorted {
            (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset)
        }.map(\.element)
        if let preview, let index = spaces.firstIndex(where: {
            $0.id == preview.id && $0.profileID == preview.profileID
        }) { spaces[index] = preview }
        return spaces
    }

    func entry(for space: Space, manager: ProfileManager = .shared) -> Entry? {
        guard owner === manager, contentValid, !loading, loadedKey == Key(manager),
              manager.profiles.contains(where: { $0.id == space.profileID }) else { return nil }
        return persisted.first { $0.space.id == space.id && $0.space.profileID == space.profileID }
    }
    /// A retained card is display metadata, not permission to edit an old Space.
    /// Existing editors also check this lease before previewing or committing, so
    /// dismissing a revoked popover cannot run ThemeEditor's onDisappear save.
    @MainActor final class Editing: Identifiable {
        let id = UUID()
        let space: Space
        private let catalog: LibrarySpaceCatalog
        private let manager: ProfileManager
        private var key: Key
        private let epoch: Int

        fileprivate init(space: Space, catalog: LibrarySpaceCatalog, manager: ProfileManager) {
            self.space = space; self.catalog = catalog; self.manager = manager
            key = Key(manager); epoch = catalog.editEpoch
        }
        var isCurrent: Bool {
            catalog.owner === manager && catalog.editEpoch == epoch && key == Key(manager)
        }
        /// No await separates admission, mutation, and renewal. Only the editor's
        /// own single revision may renew; another mutation/profile change revokes it.
        @discardableResult func perform(_ mutation: () -> Void) -> Bool {
            guard isCurrent else { return false }
            let previous = key
            mutation()
            let current = Key(manager)
            if catalog.owner === manager, catalog.editEpoch == epoch,
               current.directory == previous.directory, current.profiles == previous.profiles,
               current.revision == previous.revision &+ 1 { key = current }
            return true
        }
    }

    func beginEditing(for space: Space, manager: ProfileManager = .shared) -> Editing? {
        guard let entry = entry(for: space, manager: manager) else { return nil }
        return Editing(space: entry.space, catalog: self, manager: manager)
    }

}

private struct LibrarySpaceCatalogKey: EnvironmentKey {
    static let defaultValue: LibrarySpaceCatalog? = nil
}
extension EnvironmentValues {
    /// Optional so standalone LibraryPanel hosts keep their existing public API.
    var librarySpaceCatalog: LibrarySpaceCatalog? {
        get { self[LibrarySpaceCatalogKey.self] }
        set { self[LibrarySpaceCatalogKey.self] = newValue }
    }
}
