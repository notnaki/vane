import Combine
import Foundation

/// The palette only renders an in-memory snapshot. Reading and decoding the saved
/// metadata belongs to a worker; previews remain live and never enter persistence.
@MainActor final class PaletteSpaceCatalog: ObservableObject {
    struct Metadata: Equatable {
        let profiles: [Profile]
        let revision: Int

        @MainActor init(_ manager: ProfileManager) {
            profiles = manager.profiles
            revision = manager.spacesRevision
        }
    }

    private var metadataManager: ObjectIdentifier?
    private var metadataPublisher: AnyPublisher<Metadata, Never>?

    /// A stable subscription for a mounted palette. Published emits in willSet;
    /// coalesce the burst before reading the completed manager mutation.
    func metadataChanges(manager: ProfileManager) -> AnyPublisher<Metadata, Never> {
        let identity = ObjectIdentifier(manager)
        if metadataManager == identity, let metadataPublisher { return metadataPublisher }
        let publisher = manager.$profiles.removeDuplicates()
            .combineLatest(manager.$spacesRevision.removeDuplicates())
            .debounce(for: .zero, scheduler: DispatchQueue.main)
            .map { _ in MainActor.assumeIsolated { Metadata(manager) } }
            .removeDuplicates()
            .eraseToAnyPublisher()
        metadataManager = identity
        metadataPublisher = publisher
        return publisher
    }

    typealias Loader = @Sendable (URL, [UUID]) -> [Space]
    private struct Key: Equatable {
        let manager: ObjectIdentifier
        let directory: URL
        let profiles: [UUID]
        let revision: Int

        @MainActor init(_ manager: ProfileManager) {
            self.manager = ObjectIdentifier(manager)
            directory = manager.directory
            profiles = manager.profiles.map(\.id)
            revision = manager.spacesRevision
        }
    }

    @Published private(set) var generation = 0
    private let load: Loader
    private var loadedKey: Key?
    private var requestedKey: Key?
    private var persisted: [Space] = []
    private var request = 0
    private var task: Task<Void, Never>?

    init(load: @escaping Loader = PaletteSpaceCatalog.read) { self.load = load }

    /// No migrations, writes, live models, or UI objects cross onto this worker.
    nonisolated static func read(directory: URL, profiles: [UUID]) -> [Space] {
        profiles.flatMap { profile -> [Space] in
            guard !Task.isCancelled,
                  let data = try? Data(contentsOf: ProfileManager.spacesURL(for: profile, in: directory)),
                  let spaces = try? JSONDecoder().decode([Space].self, from: data)
            else { return [] }
            return spaces.filter { $0.profileID == profile }
        }
    }

    @discardableResult func prepare(manager: ProfileManager = .shared) -> Task<Void, Never>? {
        let key = Key(manager)
        guard key != loadedKey, key != requestedKey else { return task }
        task?.cancel()
        request &+= 1
        let ticket = request, load = load
        requestedKey = key
        task = Task { [weak self, weak manager] in
            let worker = Task.detached(priority: .userInitiated) { load(key.directory, key.profiles) }
            let spaces = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self,
                  self.request == ticket, self.requestedKey == key
            else { return }
            self.requestedKey = nil
            self.task = nil
            guard let manager, Key(manager) == key else { return }
            self.persisted = spaces
            self.loadedKey = key
            self.generation &+= 1
        }
        return task
    }

    /// Dismissal invalidates even workers that cannot cancel an in-progress file read.
    func cancel() {
        request &+= 1
        task?.cancel()
        task = nil
        requestedKey = nil
        loadedKey = nil
        persisted = []
    }

    deinit { task?.cancel() }

    func strip(manager: ProfileManager = .shared, preview: Space? = nil) -> [Space] {
        guard loadedKey == Key(manager) else { return [] }
        guard let preview, let index = persisted.firstIndex(where: {
            $0.id == preview.id && $0.profileID == preview.profileID
        }) else { return persisted }
        var result = persisted
        result[index] = preview
        return result
    }

    func spaces(for profileID: UUID, manager: ProfileManager = .shared,
                preview: Space? = nil) -> [Space] {
        strip(manager: manager, preview: preview).filter { $0.profileID == profileID }
    }
}
