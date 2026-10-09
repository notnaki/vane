import Combine
import Foundation

struct ReadingQueueIdentity: Hashable, Sendable {
    var profileID: UUID
    var articleID: UUID
}

struct ReadingQueueItem: Identifiable, Sendable {
    var profileID: UUID
    var profileName: String
    var article: ReadingArticle
    var id: ReadingQueueIdentity { .init(profileID: profileID, articleID: article.id) }
}

struct ReadingQueueOwnedDamage: Identifiable, Sendable {
    var profileID: UUID
    var profileName: String
    var entry: ReadingQueueDamage
    var id: ReadingQueueIdentity { .init(profileID: profileID, articleID: entry.id) }
}

/// Keeps the Library inventory global while every mutation remains in its owner's store.
@MainActor final class ReadingQueueCollection: ObservableObject {
    struct Failure: Identifiable {
        var id: UUID
        var profileName: String
        var message: String
    }
    struct Revision: Equatable, Sendable {
        var profileID: UUID
        var profileName: String
        var revision: Int
    }
    @Published private(set) var profiles: [Profile] = []
    @Published private var repositories: [UUID: ReadingQueueStore] = [:]
    @Published private var openErrors: [UUID: String] = [:]
    private var profileObservation: AnyCancellable?
    private var repositoryObservations: [UUID: AnyCancellable] = [:]
    private let loadRepository: (UUID) throws -> ReadingQueueStore

    init(manager: ProfileManager = .shared, loadRepository: ((UUID) throws -> ReadingQueueStore)? = nil) {
        self.loadRepository = loadRepository ?? { try ReadingQueueStore.shared(profileID: $0, directory: manager.directory) }
        reconcile(manager.profiles)
        profileObservation = manager.$profiles.dropFirst().sink { [weak self] in self?.reconcile($0) }
    }

    private func reconcile(_ savedProfiles: [Profile], retryFailures: Bool = false) {
        profiles = savedProfiles.filter { $0.id != Profile.incognito.id }
        let ids = Set(profiles.map(\.id))
        repositories = repositories.filter { ids.contains($0.key) }
        repositoryObservations = repositoryObservations.filter { ids.contains($0.key) }
        openErrors = openErrors.filter { ids.contains($0.key) }
        for profile in profiles where repositories[profile.id] == nil {
            guard retryFailures || openErrors[profile.id] == nil else { continue }
            open(profile.id)
        }
    }

    private func open(_ profileID: UUID) {
        do {
            let repository = try loadRepository(profileID)
            repositories[profileID] = repository
            openErrors[profileID] = nil
            repositoryObservations[profileID] = repository.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        } catch { openErrors[profileID] = error.localizedDescription }
    }

    func repository(for profileID: UUID) -> ReadingQueueStore? {
        guard let repository = repositories[profileID], !repository.invalidated else { return nil }
        return repository
    }

    func reload(profileID: UUID? = nil) {
        for profile in profiles where profileID == nil || profile.id == profileID {
            if let repository = repository(for: profile.id) { repository.reload() }
            else { open(profile.id) }
        }
    }

    var items: [ReadingQueueItem] {
        profiles.flatMap { profile in
            (repository(for: profile.id)?.articles ?? []).map {
                ReadingQueueItem(profileID: profile.id, profileName: profile.name, article: $0)
            }
        }
    }
    var damaged: [ReadingQueueOwnedDamage] {
        profiles.flatMap { profile in
            (repository(for: profile.id)?.damaged ?? []).map {
                ReadingQueueOwnedDamage(profileID: profile.id, profileName: profile.name, entry: $0)
            }
        }
    }
    var failures: [Failure] {
        profiles.compactMap { profile in
            guard let message = openErrors[profile.id] ?? repository(for: profile.id)?.error else { return nil }
            return Failure(id: profile.id, profileName: profile.name, message: message)
        }
    }
    var usage: ReadingQueueUsage {
        profiles.reduce(into: ReadingQueueUsage()) { total, profile in
            guard let usage = repository(for: profile.id)?.usage else { return }
            total.articleCount += usage.articleCount
            total.publishedBytes += usage.publishedBytes
            total.pendingCleanupBytes += usage.pendingCleanupBytes
        }
    }
    var loading: Bool { repositories.values.contains { !$0.invalidated && $0.loading } }
    var revisions: [Revision] {
        profiles.map { .init(profileID: $0.id, profileName: $0.name, revision: repository(for: $0.id)?.revision ?? -1) }
    }
}
