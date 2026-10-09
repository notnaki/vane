import Foundation
import Combine

/// Boards keep their owning profile even when the Library presents them together.
/// Backups can contain the same board UUID in several profiles.
struct EaselLibraryEntry: Identifiable, Equatable {
    struct ID: Hashable {
        let profileID: UUID
        let boardID: UUID
    }
    let profileID: UUID
    let profileName: String
    let board: EaselBoard
    var id: ID { ID(profileID: profileID, boardID: board.id) }

    func matches(_ query: String) -> Bool {
        Library.matches([board.title, profileName], query)
    }
}

@MainActor final class GlobalEaselLibrary: ObservableObject {
    struct RepositoryFailure: Identifiable, Equatable {
        let profileID: UUID
        let profileName: String
        let message: String
        var id: UUID { profileID }
    }

    @Published private(set) var entries: [EaselLibraryEntry] = []
    @Published private(set) var failures: [RepositoryFailure] = []
    private var profiles: [Profile] = []
    private var repositories: [UUID: EaselStore] = [:]
    private var boards: [UUID: [EaselBoard]] = [:]
    private var errors: [UUID: String] = [:]
    private var profileSubscription: AnyCancellable?
    private var repositorySubscriptions: [AnyCancellable] = []
    private var rebuilding = false
    private let directory: URL

    init(manager: ProfileManager = .shared) {
        directory = manager.directory
        profileSubscription = manager.$profiles.sink { [weak self] profiles in
            self?.replaceProfiles(profiles)
        }
    }

    func repository(for profileID: UUID) -> EaselStore? { repositories[profileID] }

    /// Resolve the latest saved board through its owner, never the initiating window.
    func board(for entry: EaselLibraryEntry) throws -> EaselBoard {
        guard let board = repositories[entry.profileID]?.board(entry.board.id) else {
            throw EaselStore.Failure.missing
        }
        return board
    }

    func delete(_ entry: EaselLibraryEntry) throws {
        _ = try board(for: entry)
        try repositories[entry.profileID]?.delete(entry.board.id)
    }

    func retry(_ profileID: UUID) { repositories[profileID]?.reload() }

    private func replaceProfiles(_ profiles: [Profile]) {
        rebuilding = true
        repositorySubscriptions.removeAll()
        self.profiles = profiles
        repositories = [:]
        boards = [:]
        errors = [:]
        for profile in profiles {
            let repository = EaselStore.shared(profileID: profile.id, directory: directory)
            repositories[profile.id] = repository
            repositorySubscriptions.append(
                Publishers.CombineLatest(repository.$boards, repository.$error).sink { [weak self] boards, error in
                    guard let self else { return }
                    self.boards[profile.id] = boards
                    self.errors[profile.id] = error
                    if !self.rebuilding { self.publish() }
                }
            )
        }
        rebuilding = false
        publish()
    }

    private func publish() {
        entries = profiles.flatMap { profile in
            (boards[profile.id] ?? []).map {
                EaselLibraryEntry(profileID: profile.id, profileName: profile.name, board: $0)
            }
        }.sorted {
            if $0.board.modified != $1.board.modified { return $0.board.modified > $1.board.modified }
            if $0.profileID != $1.profileID { return $0.profileID.uuidString < $1.profileID.uuidString }
            return $0.board.id.uuidString < $1.board.id.uuidString
        }
        failures = profiles.compactMap { profile in
            errors[profile.id].map {
                RepositoryFailure(profileID: profile.id, profileName: profile.name, message: $0)
            }
        }
    }
}
