import Combine
import Foundation

/// A shared view of regular profiles' downloads. The owning manager still handles
/// transfers, save locations, resume credentials, bookmarks, and persistence.
@MainActor final class DownloadLibrary: ObservableObject {
    private static let shared = DownloadLibrary(profiles: .shared) { Downloads.manager(for: $0) }
    private static let incognito = DownloadLibrary(managers: [Downloads.manager(for: Profile.incognito.id)])

    static func library(for profileID: UUID) -> DownloadLibrary {
        profileID == Profile.incognito.id ? incognito : shared
    }

    private var managers: [Downloads] = []
    private var profileSubscription: AnyCancellable?
    private var listSubscriptions: [AnyCancellable] = []
    private var rowSubscriptions: [UUID: [AnyCancellable]] = [:]

    var items: [Downloads.Item] {
        managers.flatMap(\.items).enumerated().sorted { lhs, rhs in
            let left = lhs.element.completed ?? lhs.element.started
            let right = rhs.element.completed ?? rhs.element.started
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    init(managers: [Downloads]) {
        observe(managers)
    }

    init(profiles: ProfileManager, resolve: @escaping (UUID) -> Downloads) {
        profileSubscription = profiles.$profiles.map { $0.map(\.id) }
            .removeDuplicates().sink { [weak self] ids in
                self?.observe(ids.filter { $0 != Profile.incognito.id }.map(resolve))
            }
    }

    private func observe(_ managers: [Downloads]) {
        objectWillChange.send()
        listSubscriptions.removeAll()
        rowSubscriptions.removeAll()
        self.managers = managers
        for manager in managers {
            let id = manager.profileID
            listSubscriptions.append(manager.$items.sink { [weak self] items in
                guard let self else { return }
                // Forward row changes too: finishing a transfer changes Media membership
                // and the footer ring without inserting or removing a download row.
                self.rowSubscriptions[id] = items.map { item in
                    item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
                }
                self.objectWillChange.send()
            })
        }
    }

    func owner(of item: Downloads.Item) -> Downloads? {
        managers.first { manager in manager.items.contains { $0 === item } }
    }

    func clear() { managers.forEach { $0.clear() } }
    func refreshMissing() { managers.forEach { $0.refreshMissing() } }
}
