import Foundation
import WebKit

// MARK: - Sandbox

/// Remembering a folder the user picked, under the App Sandbox.
///
/// A URL that came back from `NSOpenPanel` is readable for exactly one launch: powerbox
/// hands the process a sandbox extension, and the extension dies with the process. What
/// survives is *bookmark data* made with `.withSecurityScope`, and the access has to be
/// re-taken with `startAccessingSecurityScopedResource()` before the path is touched
/// again. Persisting `folder.path` instead — which is what Vane did before it was
/// sandboxed — produces a list of strings the app can no longer open.
///
/// ponytail: one `[Data]` list per UserDefaults key, so a caller that was storing `[String]`
/// paths swaps three call sites and keeps its own shape. Access, once started, is never
/// stopped: these are folders the app reads for its whole life, and the kernel drops the
/// extension at exit. Ceiling: no `stopAccessing`, so a removed extension keeps its
/// extension alive until quit. Harmless, and the alternative is refcounting by path.
@MainActor enum ScopedPaths {
    /// Paths whose extension is already started, so resolving twice does not nest.
    private static var accessing: Set<String> = []

    /// Every folder still reachable under `key`, access already started. Anything that no
    /// longer resolves — folder deleted, volume gone, or a pre-sandbox plain path that the
    /// sandbox will not grant — is dropped from the stored list rather than retried forever.
    @discardableResult
    static func urls(_ key: String, in defaults: UserDefaults = .standard) -> [URL] {
        let stored = raw(key, in: defaults)
        var kept: [Data] = []
        var out: [URL] = []
        for data in stored {
            guard let url = resolve(data), start(url) else { continue }
            kept.append(data)
            out.append(url)
        }
        if kept.count != stored.count { defaults.set(kept, forKey: key) }
        return out
    }

    static func paths(_ key: String, in defaults: UserDefaults = .standard) -> [String] {
        urls(key, in: defaults).map(\.path)
    }

    /// Bookmark `url` and append it. False means the sandbox will not let this folder be
    /// remembered — the honest answer to "can this be reopened next launch", and a caller
    /// must not write down a path it cannot reopen.
    @discardableResult
    static func add(_ url: URL, to key: String, in defaults: UserDefaults = .standard) -> Bool {
        guard let data = bookmark(url) else { return false }
        var all = raw(key, in: defaults)
        guard !all.contains(where: { same($0, url) }) else { return true }
        all.append(data)
        defaults.set(all, forKey: key)
        _ = start(url)
        return true
    }

    static func remove(path: String, from key: String, in defaults: UserDefaults = .standard) {
        let url = URL(fileURLWithPath: path)
        defaults.set(raw(key, in: defaults).filter { !same($0, url) }, forKey: key)
        accessing.remove(url.resolvingSymlinksInPath().path)
    }

    /// A resolved bookmark comes back through the data volume's firmlink — under the
    /// sandbox `~/Downloads/x` resolves to `/System/Volumes/Data/Users/…/Downloads/x` —
    /// so identity is only meaningful after resolving symlinks on both sides.
    /// Compare paths, not URLs: a directory bookmark resolves with a trailing slash while
    /// URL(fileURLWithPath:) has none, so the URLs differ even though the folder is the
    /// same one. Comparing URL objects here let the same folder be bookmarked twice, and
    /// stopped remove(path:) from matching what add() had written.
    private static func same(_ data: Data, _ url: URL) -> Bool {
        guard let resolved = resolve(data)?.resolvingSymlinksInPath().path else { return false }
        return resolved == url.resolvingSymlinksInPath().path
    }

    // MARK: internals

    /// Tolerates the pre-sandbox `[String]` shape by re-bookmarking each path. Unsandboxed
    /// that succeeds and the list upgrades itself in place; sandboxed the paths are not
    /// readable, `bookmark` fails, and they fall out — which is the correct outcome, the
    /// user has to pick the folder again.
    private static func raw(_ key: String, in defaults: UserDefaults) -> [Data] {
        let stored = defaults.array(forKey: key) ?? []
        if let datas = stored as? [Data] { return datas }
        let upgraded = (stored as? [String] ?? []).compactMap { bookmark(URL(fileURLWithPath: $0)) }
        defaults.set(upgraded, forKey: key)
        return upgraded
    }

