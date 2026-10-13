import Combine
import Foundation

/// Shared Library rows keep their profile identity for restore and removal.
@MainActor final class ArchiveLibrary: ObservableObject {
    struct Source {
        let profile: Profile
        let archive: Archive
    }
    struct Entry: Identifiable, Sendable {
        struct ID: Hashable, Sendable { let profile: UUID; let url: String }
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

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var revision = 0
    let search = Feel05ArchiveSearch()
    private var rows: [UUID: [Archive.Entry]] = [:]
    private var replacing = false

    /// Called only after clear section intent, never from view evaluation.
    func prepare() async {
        _ = await search.groups(entries, revision: revision, query: "", littleOnly: false)
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
        replacing = true
        subscriptions.removeAll()
        self.sources = sources
        rows.removeAll()
        subscriptions = sources.map { source in
            source.archive.$entries.sink { [weak self] entries in
                guard let self else { return }
                self.rows[source.profile.id] = entries
                if !self.replacing { self.publish() }
            }
        }
        replacing = false
        publish()
    }

    private func publish() {
        entries = sources.flatMap { source in
            (rows[source.profile.id] ?? []).map { Entry(profile: source.profile, entry: $0) }
        }
        revision &+= 1
    }

    func owner(of row: Entry) -> Archive? {
        sources.first { $0.profile.id == row.profile.id }?.archive
    }
    func clear() { sources.forEach { $0.archive.clear() } }
}
