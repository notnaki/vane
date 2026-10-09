import Combine
import Foundation

/// Shared Library rows keep their profile identity for restore and removal.
@MainActor final class ArchiveLibrary: ObservableObject {
    struct Source {
        let profile: Profile
        let archive: Archive
    }
    struct Entry: Identifiable {
        struct ID: Hashable { let profile: UUID; let url: String }
        let profile: Profile
        let entry: Archive.Entry
        var id: ID { ID(profile: profile.id, url: entry.url) }
    }

    private static let shared = ArchiveLibrary(profiles: .shared)
    private static let incognito = ArchiveLibrary(sources: [Source(profile: .incognito, archive: .shared(for: Profile.incognito.id))])
    static func library(for profileID: UUID) -> ArchiveLibrary {
        profileID == Profile.incognito.id ? incognito : shared
    }

    private var sources: [Source] = []
    private var profileSubscription: AnyCancellable?
    private var subscriptions: [AnyCancellable] = []

    var entries: [Entry] {
        sources.flatMap { source in source.archive.entries.map { Entry(profile: source.profile, entry: $0) } }
    }

    init(sources: [Source]) { observe(sources) }
    init(profiles: ProfileManager) {
        profileSubscription = profiles.$profiles.sink { [weak self] profiles in
            self?.observe(profiles.filter { $0.id != Profile.incognito.id }.map {
                Source(profile: $0, archive: .shared(for: $0.id))
            })
        }
    }

    private func observe(_ sources: [Source]) {
        objectWillChange.send()
        subscriptions.removeAll()
        self.sources = sources
        subscriptions = sources.map { source in
            source.archive.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    func owner(of row: Entry) -> Archive? {
        sources.first { $0.profile.id == row.profile.id }?.archive
    }
    func clear() { sources.forEach { $0.archive.clear() } }
}
