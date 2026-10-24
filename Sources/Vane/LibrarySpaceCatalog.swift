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

    init(load: @escaping Loader = LibrarySpaceCatalog.read) { self.load = load }

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
    @discardableResult func prepare(manager: ProfileManager = .shared,
                                    force: Bool = false) -> Task<Void, Never>? {
        let key = Key(manager)
        if owner !== manager {
            cancel()
            owner = manager; persisted = []; loadedKey = nil
        }
        if !force, requestedKey == key { return task }
        if !force, loadedKey == key, contentValid { return nil }
        task?.cancel()
        if force { editEpoch &+= 1 }
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
        request &+= 1
        task?.cancel(); task = nil; requestedKey = nil
        contentValid = false
        if loading { loading = false }
    }
    deinit { task?.cancel() }

    func hasSnapshot(manager: ProfileManager = .shared) -> Bool { owner === manager && loadedKey != nil }

    func spaces(manager: ProfileManager = .shared, preview: Space? = nil) -> [Space] {
        guard owner === manager else { return [] }
        // Filter removed owners immediately, even before the metadata observer fires.
        var spaces = manager.profiles.flatMap { profile in
            persisted.filter { $0.space.profileID == profile.id }.map(\.space)
        }
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
