import Foundation

struct BackupPreview: Sendable {
    struct ProfileSummary: Identifiable, Sendable {
        var id: UUID
        var name: String
        var spaces: Int
        var tabs: Int
        var bookmarks: Int
        var history: Int
        var easels: Int
        var readingQueue = 0
    }
    var profiles: [ProfileSummary]
    var settings: Int
    var hasExternalFolders: Bool
    var spaces: Int { profiles.reduce(0) { $0 + $1.spaces } }
    var tabs: Int { profiles.reduce(0) { $0 + $1.tabs } }
    var bookmarks: Int { profiles.reduce(0) { $0 + $1.bookmarks } }
    var history: Int { profiles.reduce(0) { $0 + $1.history } }
    var easels: Int { profiles.reduce(0) { $0 + $1.easels } }
    var readingQueue: Int { profiles.reduce(0) { $0 + $1.readingQueue } }
}

/// Synchronous capture is one main-actor boundary: no window/profile mutations can
/// interleave its reads. Expensive archive encoding and writes consume immutable bytes.
@MainActor struct BackupLibrary {
    let directory: URL
    let defaults: UserDefaults
    let domain: String
    struct Profiles: Codable { var profiles: [Profile]; var activeID: UUID }

    static func isLocalPreference(_ key: String) -> Bool {
        key.hasPrefix("backup.") || ["blockerLastGoodList", "firstLaunchWelcome"].contains(key)
    }
    func currentPreferences(includeLocal: Bool = false) throws -> Data {
        let all = defaults.persistentDomain(forName: domain) ?? [:]
        let kept = includeLocal ? all : all.filter { !Self.isLocalPreference($0.key) }
        return try PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0)
    }
    func applyPreferences(_ data: Data, includeLocal: Bool = false) throws {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BackupError.invalid("Invalid preferences.")
        }
        var incoming = includeLocal ? values : values.filter { !Self.isLocalPreference($0.key) }
        if !includeLocal {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] where Self.isLocalPreference(key) {
                incoming[key] = value
            }
        }
        defaults.setPersistentDomain(incoming, forName: domain)
        guard defaults.synchronize() else { throw BackupError.storage("Could not persist restored settings.") }
    }
    func ownedNames(includeJournals: Bool = false) throws -> [String] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BackupError.storage("Vane's data folder is not a regular directory.")
        }
        var names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { includeJournals ? BackupPaths.isOriginal($0) : BackupPaths.isOwned($0) }
        let lists = directory.appendingPathComponent("FilterLists")
        if FileManager.default.fileExists(atPath: lists.path) {
            let values = try lists.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw BackupError.storage("FilterLists is not a regular directory.") }
            names += try FileManager.default.contentsOfDirectory(atPath: lists.path)
                .map { "FilterLists/" + $0 }.filter(BackupPaths.isOwned)
        }
        names += try ReadingQueueFiles.ownedNames(in: directory)
        return names.sorted()
    }
    func capture(reason: BackupReason, allowDamaged: Bool = false) throws -> BackupArchive {
        let names = try ownedNames()
        // Even a read-only SQLite connection can rebuild its shared-memory file.
        // Preserve raw companions before attempting any snapshot of damaged data.
        var originals: [BackupArchive.File] = []
        if allowDamaged {
            var budget = BackupCodec.limit
            for name in try ownedNames(includeJournals: true) {
                let data = try BackupIO.read(directory.appendingPathComponent(name))
                guard data.count <= budget else { throw BackupError.tooLarge }
                budget -= data.count
                originals.append(.init(name: name, data: data))
            }
        }
        var files: [BackupArchive.File] = [], damage: [String] = []
        var remaining = BackupCodec.limit
        for name in names {
            let url = directory.appendingPathComponent(name)
            let data: Data
            if name.hasSuffix(".db") {
                do { data = try BackupSQLite.snapshot(at: url) }
                catch {
                    guard allowDamaged else { throw error }
                    data = try BackupIO.read(url)
                    damage.append("\(name): \(error.localizedDescription)")
                }
            } else { data = try BackupIO.read(url) }
            guard data.count <= remaining else { throw BackupError.tooLarge }
            remaining -= data.count
            files.append(.init(name: name, data: data))
        }
        let preferences = try currentPreferences()
        guard preferences.count <= remaining else { throw BackupError.tooLarge }
        var archive = BackupArchive(preferences: preferences, files: files, reason: reason)
        do { _ = try validate(archive) }
        catch {
            guard allowDamaged else { throw error }
            damage.append(error.localizedDescription)
        }
        if !damage.isEmpty {
            // A damaged point is evidence rather than an installable snapshot.
            // Keep exact database bytes and journals after transaction cleanup.
            guard BackupCodec.withinLimit([preferences.count] + originals.map { $0.data.count }) else { throw BackupError.tooLarge }
            archive.files = originals
            archive.damage = damage.joined(separator: "\n")
        }
        return archive
    }
    func validate(_ archive: BackupArchive) throws -> BackupPreview {
        try BackupCodec.validate(archive)
        if let damage = archive.damage { throw BackupError.invalid("This recovery point contains damaged originals. \(damage)") }
        let files = Dictionary(uniqueKeysWithValues: archive.files.map { ($0.name, $0.data) })
        guard let profileData = files["profiles.json"] else { throw BackupError.invalid("The profile list is missing.") }
        let disk = try decode(Profiles.self, profileData, "profiles.json")
        let ids = Set(disk.profiles.map(\.id))
        guard !disk.profiles.isEmpty, disk.profiles.count <= 1000, ids.count == disk.profiles.count,
              !ids.contains(Profile.incognito.id), ids.contains(disk.activeID) else { throw BackupError.invalid("Invalid profile identities.") }
        let allowed = disk.profiles.reduce(into: Set(["profiles.json"])) { $0.formUnion(BackupPaths.names(for: $1.id)) }
        guard files.keys.allSatisfy({ allowed.contains($0) || $0.hasPrefix("FilterLists/") || ReadingQueueFiles.parseOwnedName($0).map { ids.contains($0.profileID) } == true }) else {
            throw BackupError.invalid("A saved file belongs to an unknown profile.")
        }
        guard let preferences = try PropertyListSerialization.propertyList(from: archive.preferences, format: nil) as? [String: Any] else {
            throw BackupError.invalid("Invalid preferences.")
        }
        guard !preferences.keys.contains(where: Self.isLocalPreference) else { throw BackupError.invalid("Local startup metadata cannot be restored.") }
        let imported = preferences["blockerImportedLists"] as? [String] ?? []
        for name in imported {
            guard BackupPaths.isOwned("FilterLists/" + name), let data = files["FilterLists/" + name],
                  String(data: data, encoding: .utf8) != nil else { throw BackupError.invalid("An imported blocking list is missing or invalid.") }
        }
        for (name, data) in files where name.hasPrefix("FilterLists/") {
            guard String(data: data, encoding: .utf8) != nil else { throw BackupError.invalid("Invalid blocking list: \(name).") }
        }
        var summaries: [BackupPreview.ProfileSummary] = []
        let queueCounts = try ReadingQueueFiles.validateBackup(files: files, profileIDs: ids)
        var allSpaces = Set<UUID>(), allBoards = Set<UUID>()
        for profile in disk.profiles {
            let suffix = ProfileManager.suffix(profile.id)
            // Boosts live inside preferences rather than a standalone profile file.
            // Reject unreadable records before replacing a healthy library; the runtime
            // otherwise falls back to empty Boosts and hides the damaged saved data.
            if let value = preferences[SiteBoostStore.key(profile.id)] {
                guard let data = value as? Data,
                      let records = try? JSONDecoder().decode([String: SiteBoost].self, from: data),
                      records.keys.allSatisfy({ URL(string: $0).flatMap(SiteBoosts.origin) == $0 }) else {
                    throw BackupError.invalid("Invalid saved site Boosts for \(profile.name).")
                }
            }
            if let data = files["space-templates\(suffix).json"] {
                do { _ = try WorkspaceTemplates.validate(data, profile: profile.id) }
                catch { throw BackupError.invalid("Invalid or unsupported Space templates.") }
            }
            let spaces = try files["spaces\(suffix).json"].map { try decode([Space].self, $0, "Spaces") } ?? []
            guard spaces.allSatisfy({ $0.profileID == profile.id && allSpaces.insert($0.id).inserted }) else {
                throw BackupError.invalid("Duplicate Spaces or cross-profile Space ownership.")
            }
            let boards: [EaselBoard]
            if let data = files["easels-\(profile.id.uuidString).json"] {
                guard data.count <= EaselStore.fileLimit else { throw BackupError.tooLarge }
                let easels = try decode(EaselStore.Archive.self, data, "Easels")
                guard easels.version == 1, easels.boards.count <= 200 else { throw BackupError.invalid("Unsupported Easels.") }
                for board in easels.boards {
                    guard allBoards.insert(board.id).inserted else { throw BackupError.invalid("Duplicate Easel identity.") }
                    try EaselStore.validate(board)
                }
                boards = easels.boards
            } else { boards = [] }
            let boardIDs = Set(boards.map(\.id))
            for space in spaces {
                for url in space.tabURLs + space.pinnedURLs + (space.pinnedTabURLs ?? []) { try validateURL(url, boards: boardIDs) }
                if let layout = space.layout {
                    do { try layout.validate() }
                    catch { throw BackupError.invalid("Invalid Space layout.") }
                    guard layout.matches(space) else { throw BackupError.invalid("The Space layout does not match its saved tabs.") }
                    for page in layout.tabs {
                        try validateURL(page.url, boards: boardIDs)
                        if let home = page.home { try validateURL(home, boards: boardIDs) }
                    }
                }
            }
            if let data = files["spacestate\(suffix).json"] {
                let sidecar = try decode([String: [String: StateRow]].self, data, "Space state")
                // Old cache rows may refer to deleted Spaces; preserve them without
                // treating them as live tabs. Reject malformed state, not stale cache IDs.
                for (space, rows) in sidecar {
                    guard UUID(uuidString: space) != nil else { throw BackupError.invalid("Invalid Space state identity.") }
                    for (url, row) in rows {
                        try validateURLString(url, boards: nil)
                        if let state = row.s, Data(base64Encoded: state) == nil { throw BackupError.invalid("Invalid tab state.") }
                        if let page = row.u { try validateURLString(page, boards: nil) }
                    }
                }
            }
            var sessions: [[Session.Entry]] = [], sessionSpaces: [UUID?] = []
            if let data = files["session\(suffix).json"] {
                let summary = try Session.validateBackup(data)
                sessions = summary.windows; sessionSpaces = summary.spaces
                for id in sessionSpaces.compactMap({ $0 }) where !spaces.contains(where: { $0.id == id }) {
                    throw BackupError.invalid("A saved window belongs to an unknown Space.")
                }
                for entry in sessions.flatMap({ $0 }) {
                    try validateURLString(entry.url, boards: boardIDs)
                    if let home = entry.home { try validateURLString(home, boards: boardIDs) }
                    if let state = entry.state, Data(base64Encoded: state) == nil { throw BackupError.invalid("Invalid session state.") }
                }
            }
            let favouriteKey = TabStore.defaultsKey(.favourite, profile.id)
            guard preferences[favouriteKey] == nil || preferences[favouriteKey] is [String] else {
                throw BackupError.invalid("Invalid favourite tabs.")
            }
            let favourites = preferences[favouriteKey] as? [String] ?? []
            for url in favourites { try validateURLString(url, boards: boardIDs) }
            let databaseCounts = try files["vane\(suffix).db"].map(BackupSQLite.counts)
            summaries.append(.init(id: profile.id, name: profile.name, spaces: spaces.count,
                                   tabs: tabCount(spaces: spaces, sessions: sessions, windowSpaces: sessionSpaces, favourites: favourites),
                                   bookmarks: databaseCounts?.bookmarks ?? 0, history: databaseCounts?.history ?? 0, easels: boards.count, readingQueue: queueCounts[profile.id] ?? 0))
        }
        let external = preferences.keys.contains { $0.hasPrefix("extensionPaths") || $0.hasPrefix("downloadFolder") || $0 == "blockerLists" }
        return BackupPreview(profiles: summaries, settings: preferences.count, hasExternalFolders: external)
    }
    private struct StateRow: Decodable { var t: String?; var s: String?; var u: String? }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ label: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw BackupError.invalid("\(label) contains invalid saved data.") }
    }
    private func validateURLString(_ string: String, boards: Set<UUID>?) throws {
        guard let url = URL(string: string) else { throw BackupError.invalid("Invalid saved tab address.") }
        try validateURL(url, boards: boards)
    }
    private func validateURL(_ url: URL, boards: Set<UUID>?) throws {
        if let id = EaselAddress.boardID(url) {
            if let boards, !boards.contains(id) { throw BackupError.invalid("A tab references a missing Easel.") }
        } else {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
                throw BackupError.invalid("Unsupported saved tab address.")
            }
        }
    }
    private func tabCount(spaces: [Space], sessions: [[Session.Entry]], windowSpaces: [UUID?], favourites: [String]) -> Int {
        // Multisets preserve deliberate duplicate tabs; max avoids counting both the
        // Space list and its session representation. Shared window IDs count once.
        var grid = Set(favourites)
        var bySpace: [String: [String: Int]] = [:]
        for space in spaces {
            var rows: [String: Int] = [:]
            grid.formUnion(space.pinnedURLs.map(\.absoluteString))
            for (kind, urls) in [(TabKind.today, space.tabURLs), (.pinned, space.pinnedTabURLs ?? [])] {
                for url in urls { rows["\(kind.rawValue):\(url.absoluteString)", default: 0] += 1 }
            }
            bySpace[space.id.uuidString] = rows
        }
        var seen = Set<String>(), sessionRows: [String: [String: Int]] = [:]
        for (index, entries) in sessions.enumerated() {
            let space = windowSpaces.indices.contains(index) ? windowSpaces[index]?.uuidString : nil
            let key = space ?? "window-\(index)"
            for entry in entries {
                if let id = entry.id, !seen.insert(id).inserted { continue }
                if entry.kind == .favourite {
                    grid.insert(entry.home ?? entry.url)
                    continue
                }
                let address = entry.kind == .today ? entry.url : (entry.home ?? entry.url)
                sessionRows[key, default: [:]]["\((entry.kind ?? .today).rawValue):\(address)", default: 0] += 1
            }
        }
        for (space, rows) in sessionRows {
            for (url, count) in rows { bySpace[space, default: [:]][url] = max(bySpace[space]?[url] ?? 0, count) }
        }
        return bySpace.values.reduce(grid.count) { $0 + $1.values.reduce(0, +) }
    }
}
