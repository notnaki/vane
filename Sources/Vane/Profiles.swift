import Foundation
import WebKit

/// One isolated set of browsing data: its own cookie/website data store, its own
/// history+bookmarks database, its own keychain items, favicons, pins, session, extensions
/// and spaces.
struct Profile: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String = "#6E7DD2") {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    /// The profile that owns everything Vane wrote before profiles existed. See
    /// `ProfileManager.suffix` — this is the whole of the migration.
    var isDefault: Bool { id == ProfileManager.defaultID }
}

/// A named, ordered group of tabs inside exactly one profile. One profile has many spaces;
/// a space never belongs to two profiles, which is why `profileID` is the only link and why
/// spaces are stored in a per-profile file rather than one global list.
struct Space: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var profileID: UUID
    var tabURLs: [URL]
    var pinnedURLs: [URL]

    init(id: UUID = UUID(), name: String, profileID: UUID,
         tabURLs: [URL] = [], pinnedURLs: [URL] = []) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.tabURLs = tabURLs
        self.pinnedURLs = pinnedURLs
    }
}

/// The profile list, the selection, and every per-profile path.
///
/// ponytail: a JSON file and a fixed UUID for the default profile, instead of a migration
/// step that moves files around. Because the default profile's file names are the *old*
/// names (`vane.db`, `session.json`, `favicons/`, the `pinnedTabs` default, keychain items
/// with no security domain, `WKWebsiteDataStore.default()`), an existing installation is
/// already inside its default profile on first launch — nothing is copied and nothing can
/// be half-copied. Ceiling: the default profile can never be renamed *on disk*, so its
/// files stay called `vane.db` forever. That is a cosmetic ceiling, not a functional one.
@MainActor final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    /// `000056616E65` is 'Vane' in ASCII. Fixed, because it is what makes the pre-profiles
    /// data land in the default profile rather than being orphaned.
    nonisolated static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000056616E65")!

    /// Where profiles.json and every per-profile file lives. Injectable so `check()` can run
    /// against a temp directory instead of the user's real Application Support folder.
    let directory: URL
    /// A sandboxed manager touches only files under `directory` — never the keychain, the
    /// shared caches, UserDefaults or WebKit's data stores. `check()` uses one.
    let sandboxed: Bool

    @Published private(set) var profiles: [Profile] = []
    @Published private var activeID: UUID = ProfileManager.defaultID

    /// The profile everything unqualified resolves to. Falls back to the first profile, so
    /// a stale or deleted selection can never leave the app with no profile at all.
    var active: Profile {
        get { profiles.first { $0.id == activeID } ?? profiles[0] }
        set {
            guard profiles.contains(where: { $0.id == newValue.id }) else { return }
            activeID = newValue.id
            persist()
        }
    }

    /// The active profile, readable from nonisolated code so it can be a default argument —
    /// `Passwords` and the CSV importer are plain enums, and making them @MainActor would
    /// infect Import.swift, which is not this file's to change.
    /// ponytail: every call site is on the main thread; off it there is no safe way to read
    /// the manager at all, so the default profile is the only honest answer.
    nonisolated static var activeProfileID: UUID {
        Thread.isMainThread ? MainActor.assumeIsolated { shared.active.id } : defaultID
    }

    private struct Disk: Codable {
        var profiles: [Profile]
        var activeID: UUID
    }

    init(directory: URL = Store.directory, sandboxed: Bool = false) {
        self.directory = directory
        self.sandboxed = sandboxed
        let file = directory.appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: file),
           let disk = try? JSONDecoder().decode(Disk.self, from: data),
           !disk.profiles.isEmpty {
            profiles = disk.profiles
            activeID = disk.profiles.contains { $0.id == disk.activeID } ? disk.activeID : disk.profiles[0].id
        } else {
            profiles = [Profile(id: Self.defaultID, name: "Personal", colorHex: Self.palette[0])]
            activeID = Self.defaultID
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Disk(profiles: profiles, activeID: activeID)) else { return }
        try? data.write(to: directory.appendingPathComponent("profiles.json"))
    }

    // MARK: CRUD

    static let palette = ["#6E7DD2", "#D2795E", "#4FA07A", "#B45FA8", "#C7A03E", "#5AA3C7"]

    @discardableResult
    func create(name: String, colorHex: String? = nil) -> Profile {
        let p = Profile(name: name, colorHex: colorHex ?? Self.palette[profiles.count % Self.palette.count])
        profiles.append(p)
        persist()
        return p
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        profiles[i].name = name
        persist()
    }

    /// Deletes the profile and everything that belongs to it. Refuses to delete the last
    /// one — a browser with no profile has nowhere to put a tab.
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles.remove(at: i)
        if activeID == id { activeID = profiles[0].id }
        persist()

        if !sandboxed {
            // Close the sqlite connection and drop the cached objects before the files go.
            Store.forget(id)
            Favicons.forget(id)
            ExtensionHost.forget(id)
            Passwords.deleteAll(profileID: id)
            for key in ["pinnedTabs", "blockerEnabled", ExtensionHost.baseKey] {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey(key, id))
            }
            if id != Self.defaultID {
                Self.dataStores[id] = nil
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
            }
        }

        let fm = FileManager.default
        let db = Self.dbURL(for: id, in: directory).path
        for path in [db, db + "-wal", db + "-shm"] { try? fm.removeItem(atPath: path) }
        try? fm.removeItem(at: Self.sessionURL(for: id, in: directory))
        try? fm.removeItem(at: Self.spacesURL(for: id, in: directory))
        try? fm.removeItem(at: Self.faviconDir(for: id, in: directory))
        return true
    }

    // MARK: Paths
    //
    // Every per-profile name is "the old name + suffix", and the default profile's suffix is
    // empty. That single rule is what makes an upgrade a no-op.

    nonisolated static func suffix(_ id: UUID) -> String {
        id == defaultID ? "" : "-" + id.uuidString.lowercased()
    }

    nonisolated static func dbURL(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("vane\(suffix(id)).db")
    }

    nonisolated static func sessionURL(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("session\(suffix(id)).json")
    }

    nonisolated static func spacesURL(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("spaces\(suffix(id)).json")
    }

    nonisolated static func faviconDir(for id: UUID, in dir: URL) -> URL {
        dir.appendingPathComponent("favicons\(suffix(id))", isDirectory: true)
    }

    nonisolated static func defaultsKey(_ base: String, _ id: UUID) -> String { base + suffix(id) }

    // MARK: Website data store

    private static var dataStores: [UUID: WKWebsiteDataStore] = [:]

    /// The real multi-store API. The default profile keeps `.default()` so existing cookies
    /// and logins survive; every other profile gets its own persistent store. Private
    /// windows never come through here — they use `.nonPersistent()`.
    static func dataStore(for id: UUID) -> WKWebsiteDataStore {
        guard id != defaultID else { return .default() }
        if let existing = dataStores[id] { return existing }
        // WebKit wants one instance per identifier for the life of the process.
        let store = WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    // MARK: Spaces

    /// Read filters on `profileID` as well as reading the profile's own file, so a space can
    /// never surface under a profile that does not own it even if the file is edited by hand.
    func spaces(for profileID: UUID) -> [Space] {
        guard let data = try? Data(contentsOf: Self.spacesURL(for: profileID, in: directory)),
              let all = try? JSONDecoder().decode([Space].self, from: data) else { return [] }
        return all.filter { $0.profileID == profileID }
    }

    func saveSpaces(_ spaces: [Space], for profileID: UUID) {
        let owned = spaces.filter { $0.profileID == profileID }
        guard let data = try? JSONEncoder().encode(owned) else { return }
        try? data.write(to: Self.spacesURL(for: profileID, in: directory))
    }

    @discardableResult
    func createSpace(name: String, in profileID: UUID) -> Space {
        let space = Space(name: name, profileID: profileID)
        saveSpaces(spaces(for: profileID) + [space], for: profileID)
        return space
    }

    /// Insert-or-replace, into the file of the profile the space says it belongs to.
    func updateSpace(_ space: Space) {
        var all = spaces(for: space.profileID)
        if let i = all.firstIndex(where: { $0.id == space.id }) { all[i] = space } else { all.append(space) }
        saveSpaces(all, for: space.profileID)
    }

    func deleteSpace(_ id: UUID, in profileID: UUID) {
        saveSpaces(spaces(for: profileID).filter { $0.id != id }, for: profileID)
    }

    // MARK: Offline check

    /// Everything here runs against a throwaway temp directory with a sandboxed manager, so
    /// no keychain, no WebKit, no UserDefaults and never the real Application Support folder.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vane-profiles-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Pre-existing, pre-profiles data sitting in the directory before any profile exists.
        let legacyDB = root.appendingPathComponent("vane.db")
        try? Data("legacy".utf8).write(to: legacyDB)

        let pm = ProfileManager(directory: root, sandboxed: true)
        assert("first launch creates exactly one profile", pm.profiles.count == 1)
        assert("that profile is the fixed default id", pm.profiles[0].id == defaultID)
        assert("the default profile's database is the pre-existing vane.db",
               dbURL(for: defaultID, in: root) == legacyDB)
        assert("pre-existing data is adopted, not orphaned or overwritten",
               (try? Data(contentsOf: legacyDB)).map { String(decoding: $0, as: UTF8.self) } == "legacy")
        assert("the default profile keeps the pre-profiles file names",
               sessionURL(for: defaultID, in: root).lastPathComponent == "session.json"
               && faviconDir(for: defaultID, in: root).lastPathComponent == "favicons"
               && defaultsKey("pinnedTabs", defaultID) == "pinnedTabs")

        let work = pm.create(name: "Work")
        assert("create adds a profile", pm.profiles.count == 2)
        assert("a created profile keeps the name it was given",
               pm.profiles.last?.name == "Work" && !work.isDefault)
        assert("per-profile store paths are distinct",
               Set(pm.profiles.map { dbURL(for: $0.id, in: root).path }).count == 2)
        assert("a non-default profile does not reuse the legacy names",
               dbURL(for: work.id, in: root) != legacyDB
               && sessionURL(for: work.id, in: root).lastPathComponent != "session.json"
               && defaultsKey("pinnedTabs", work.id) != "pinnedTabs")

        pm.rename(work.id, to: "School")
        assert("rename sticks", pm.profiles.first { $0.id == work.id }?.name == "School")
        pm.active = work
        assert("active follows the selection", pm.active.id == work.id)

        let reloaded = ProfileManager(directory: root, sandboxed: true)
        assert("profiles round-trip through disk",
               reloaded.profiles.count == 2 && reloaded.profiles.contains { $0.name == "School" })
        assert("the active selection round-trips", reloaded.active.id == work.id)

        // Spaces belong to exactly one profile.
        let reading = pm.createSpace(name: "Reading", in: work.id)
        pm.createSpace(name: "Inbox", in: defaultID)
        assert("a new space belongs to the profile it was made in", reading.profileID == work.id)
        assert("spaces list under their own profile", pm.spaces(for: work.id).map(\.name) == ["Reading"])
        assert("a space never shows up under another profile",
               pm.spaces(for: defaultID).map(\.name) == ["Inbox"])
        assert("every space's profileID resolves to a live profile",
               (pm.spaces(for: work.id) + pm.spaces(for: defaultID))
                   .allSatisfy { s in pm.profiles.contains { $0.id == s.profileID } })
        var edited = reading
        edited.tabURLs = [URL(string: "https://example.com/a")!]
        edited.pinnedURLs = [URL(string: "https://example.com/p")!]
        pm.updateSpace(edited)
        assert("space contents round-trip",
               pm.spaces(for: work.id).first?.tabURLs.first?.absoluteString == "https://example.com/a"
               && pm.spaces(for: work.id).first?.pinnedURLs.count == 1)
        assert("updating a space replaces it instead of duplicating it",
               pm.spaces(for: work.id).count == 1)
        pm.deleteSpace(reading.id, in: work.id)
        assert("a deleted space is gone", pm.spaces(for: work.id).isEmpty)
        pm.updateSpace(edited)

        // A profile's files must actually be on disk before deletion can prove anything.
        try? Data("work".utf8).write(to: dbURL(for: work.id, in: root))
        try? Data("[]".utf8).write(to: sessionURL(for: work.id, in: root))
        assert("deleting a profile succeeds while others remain", pm.delete(work.id))
        assert("deleting a profile removes it from the list",
               pm.profiles.count == 1 && pm.profiles[0].id == defaultID)
        assert("deleting the active profile moves the selection to a survivor",
               pm.active.id == defaultID)
        assert("deleting a profile deletes its database and session",
               !fm.fileExists(atPath: dbURL(for: work.id, in: root).path)
               && !fm.fileExists(atPath: sessionURL(for: work.id, in: root).path))
        assert("deleting a profile removes its spaces",
               pm.spaces(for: work.id).isEmpty
               && !fm.fileExists(atPath: spacesURL(for: work.id, in: root).path))
        assert("the surviving profile's spaces are untouched",
               pm.spaces(for: defaultID).map(\.name) == ["Inbox"])
        assert("deleting a profile leaves the other profile's data alone",
               fm.fileExists(atPath: legacyDB.path))

        assert("the last remaining profile cannot be deleted", pm.delete(defaultID) == false)
        assert("...and is still there", pm.profiles.count == 1)
        assert("deleting a profile that does not exist is refused",
               pm.delete(UUID()) == false)

        return out
    }
}
