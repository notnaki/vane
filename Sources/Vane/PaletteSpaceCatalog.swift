import Foundation

/// Saved Space metadata belongs to the open palette, rather than each query. Keep
/// persistence reads unchanged elsewhere; live previews are folded over this snapshot.
@MainActor final class PaletteSpaceCatalog {
    typealias Loader = @MainActor (ProfileManager, [Profile]) -> [Space]
    private let load: Loader
    private weak var cachedManager: ProfileManager?
    private var profileIDs: [UUID] = []
    private var revision: Int?
    private var persisted: [Space] = []

    init(load: @escaping Loader = { manager, profiles in
        Spaces.strip(profiles: profiles) { manager.spaces(for: $0.id) }
    }) {
        self.load = load
    }

    func strip(manager: ProfileManager = .shared, preview: Space? = nil) -> [Space] {
        let ids = manager.profiles.map(\.id)
        if cachedManager !== manager || ids != profileIDs || revision != manager.spacesRevision {
            persisted = load(manager, manager.profiles)
            cachedManager = manager
            profileIDs = ids
            revision = manager.spacesRevision
        }
        guard let preview, let index = persisted.firstIndex(where: { $0.id == preview.id })
        else { return persisted }
        var result = persisted
        result[index] = preview
        return result
    }

    func spaces(for profileID: UUID, manager: ProfileManager = .shared,
                preview: Space? = nil) -> [Space] {
        strip(manager: manager, preview: preview).filter { $0.profileID == profileID }
    }
}