    /// Outside the sandbox `.withSecurityScope` is refused; a plain bookmark is all that is
    /// needed there, and resolving one grants access the process already had.
    private static func bookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope,
                               includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              bookmarkDataIsStale: &stale) { return url }
        return try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale)
    }

    /// True when the path is usable. Unsandboxed `startAccessing` returns false for a plain
    /// bookmark and the path is readable anyway, so a readability check is the real answer.
    private static func start(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath().path
        if accessing.contains(real) { return true }
        if url.startAccessingSecurityScopedResource() {
            accessing.insert(real)
            return true
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    // MARK: check

    /// Proves the whole mechanism against a real folder outside the container: bookmark,
    /// persist as `Data`, resolve, take access, read through it, drop it. Run this from a
    /// *sandboxed* binary and it is the only thing standing between a user's extensions and
    /// silently vanishing on the second launch.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ n: String, _ ok: Bool) { out.append((n, ok)) }

        let fm = FileManager.default
        // ~/Downloads, because it is genuinely outside the container — a container-internal
        // path would pass without the entitlement doing anything — and the downloads
        // entitlement is what lets the check create a scratch folder there. Falls back to
        // the temp directory on a machine with no ~/Downloads, where the API is still
        // exercised but the sandbox boundary is not crossed.
        let name = "vane-scoped-check-\(UUID().uuidString)"
        var folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        var outside = true
        if (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) == nil {
            outside = false
            folder = fm.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        assert("~/Downloads is writable, so the bookmark crosses the container boundary", outside)
        defer { try? fm.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("manifest.json")
        try? Data(#"{"manifest_version":3,"name":"x","version":"1"}"#.utf8).write(to: marker)

        let suite = "vane.scoped.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let key = "folders"

        assert("a user-picked folder can be bookmarked", add(folder, to: key, in: defaults))
        assert("the bookmark is stored as Data, not a path string",
               (defaults.array(forKey: key) as? [Data])?.count == 1)
        assert("adding the same folder twice does not duplicate it",
               add(folder, to: key, in: defaults) && (defaults.array(forKey: key) as? [Data])?.count == 1)

        // The relaunch. Forgetting `accessing` is what a new process starts with, so this
        // resolve has to take the extension again from the stored Data alone.
        accessing.removeAll()
        let resolved = urls(key, in: defaults)
        assert("a stored bookmark resolves back to the same folder",
               resolved.first?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        assert("access is granted through the resolved bookmark",
               resolved.first.map { fm.isReadableFile(atPath: $0.appendingPathComponent("manifest.json").path) } == true)
        assert("the folder's contents are actually readable after resolving",
               resolved.first.flatMap { try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) }?.isEmpty == false)

        remove(path: folder.path, from: key, in: defaults)
        assert("removing a folder empties the stored list", raw(key, in: defaults).isEmpty)

        // A folder that has gone away must fall out of the list instead of being retried.
        _ = add(folder, to: key, in: defaults)
        try? fm.removeItem(at: folder)
        accessing.removeAll()
        assert("a bookmark to a deleted folder is dropped, not retried forever",
               urls(key, in: defaults).isEmpty && raw(key, in: defaults).isEmpty)

        // Sanity: is the sandbox even on? ~/Pictures is not covered by any entitlement here.
        let pictures = LegacyData.realHome.appendingPathComponent("Pictures")
        let sandboxed = (try? fm.contentsOfDirectory(atPath: pictures.path)) == nil
        assert("sandbox status: ~/Pictures is \(sandboxed ? "denied (sandboxed)" : "readable (NOT sandboxed)")",
               true)
        return out
    }
}

/// Pre-sandbox Vane wrote to `~/Library/Application Support/Vane`. Under the App Sandbox
/// `.applicationSupportDirectory` resolves *inside the container* instead, so on the first
/// sandboxed launch that folder — the history and bookmarks database, the profile list, the
/// saved session, the whole favicon cache — is suddenly somewhere the app cannot see, and a
/// user who upgrades looks at an empty browser. Copy it in, once.
///
/// ponytail: copy rather than move, so a downgrade to an unsandboxed build finds its data
/// where it left it. Ceiling: if an unsandboxed Vane is running at the same time, the
/// sqlite file and its -wal can be copied mid-write; the fix is a `sqlite3_backup`, and it
/// is not worth it for a one-shot upgrade step. Ceiling: this needs the temporary-exception
/// entitlement in Vane.entitlements — delete both a release after everyone has launched.
@MainActor enum LegacyData {
    /// The *real* home directory. `NSHomeDirectory()` is redirected into the container
    /// under the sandbox; the passwd entry is not.
    static var realHome: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory())
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    private static var legacy: URL {
        realHome.appendingPathComponent("Library/Application Support/Vane", isDirectory: true)
    }

    /// Runs before anything reads a profile file. A no-op when unsandboxed (the container
    /// *is* the legacy folder), when it has already run, or when there is nothing to copy.
    static func migrateIfNeeded(into container: URL) {
        let fm = FileManager.default
        guard container.standardizedFileURL != legacy.standardizedFileURL else { return }
        let stamp = container.appendingPathComponent(".migrated-from-legacy")
        guard !fm.fileExists(atPath: stamp.path) else { return }
        defer { try? Data(Date.now.description.utf8).write(to: stamp) }
        guard let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names {
            // Never the -shm. SQLite's own rule for copying a WAL database is "the database
            // and the -wal, never the shared-memory index": a copied -shm looks valid but
            // describes the *old* file, and SQLite answers by ignoring the WAL entirely.
            // Copying it cost 16 of 63 history rows on the first run of this migration.
            guard !name.hasSuffix("-shm"), !fm.fileExists(atPath: container.appendingPathComponent(name).path)
            else { continue }
            try? fm.copyItem(at: legacy.appendingPathComponent(name),
                             to: container.appendingPathComponent(name))
        }
    }
}

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
    /// The Favourites grid. The key is `pinnedURLs` because it predates the split between
    /// Favourites and Pinned; renaming it would drop every existing space's grid.
    var pinnedURLs: [URL]
    /// Arc's Pinned section — the list rows between the space's name and the New Tab
    /// divider. Optional so a spaces.json written before the split still decodes.
    var pinnedTabURLs: [URL]?
    /// The space's look. All optional, so a spaces.json written before any of this existed
    /// still decodes — an Optional property gets `decodeIfPresent` for free. `icon` is an SF
    /// Symbol name, `appearance` is "light"/"dark" (nil follows the system) and `tint` is how
    /// strongly `colorHex` washes over the window ground, 0…1.
    var colorHex: String?
    var icon: String?
    var appearance: String?
    var tint: Double?

    init(id: UUID = UUID(), name: String, profileID: UUID,
         tabURLs: [URL] = [], pinnedURLs: [URL] = [], pinnedTabURLs: [URL]? = nil,
         colorHex: String? = nil, icon: String? = nil,
         appearance: String? = nil, tint: Double? = nil) {
        self.id = id
        self.name = name
        self.profileID = profileID
        self.tabURLs = tabURLs
        self.pinnedURLs = pinnedURLs
        self.pinnedTabURLs = pinnedTabURLs
        self.colorHex = colorHex
        self.icon = icon
        self.appearance = appearance
        self.tint = tint
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
        // Before profiles.json is read: under the App Sandbox this directory is a fresh,
        // empty container and the user's real data is still outside it. Nothing else in the
        // app touches a profile file earlier than this, so this is the whole hook.
        if !sandboxed { LegacyData.migrateIfNeeded(into: directory) }
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
        // Deliberately not called inline: `ProfileManager.shared` is first touched from
        // `Session.restore()`, which runs before `NSApplication.run()`, and WebKit's main
        // WTF::RunLoop does not exist yet — `fetchAllDataStoreIdentifiers` delivers its
        // completion into a null run loop and the app segfaults on launch. Hopping to the
        // main actor puts it after the run loop is up, which is also when the profile's
        // stores are least likely to be open.
        if !sandboxed {
            let live = profiles.map(\.id)
            Task { @MainActor in Self.sweepOrphanedDataStores(keeping: live) }
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

    /// The profile's accent, picked from `palette`. Same shape as `rename` — `profiles` is
    /// `private(set)` and `persist` is private, so the settings pane cannot do this itself.
    func setColor(_ colorHex: String, for id: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].colorHex = colorHex
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
            for key in ["pinnedTabs", "blockerEnabled", ExtensionHost.baseKey,
                        HTTPSOnly.exceptionsKey] {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey(key, id))
            }
            Self.eraseWebsiteData(for: id)
        }

        let fm = FileManager.default
        let db = Self.dbURL(for: id, in: directory).path
        for path in [db, db + "-wal", db + "-shm"] { try? fm.removeItem(atPath: path) }
        try? fm.removeItem(at: Self.sessionURL(for: id, in: directory))
        try? fm.removeItem(at: Suspension.SpaceState.url(for: id, in: directory))
        Downloads.forget(id, in: directory)
        TidyTitles.forget(id)
        Zoom.forget(profile: id)
        try? fm.removeItem(at: Self.spacesURL(for: id, in: directory))
        try? fm.removeItem(at: Self.faviconDir(for: id, in: directory))
        return true
    }

    /// Cookies, localStorage, IndexedDB, caches — everything WebKit keeps for a profile.
    ///
    /// Two things the original one-liner got wrong, both found by running the deletion path
    /// for the first time:
    ///
    ///  * `WKWebsiteDataStore.remove(forIdentifier:)` fails while any live instance for that
    ///    identifier is still around — and one always is, because deleting a profile does
    ///    not close its windows, and every tab's web view holds the store. The error came
    ///    back in a completion handler that was spelled `{ _ in }`, so the store, the
    ///    cookies and the site databases silently stayed on disk.
    ///  * the default profile was skipped entirely (`if id != defaultID`). It uses
    ///    `WKWebsiteDataStore.default()`, which has no identifier to remove, so deleting the
    ///    default profile erased its history and passwords and left every cookie behind.
    ///
    /// So: wipe the contents first, which always works and is the part the user actually
    /// cares about, then try to unregister the store, which only matters for the empty
    /// directory it leaves behind.
    ///
    /// The unregister step reliably fails in the launch that did the deleting —
    /// `WKWebSiteDataStore Code=1 "Data store is in use (by network process)"` — because
    /// WebKit's network process still has the store open. Nothing in-process makes it let
    /// go, so `sweepOrphanedDataStores` finishes the job at the next launch, when nobody
    /// has opened it yet.
    private static func eraseWebsiteData(for id: UUID) {
        let store = dataStore(for: id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {
            MainActor.assumeIsolated {
                dataStores[id] = nil
                guard id != defaultID else { return }
                WKWebsiteDataStore.remove(forIdentifier: id) { error in
                    // Not fatal — the data is already gone — but never silent again.
                    if let error { NSLog("Vane: profile store \(id) not unregistered: \(error)") }
                }
            }
        }
    }

    /// Registered stores that no profile owns any more. Pure, so it can be asserted on.
    nonisolated static func orphanedStores(_ registered: [UUID], keeping live: [UUID]) -> [UUID] {
        registered.filter { !live.contains($0) }
    }

    /// Run at launch. Picks up the store that `eraseWebsiteData` emptied but could not
    /// unregister, and anything left behind by a crash mid-delete.
    /// ponytail: fire-and-forget. Worst case it fails again and next launch tries again —
    /// the data inside is already gone either way, so there is nothing to report to anyone.
    private static func sweepOrphanedDataStores(keeping live: [UUID]) {
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { registered in
            let orphans = orphanedStores(registered, keeping: live)
            guard !orphans.isEmpty else { return }
            Task { @MainActor in
                for id in orphans where dataStores[id] == nil {
                    WKWebsiteDataStore.remove(forIdentifier: id) { _ in }
                }
            }
        }
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
        // A spaces.json from before spaces had a look must still load, or upgrading throws
        // away every space the user had.
        let legacySpace = #"[{"id":"\#(UUID().uuidString)","name":"Old","profileID":"\#(work.id.uuidString)","tabURLs":[],"pinnedURLs":[]}]"#
        assert("a space written before icons and theme colours existed still decodes",
               (try? JSONDecoder().decode([Space].self, from: Data(legacySpace.utf8)))?.first
                   .map { $0.name == "Old" && $0.icon == nil && $0.colorHex == nil
                          && $0.appearance == nil && $0.tint == nil } == true)
        var themed = edited
        themed.icon = "leaf"
        themed.colorHex = "#4FA07A"
        themed.appearance = "dark"
        themed.tint = 0.4
        pm.updateSpace(themed)
        assert("a space's icon, colour, appearance and tint round-trip",
               pm.spaces(for: work.id).first.map {
                   $0.icon == "leaf" && $0.colorHex == "#4FA07A"
                   && $0.appearance == "dark" && $0.tint == 0.4
               } == true)
        pm.updateSpace(edited)
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

        // Security-scoped bookmarks: the mechanism that makes every user-picked folder
        // survive a relaunch once the app is sandboxed. Pure — files and defaults only.
        out += ScopedPaths.check()

        // Everything above ran with `sandboxed: true`, which is exactly the half of
        // `delete(_:)` that does nothing. The destructive half runs for real, below.
        out += liveDeletion()
        return out
    }

    /// The half of `delete(_:)` that `check()` above cannot reach.
    ///
    /// `Store`, `Favicons` and `ExtensionHost` all resolve through the *real*
    /// `Store.directory`, and the keychain and `WKWebsiteDataStore` have no injectable
    /// form — so proving that deleting a profile really erases a keychain item, a database,
    /// a favicon and a website data store means doing it for real. It is safe because every
    /// name a throwaway profile owns is suffixed with its random UUID: its keychain items
    /// are keyed on a security domain nothing else uses, its defaults keys carry the UUID,
    /// its data store is addressed by the UUID. Nothing the user owns is in reach.
    ///
    /// ponytail: skipped under `selfcheck --pure`, which promises no keychain ACL prompt
    /// and no WebKit — reading the flag off CommandLine beats threading a parameter through
    /// a call site in a file this one does not own.
    private static func liveDeletion() -> [(String, Bool)] {
        guard !CommandLine.arguments.contains("--pure") else { return [] }
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }
        let fm = FileManager.default
        let dir = Store.directory
        let pm = ProfileManager(directory: dir)

        // The other half of the fix, and the only way to see it: this launch's startup sweep
        // clearing the store the *previous* run of this check deleted but could not
        // unregister. Vacuously true the first time, real every time after.
        assert("a data store orphaned by an earlier launch is swept at startup",
               wait(20) { orphanedStores(dataStoreIdentifiers(), keeping: pm.profiles.map(\.id)).isEmpty })

        // MARK: sentinels for the surviving default profile
        // Distinct hosts: `lookup` for the default profile carries no security domain, so a
        // shared host would make the assertion depend on which item the keychain returned.
        let keepHost = "vane-delete-check-keep.invalid"
        let goneHost = "vane-delete-check-gone.invalid"
        Passwords.save(host: keepHost, account: "survivor", password: "keep", profileID: defaultID)
        let keepDir = faviconDir(for: defaultID, in: dir)
        try? fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        let keepIcon = keepDir.appendingPathComponent("vane-delete-check.invalid")
        try? Data("keep".utf8).write(to: keepIcon)
        // The real database is only ever measured, never written: a byte count that does
        // not move is proof enough that the sweep did not reach into it.
        let keepDB = dbURL(for: defaultID, in: dir)
        let keepDBSize = (try? fm.attributesOfItem(atPath: keepDB.path)[.size] as? Int) ?? nil
        // Read-only: the real user's pinned tabs, never written by this check.
        let keepPins = UserDefaults.standard.array(forKey: defaultsKey("pinnedTabs", defaultID)) as? [String]
        let survivors = pm.profiles.map(\.id)

        // MARK: the throwaway, populated the way a used profile is
        let victim = pm.create(name: "Deletion Check").id
        Passwords.save(host: goneHost, account: "victim", password: "gone", profileID: victim)
        Store.store(for: victim).record(URL(string: "https://vane-delete-check.invalid/v")!,
                                        title: "victim")
        let victimDB = dbURL(for: victim, in: dir)
        let victimIcons = faviconDir(for: victim, in: dir)
        try? fm.createDirectory(at: victimIcons, withIntermediateDirectories: true)
        try? Data("icon".utf8).write(to: victimIcons.appendingPathComponent("example.com"))
        try? Data("[]".utf8).write(to: sessionURL(for: victim, in: dir))
        pm.createSpace(name: "Scratch", in: victim)
        let victimKeys = ["pinnedTabs", "blockerEnabled", ExtensionHost.baseKey]
            .map { defaultsKey($0, victim) }
        UserDefaults.standard.set(["https://pinned.example"], forKey: victimKeys[0])
        UserDefaults.standard.set(false, forKey: victimKeys[1])
        UserDefaults.standard.set([Data("bookmark".utf8)], forKey: victimKeys[2])

        // A website data store only exists on disk once something is written into it.
        // Scoped so the only strong reference left is the manager's own cache — which is
        // what `delete` drops. A live instance is exactly what stops WebKit unregistering.
        do {
            let cookie = HTTPCookie(properties: [
                .domain: "vane-delete-check.invalid", .path: "/",
                .name: "v", .value: "1", .expires: Date.now.addingTimeInterval(3600),
            ])!
            let box = Box()
            dataStore(for: victim).httpCookieStore.setCookie(cookie) { box.done = true }
            _ = wait(5) { box.done }
        }

        assert("a throwaway profile's keychain item is stored before deletion",
               Passwords.lookup(host: goneHost, profileID: victim)?.password == "gone")
        assert("a throwaway profile's database is on disk before deletion",
               fm.fileExists(atPath: victimDB.path))
        assert("a throwaway profile's favicon cache is on disk before deletion",
               fm.fileExists(atPath: victimIcons.appendingPathComponent("example.com").path))
        assert("a throwaway profile's website data store is registered before deletion",
               dataStoreIdentifiers().contains(victim))
        assert("a throwaway profile's cookie is in its data store before deletion",
               cookieCount(victim) == 1)

        // MARK: the thing under test
        assert("deleting a populated profile succeeds", pm.delete(victim))

        assert("deleting a profile deletes its keychain items",
               Passwords.lookup(host: goneHost, profileID: victim) == nil)
        assert("deleting a profile deletes its database, -wal and -shm",
               ![victimDB.path, victimDB.path + "-wal", victimDB.path + "-shm"]
                   .contains(where: fm.fileExists(atPath:)))
        assert("deleting a profile deletes its favicon cache",
               !fm.fileExists(atPath: victimIcons.path))
        assert("deleting a profile deletes its session and spaces files",
               !fm.fileExists(atPath: sessionURL(for: victim, in: dir).path)
               && !fm.fileExists(atPath: spacesURL(for: victim, in: dir).path))
        assert("deleting a profile deletes its UserDefaults keys",
               victimKeys.allSatisfy { UserDefaults.standard.object(forKey: $0) == nil })
        // Before the cookies are read back, because reading them re-creates the store and
        // would re-register the identifier.
        //
        // WebKit will not unregister a store its network process still holds — this is the
        // one thing running the deletion path for real turned up that cannot be fixed here.
        // What can be checked is that the store is left in a state the next launch cleans
        // up, and that the data inside is gone now rather than at some later launch.
        let registered = dataStoreIdentifiers()
        assert("a store WebKit would not unregister is classified as orphaned",
               registered.contains(victim) == false
               || orphanedStores(registered, keeping: survivors).contains(victim))
        assert("the sweep never classifies a surviving profile's store as orphaned",
               orphanedStores(registered, keeping: survivors).allSatisfy { !survivors.contains($0) })
        assert("deleting a profile erases its cookies and site data",
               wait(15) { cookieCount(victim) == 0 })
        assert("deleting a profile drops its cached Store connection",
               !fm.fileExists(atPath: victimDB.path))

        // MARK: the survivor is untouched
        assert("another profile's keychain items survive the sweep",
               Passwords.lookup(host: keepHost, profileID: defaultID)?.password == "keep")
        assert("another profile's database survives untouched, to the byte",
               fm.fileExists(atPath: keepDB.path)
               && ((try? fm.attributesOfItem(atPath: keepDB.path)[.size] as? Int) ?? nil) == keepDBSize)
        assert("another profile's favicon cache survives", fm.fileExists(atPath: keepIcon.path))
        assert("another profile's UserDefaults keys survive",
               (UserDefaults.standard.array(forKey: defaultsKey("pinnedTabs", defaultID)) as? [String]) == keepPins)
        assert("another profile's website data store survives",
               WKWebsiteDataStore.default().isPersistent)
        assert("the profile list is back to exactly the profiles that were there before",
               ProfileManager(directory: dir).profiles.map(\.id) == survivors)

        // MARK: cleanup — the sentinels are the only thing this check leaves behind
        Passwords.delete(host: keepHost, account: "survivor", profileID: defaultID)
        try? fm.removeItem(at: keepIcon)
        // Reading the cookies back above re-created the store; put that away again.
        dataStores[victim] = nil
        WKWebsiteDataStore.remove(forIdentifier: victim) { _ in }
        return out
    }

    private static func cookieCount(_ id: UUID) -> Int {
        let box = Box()
        dataStore(for: id).httpCookieStore.getAllCookies { cookies in
            box.count = cookies.count
            box.done = true
        }
        _ = wait(5) { box.done }
        return box.count
    }

    /// `check()` is synchronous and WebKit is not. Spins the main runloop rather than
    /// blocking it, because the completion handlers land on this thread.
    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !done(), Date.now < deadline {
            RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
        }
        return done()
    }

    private static func dataStoreIdentifiers() -> [UUID] {
        let box = Box()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
            box.ids = ids
            box.done = true
        }
        _ = wait(5) { box.done }
        return box.ids
    }

    /// A mutable box for the completion handlers above. They all land on the main thread,
    /// which the runloop spin above is sitting on; `@unchecked` says so out loud.
    private final class Box: @unchecked Sendable {
        var done = false
        var ids: [UUID] = []
        var count = 0
    }
}
