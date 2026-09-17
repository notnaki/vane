import AppKit
import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import WebKit

// MARK: - What Arc writes down

/// One row of an Arc space's sidebar: a tab, or a folder holding more rows.
///
/// Arc's own file is a flat `items` array where every row names its parent and every parent
/// lists its children in order; this is that array walked back into the tree it describes,
/// which is the only shape the folder half of the import can be written against. Only
/// `http(s)` tabs survive the walk — see `ArcSidebar.rows`.
enum ArcRow: Equatable, Sendable {
    case tab(url: URL, title: String)
    /// `live` is Arc's one automatic folder — its "Pull Requests" — carried as the
    /// `LiveSource` Vane fills the same folder from. nil for every folder somebody put rows
    /// in by hand, which is why it has a default: an ordinary folder is still written
    /// `.folder(name:rows:)` and reads as one.
    indirect case folder(name: String, rows: [ArcRow], live: LiveSource? = nil)
}

/// One Arc Space, as `StorableSidebar.json` describes it: which profile it belongs to, the
/// colour it is washed in, its Pinned section and its Today tabs.
///
/// `profileDirectory` is the *directory basename* under `User Data` ("Default", "Profile 1"),
/// not a display name: it is the only thing that joins a space to the Login Data, Cookies and
/// History files it was browsing with. The display name comes from `ArcProfiles`.
struct ArcSpace: Equatable, Sendable {
    let id: String
    let title: String
    let profileDirectory: String
    /// `#RRGGBB` from the space's theme, or nil for a space that never had one set.
    let themeHex: String?
    let pinned: [ArcRow]
    let today: [ArcRow]
}

/// Everything Vane wants out of `StorableSidebar.json`: the spaces, and each profile's
/// favourites row.
///
/// Pure — it takes `Data` and nothing else — so the whole parse is provable from a JSON
/// literal in `check()`, with no Arc installed and no panel to drive.
struct ArcSidebar: Equatable, Sendable {
    var spaces: [ArcSpace] = []
    /// Favourites by Arc profile directory basename. Flat: Arc's favourites row is a strip of
    /// icons and Vane's grid is a grid, so a folder that somehow got in there gives up its
    /// tabs rather than becoming a folder nothing could draw.
    var favourites: [String: [URL]] = [:]

    /// Arc writes its dictionaries as flat, alternating `[id, object, id, object]` arrays
    /// rather than as JSON objects — `spaces`, `items` and `topAppsContainerIDs` all have
    /// that shape. Reading the objects and ignoring the keys beside them is safe because
    /// every object repeats its own `id` inside itself.
    private static func objects(_ any: Any?) -> [[String: Any]] {
        (any as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// The same alternating shape, read as the pairs it actually is. Used for
    /// `containerIDs` (`["unpinned", <id>, "pinned", <id>]`) and for `topAppsContainerIDs`
    /// (profile descriptor, then container id).
    ///
    /// Everything here looks a container up by its label and never by its index. Defensive:
    /// this Mac's file writes `unpinned` first on all three of its spaces, but the same
    /// object also carries a structured `newContainerIDs` variant this parser does not read,
    /// so the flat list is a compatibility spelling and not a promise about order.
    private static func pairs(_ any: Any?) -> [(Any, Any)] {
        let list = any as? [Any] ?? []
        return stride(from: 0, to: list.count - 1, by: 2).map { (list[$0], list[$0 + 1]) }
    }

    /// Arc names a profile either `{"default": true}` or
    /// `{"custom": {"_0": {"directoryBasename": "Profile 1", …}}}`. Both spellings appear in
    /// a space's `profile` and in `topAppsContainerIDs`, so there is one reader for them.
    static func profileDirectory(_ any: Any?) -> String? {
        guard let d = any as? [String: Any] else { return nil }
        if d["default"] != nil { return "Default" }
        guard let custom = (d["custom"] as? [String: Any])?["_0"] as? [String: Any],
              let dir = custom["directoryBasename"] as? String, !dir.isEmpty else { return nil }
        return dir
    }

    /// Arc keeps colour channels as extended-sRGB doubles, which can sit outside 0…1 for a
    /// colour outside the gamut; Vane's themes are plain hex, so they are clamped on the way
    /// in rather than wrapping round into a colour nobody picked.
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// A space's ground colour. Arc's `windowTheme` is a deep tree of gradients, overlays and
    /// translucency styles; `primaryColorPalette.midTone` is the one colour in it that stands
    /// for the whole theme, and it is the one Arc itself tints the space's dot with.
    /// ponytail: one colour, not the gradient. `Spaces.setThemeColors` takes a list and Vane
    /// can draw three, but Arc's gradient lives under a different key on every theme style
    /// (`blendedGradient.baseColors`, `blendedSingleColor.color`, …) and mapping all of them
    /// is a second parser for a nicety. Ceiling: a two-colour Arc space comes across as its
    /// midtone; the upgrade path is reading `baseColors` when it is there.
    static func themeHex(_ customInfo: Any?) -> String? {
        guard let info = customInfo as? [String: Any],
              let theme = info["windowTheme"] as? [String: Any],
              let palette = theme["primaryColorPalette"] as? [String: Any],
              let mid = palette["midTone"] as? [String: Any],
              let r = mid["red"] as? Double, let g = mid["green"] as? Double,
              let b = mid["blue"] as? Double else { return nil }
        return hex(red: r, green: g, blue: b)
    }

    /// Arc's automatic folder, as the `LiveSource` Vane keeps the same folder filled from.
    ///
    /// Arc writes `data.list.automaticLiveFolderData.dataSource.github` and leaves the object
    /// under `github` empty — it has no query and no repository to carry, because Arc's live
    /// folder asks nothing: it is the pull requests you and your team have between you. That
    /// is `LiveFolders.defaultQuery` exactly (`involves:@me`, every repository the account can
    /// see), so the mapping is one for one. A `repository` Arc may start writing is the one
    /// field Vane's query has a place for and is taken when it is there; a data source that is
    /// not `github` is one Vane cannot fill, and that folder comes across as the ordinary
    /// folder it looks like.
    static func liveSource(_ list: Any?) -> LiveSource? {
        guard let list = list as? [String: Any],
              let auto = list["automaticLiveFolderData"] as? [String: Any],
              let source = auto["dataSource"] as? [String: Any],
              let github = source["github"] as? [String: Any] else { return nil }
        var query = LiveFolders.defaultQuery
        if let repo = github["repository"] as? String, !repo.isEmpty { query.repo = repo }
        return .github(query)
    }

    /// The rows of one container, in the order the parent lists its children.
    ///
    /// `seen` is a guard rail, not a fix for anything observed: `childrenIds` is a plain list
    /// of ids with nothing in the format stopping a parent appearing inside its own subtree,
    /// and a walk that met one would never return. No file read so far has one.
    private static func rows(of containerID: String, items: [String: [String: Any]],
                             seen: inout Set<String>) -> [ArcRow] {
        guard let container = items[containerID], seen.insert(containerID).inserted else { return [] }
        var out: [ArcRow] = []
        for id in container["childrenIds"] as? [String] ?? [] {
            guard let item = items[id] else { continue }
            let data = item["data"] as? [String: Any] ?? [:]
            if let tab = data["tab"] as? [String: Any] {
                // Only web pages. An `arc://` or `file://` row is a place Vane has nothing to
                // put, and letting one through would mean a sidebar row that opens nothing.
                guard let raw = tab["savedURL"] as? String, let url = URL(string: raw),
                      url.scheme == "http" || url.scheme == "https",
                      seen.insert(id).inserted else { continue }
                // The item's own `title` is the name the user typed over the row — null on
                // most tabs and not on a renamed one (7 of 28 on this Mac). `savedTitle` is
                // the name the page came with, and is what Arc draws when there is no
                // rename. Taking only `savedTitle` turned "Vane Browser" back into
                // "notnaki/vane: Native macOS browser in Swift/SwiftUI on WebKit".
                let renamed = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                out.append(.tab(url: url, title: renamed ?? (tab["savedTitle"] as? String ?? "")))
            } else if let list = data["list"] {
                // A folder. Its name is the *item's* title, not anything inside `data` —
                // `{"list": {}}` is empty on every folder a person made.
                let kids = rows(of: id, items: items, seen: &seen)
                let live = liveSource(list)
                // An empty ordinary folder is a row with nothing behind it and is dropped; an
                // empty *live* folder is the normal state of one, because what fills it is a
                // search that has not run yet. Dropping those lost the user's Pull Requests
                // folder — the one folder in Arc that Vane has a real equivalent for.
                guard !kids.isEmpty || live != nil else { continue }
                out.append(.folder(name: item["title"] as? String ?? "Folder", rows: kids,
                                   live: live))
            }
            // Anything else is an `itemContainer` (a root) nested where it cannot be, or a
            // row type this version of Arc invented after this was written. Skipped.
        }
        return out
    }

    /// nil when the file is not a sidebar at all. An empty sidebar — no spaces, no
    /// favourites — is a valid answer and a different one: the file parsed and said nothing.
    static func parse(_ data: Data) -> ArcSidebar? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sidebar = top["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any] else { return nil }
        // One of the containers is `{"global": {}}` and holds nothing; the other holds
        // everything. Picking by content rather than by index, because which is which is
        // Arc's business.
        guard let box = containers.compactMap({ $0 as? [String: Any] })
            .first(where: { $0["spaces"] != nil || $0["items"] != nil }) else { return nil }

        var items: [String: [String: Any]] = [:]
        for item in objects(box["items"]) {
            guard let id = item["id"] as? String else { continue }
            items[id] = item
        }

        var out = ArcSidebar()
        for space in objects(box["spaces"]) {
            guard let id = space["id"] as? String,
                  let directory = profileDirectory(space["profile"]) else { continue }
            var containerID: [String: String] = [:]
            for (label, value) in pairs(space["containerIDs"]) {
                guard let label = label as? String, let value = value as? String else { continue }
                containerID[label] = value
            }
            // One `seen` per space: the two sections of one space cannot share a row, and a
            // row that somehow appears in both should be drawn once.
            var seen = Set<String>()
            let pinned = containerID["pinned"].map { rows(of: $0, items: items, seen: &seen) } ?? []
            let today = containerID["unpinned"].map { rows(of: $0, items: items, seen: &seen) } ?? []
            out.spaces.append(ArcSpace(id: id,
                                       title: (space["title"] as? String) ?? "Space",
                                       profileDirectory: directory,
                                       themeHex: themeHex(space["customInfo"]),
                                       pinned: pinned, today: today))
        }

        for (descriptor, container) in pairs(box["topAppsContainerIDs"]) {
            guard let directory = profileDirectory(descriptor),
                  let container = container as? String else { continue }
            var seen = Set<String>()
            let urls = flatten(rows(of: container, items: items, seen: &seen))
            guard !urls.isEmpty else { continue }
            out.favourites[directory, default: []] += urls.map(\.url)
        }
        return out
    }

    /// Every tab in a tree, in drawing order, folders given up. What the favourites row and
    /// the Space's flat url lists are made of — the folders themselves travel separately, in
    /// a `Pins`.
    static func flatten(_ rows: [ArcRow]) -> [(url: URL, title: String)] {
        rows.flatMap { row -> [(url: URL, title: String)] in
            switch row {
            case .tab(let url, let title): [(url, title)]
            case .folder(_, let kids, _): flatten(kids)
            }
        }
    }
}

/// One Arc profile directory and the name Arc shows for it.
struct ArcProfile: Equatable, Sendable {
    /// The directory basename under `User Data`: "Default", "Profile 1", …
    let directory: String
    let name: String
}

/// `User Data/Local State` — Chromium's own profile list, which Arc keeps up to date even
/// though it draws profile names from its own store.
enum ArcProfiles {
    /// Arc never renames `Default`, so its `name` is Chromium's placeholder ("Your Chromium"
    /// on this Mac) rather than anything a user chose. The importer maps `Default` onto
    /// Vane's default profile by identity and never by name, so that placeholder is carried
    /// but never used to name anything.
    ///
    /// Sorted, with `Default` first: a dictionary has no order and the import's profile→space
    /// pass must run the same way twice.
    static func parse(_ data: Data) -> [ArcProfile] {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = (top["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [] }
        return cache.compactMap { directory, value -> ArcProfile? in
            guard let info = value as? [String: Any] else { return nil }
            let name = (info["name"] as? String) ?? ""
            return ArcProfile(directory: directory, name: name.isEmpty ? directory : name)
        }
        .sorted { a, b in
            if (a.directory == "Default") != (b.directory == "Default") { return a.directory == "Default" }
            return a.directory < b.directory
        }
    }
}

// MARK: - Chromium's at-rest encryption

/// Chromium's "Safe Storage": the AES key behind every `encrypted_value` in `Cookies` and
/// every `password_value` in `Login Data`.
///
/// `BrowserImport` deliberately stops short of this — its own note says so: "no keychain, no
/// Safe Storage key … the ceiling is that session cookies do not come across; the upgrade
/// path is the same Safe Storage decryption PasswordImport deliberately avoids." This file
/// *is* that upgrade path, and crossing the line is the whole point of Import from Arc:
/// bringing a browser across without its logins and its sessions leaves the user signed out
/// of everything, which is the one thing that makes a switch not happen. The line is crossed
/// in exactly one direction — read Arc's key, decrypt Arc's rows — and nothing here ever
/// writes to Arc or logs a decrypted value.
///
/// The scheme has not changed since 2014: the keychain holds a generic password under the
/// service "Arc Safe Storage", and the AES key is PBKDF2-HMAC-SHA1 of it with the fixed salt
/// "saltysalt" over 1003 rounds. The IV is sixteen spaces. Yes, really.
enum SafeStorage {
    /// The version tag Chromium writes in front of every value it encrypted on macOS.
    /// `v11` is Linux's libsecret variant and never appears here; a row with neither prefix
    /// is plaintext from before encryption was turned on.
    static let prefix = Data("v10".utf8)

    static let salt = Data("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let keyLength = kCCKeySizeAES128
    /// Sixteen 0x20 bytes — the ASCII space, repeated. Chromium's constant, not a choice.
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// The AES key for one browser's keychain secret.
    ///
    /// The *bytes*, not a String. A keychain generic password is a bag of bytes and nothing
    /// promises it is UTF-8; decoding it first would turn one stray byte into U+FFFD and
    /// derive a key that opens nothing, with no error anywhere — every password and every
    /// session lost to a silently wrong answer. Chromium's own secret is base64 and would
    /// always survive the round trip, but that is a fact about today's Arc and not about the
    /// keychain, and the bytes cost nothing.
    static func key(secret: Data) -> Data {
        var out = Data(count: keyLength)
        let ok = out.withUnsafeMutableBytes { key in
            secret.withUnsafeBytes { secret in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secret.bindMemory(to: Int8.self).baseAddress,
                                         secret.count,
                                         salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                                         key.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        return ok == kCCSuccess ? out : Data()
    }

    /// The same over text, which is how `check()` pins the derivation to a known answer
    /// without a keychain in the room.
    static func key(secret: String) -> Data { key(secret: Data(secret.utf8)) }

    /// One `encrypted_value` or `password_value`, in the clear.
    ///
    /// `hostKey` is the cookie's `host_key` and is what makes the newer Chromium format
    /// readable: since M127 a cookie's plaintext is SHA-256 of its host key followed by the
    /// value, so that a cookie copied into another domain's row decrypts to nothing useful.
    /// It is checked rather than assumed — a `Login Data` row has no host prefix, and neither
    /// does a cookie written by an older Arc — so the same function reads both formats.
    ///
    /// nil for anything that does not come out as UTF-8: a value encrypted under a different
    /// key, a truncated row, or a profile whose keychain item is not the one we read.
    static func decrypt(_ value: Data, key: Data, hostKey: String? = nil) -> String? {
        guard key.count == keyLength, value.count > prefix.count,
              value.prefix(prefix.count) == prefix else { return nil }
        let body = Data(value.dropFirst(prefix.count))
        guard body.count >= kCCBlockSizeAES128, body.count % kCCBlockSizeAES128 == 0 else { return nil }

        var out = Data(count: body.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                iv.withUnsafeBytes { iv in
                    key.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, keyLength, iv.baseAddress,
                                src.baseAddress, src.count,
                                dst.baseAddress, dst.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out = out.prefix(written)

        if let hostKey {
            let hash = Data(SHA256.hash(data: Data(hostKey.utf8)))
            if out.count >= hash.count, out.prefix(hash.count) == hash {
                out = out.dropFirst(hash.count)
            }
        }
        return String(data: out, encoding: .utf8)
    }
}

// MARK: - The import itself

/// Bring a whole Arc installation into Vane: its profiles, its spaces with their themes,
/// pinned rows, folders and Today tabs, each profile's favourites, its saved logins, its
/// logged-in sessions, and its history and bookmarks.
///
/// ponytail: one enum, no protocol, no per-thing importer object. Every step is a function
/// that takes what it read and calls the API that already exists for that thing —
/// `ProfileManager.createSpace`, `Passwords.save`, `WKHTTPCookieStore.setCookie`,
/// `BrowserImport.importAll`. The only new *concept* in the file is Arc's on-disk shape.
enum ArcImport {

    /// Chromium's microseconds since 1601-01-01 UTC, the Windows FILETIME epoch.
    ///
    /// nil for zero, which is what a session cookie's `expires_utc` holds — and an
    /// `HTTPCookie` with no expiry *is* a session cookie, so the nil travels all the way
    /// through rather than being turned into a date in 1601 that expires the cookie on
    /// arrival. `BrowserImport.chromiumTime` is the same arithmetic without the nil; it is
    /// reading `last_visit_time`, where zero is already filtered out in SQL.
    static func chromeTime(_ micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return BrowserImport.chromiumTime(micros)
    }

    /// An Arc space's Pinned section, as the three things Vane writes it down as: the folder
    /// shape, the flat url list the shape orders, and the titles to park under each url.
    ///
    /// The shape names its rows by url, which is exactly what `TabStore.saveShape` writes and
    /// what `restorePins` reads back — so a Space built here comes up through the ordinary
    /// restore path with no import-shaped code anywhere near it.
    ///
    /// Pure, so `selfcheck --pure` can prove the whole tree-to-flat translation with no
    /// window, no defaults and no Space on disk.
    static func shape(_ rows: [ArcRow]) -> (pins: Pins, urls: [URL], titles: [String: String]) {
        var pins = Pins()
        var urls: [URL] = []
        var titles: [String: String] = [:]

        func walk(_ rows: [ArcRow], parent: UUID?, depth: Int) {
            for row in rows {
                switch row {
                case .tab(let url, let title):
                    pins.entries.append(Pins.Entry(row: .tab(url.absoluteString), parent: parent))
                    urls.append(url)
                    // Two rows on the same page are one key in the sidecar, exactly as they
                    // are for a Space Vane wrote itself; the first title wins rather than the
                    // last, so the page keeps the name of the row drawn first.
                    if !title.isEmpty, titles[url.absoluteString] == nil {
                        titles[url.absoluteString] = title
                    }
                case .folder(let name, let kids, let live):
                    // Arc nests as deep as it likes and Vane's sidebar stops at
                    // `Pins.maxDepth`. A folder past that gives up its rows to the folder it
                    // is in rather than being dropped: losing a name is a cosmetic loss,
                    // losing the tabs is not.
                    guard depth <= Pins.maxDepth else {
                        walk(kids, parent: parent, depth: depth)
                        continue
                    }
                    var folder = Folder(name: name)
                    // A live folder is an ordinary folder with a source on it — the same
                    // field `newLiveFolder` sets — so it comes up live through the ordinary
                    // restore and fills itself on the Space's next refresh.
                    folder.live = live
                    pins.entries.append(Pins.Entry(row: .folder(folder), parent: parent))
                    walk(kids, parent: folder.id, depth: depth + 1)
                }
            }
        }
        walk(rows, parent: nil, depth: 0)
        return (pins, urls, titles)
    }

    // MARK: What is on disk

    /// One Arc profile directory, with the rows that need the Safe Storage key already read
    /// but not yet decrypted. Read once, before the summary alert, so the counts the user is
    /// asked to approve are the real ones rather than an estimate.
    struct Vault: Sendable {
        let directory: String
        let path: URL
        var logins: [(origin: String, account: String, value: Data)] = []
        var cookies: [(host: String, name: String, path: String, value: Data,
                       expires: Int64, secure: Bool)] = []
        /// Files Arc still has that would not open. Zero cookies and "Vane could not read
        /// your cookies" are different answers, and the second one used to be reported as
        /// the first because the read was a `try?`.
        var unreadable = 0
    }

    /// One vault with its sealed rows opened. What is left is ordinary strings, so every
    /// decision that needs Vane — which profile already has this login, which data store a
    /// cookie belongs in — is made on the main actor from these and the AES is not.
    struct Opened: Sendable {
        var logins: [(host: String, account: String, password: String)] = []
        var cookies: [(host: String, name: String, path: String, value: String,
                       expires: Int64, secure: Bool)] = []
        /// Rows Vane will not save and nothing was lost by not saving: Chromium writes a site
        /// you told it never to save as a login with an empty username, and an origin with no
        /// host in it names nothing. Counted apart from the ones already here, which they
        /// used to inflate.
        var skipped = 0
        /// Rows the key would not open. All of them, with a key in hand, is the wrong key.
        var locked = 0
    }

    /// Everything one Arc installation has to say, read and parsed, before anything is
    /// written into Vane.
    struct Scan: Sendable {
        let root: URL
        let sidebar: ArcSidebar
        let profiles: [ArcProfile]
        /// Every Arc profile directory that gets a Vane profile — including one whose folder
        /// under `User Data` is gone, which `vaults` by definition has no entry for.
        var directories: [String] = []
        var vaults: [String: Vault] = [:]

        /// Arc's `User Data`, where the Chromium half of the installation lives.
        var userData: URL { root.appendingPathComponent("User Data") }
        var passwordCount: Int { vaults.values.reduce(0) { $0 + $1.logins.count } }
        var cookieCount: Int { vaults.values.reduce(0) { $0 + $1.cookies.count } }
        var pinnedCount: Int { sidebar.spaces.reduce(0) { $0 + ArcSidebar.flatten($1.pinned).count } }
    }

    /// What the import managed to do, for the toast at the end — and what it did not, which
    /// is the half a summary of successes alone cannot say.
    struct Counts {
        var profiles = 0, spaces = 0, spacesSkipped = 0
        var favourites = 0, liveFolders = 0
        var passwords = 0, passwordsAlready = 0, passwordsSkipped = 0
        var cookies = 0, history = 0, bookmarks = 0
        /// Rows the Safe Storage key would not open, of either kind.
        var locked = 0
        /// Rows that came out in the clear and the keychain would not take.
        var refused = 0
        /// Files Arc still has that would not open at all — Full Disk Access, most likely.
        var unreadable = 0
        /// True when the keychain would not give up Arc's key, so the two things that need
        /// it were skipped wholesale rather than one row at a time.
        var noKey = false

        /// A key was read and not one of the rows sealed with it came out. That is a key for
        /// another browser, or an Arc that has re-keyed since — and "0 passwords" on its own
        /// reads as "Arc had none", which is the opposite of what happened.
        var wrongKey: Bool {
            !noKey && locked > 0 && refused == 0 && passwords == 0 && cookies == 0
        }
    }

    nonisolated private static func text(_ st: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }

    nonisolated private static func blob(_ st: OpaquePointer, _ col: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(st, col) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(st, col)))
    }

    /// Read one Arc profile directory's encrypted rows. Both files are copied before they are
    /// opened — see `BrowserImport.query` — so Arc can stay open the whole time, which is the
    /// difference between an import the user can run now and one that starts with "quit Arc".
    ///
    /// A missing file leaves its list empty and takes nothing else with it: a profile with no
    /// saved logins is ordinary. A file that is *there* and will not open is counted, because
    /// a locked `Cookies` must not cost the user their spaces and must not be reported as an
    /// Arc that had no cookies either.
    ///
    /// `nonisolated`: this is a file copy and a `sqlite3_step` loop over a profile that can
    /// hold six figures of rows, and running it on the main actor froze the window between
    /// the panel and the summary alert. Nothing in it is UI.
    nonisolated private static func read(vault directory: String, at path: URL) -> Vault {
        var vault = Vault(directory: directory, path: path)
        func read(_ name: String, _ sql: String, _ row: (OpaquePointer) -> Void) {
            let file = path.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            do { try BrowserImport.query(file, sql, row) } catch { vault.unreadable += 1 }
        }
        read("Login Data", """
            SELECT origin_url, username_value, password_value FROM logins
            """) { vault.logins.append((text($0, 0), text($0, 1), blob($0, 2))) }
        read("Cookies", """
            SELECT host_key, name, path, encrypted_value, expires_utc, is_secure FROM cookies
            """) {
            vault.cookies.append((text($0, 0), text($0, 1), text($0, 2), blob($0, 3),
                                  sqlite3_column_int64($0, 4), sqlite3_column_int($0, 5) != 0))
        }
        return vault
    }

    /// Which Arc profile directories become Vane profiles: the ones `Local State` lists and
    /// still have a folder, plus every one a space or a favourites row points at whether the
    /// folder is there or not.
    ///
    /// That second half is the whole rule. A profile Chromium's cache has forgotten still has
    /// a space pointing at it, and those tabs are worth more than the tidiness of ignoring
    /// it — the space comes across with no passwords, no cookies and no history, which is
    /// everything the missing folder held. The first half is what keeps the list honest the
    /// other way: a directory `Local State` remembers, whose folder is gone and which nothing
    /// in the sidebar refers to, is a profile Arc itself has nothing left for.
    ///
    /// Pure, over an `onDisk` answer rather than the filesystem, so both halves are provable.
    static func directories(in sidebar: ArcSidebar, listed: [ArcProfile],
                            onDisk: (String) -> Bool) -> [String] {
        var out = Set(listed.map(\.directory).filter(onDisk))
        out.formUnion(sidebar.spaces.map(\.profileDirectory))
        out.formUnion(sidebar.favourites.keys)
        return out.sorted()
    }

    /// Arc's folder, read into values. nil when the folder is not an Arc installation.
    ///
    /// `async` for the SQLite half, which is handed to a detached task: see `read(vault:at:)`.
    /// The two JSON files are small enough to read here.
    @MainActor static func scan(_ root: URL) async -> Scan? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("StorableSidebar.json")),
              let sidebar = ArcSidebar.parse(data) else { return nil }
        let userData = root.appendingPathComponent("User Data")
        let listed = (try? Data(contentsOf: userData.appendingPathComponent("Local State")))
            .map(ArcProfiles.parse) ?? []
        let fm = FileManager.default
        let directories = directories(in: sidebar, listed: listed) {
            fm.fileExists(atPath: userData.appendingPathComponent($0).path)
        }

        let reading = Task.detached(priority: .userInitiated) {
            directories.compactMap { directory -> Vault? in
                let path = userData.appendingPathComponent(directory)
                guard FileManager.default.fileExists(atPath: path.path) else { return nil }
                return read(vault: directory, at: path)
            }
        }
        var scan = Scan(root: root, sidebar: sidebar, profiles: listed, directories: directories)
        for vault in await reading.value { scan.vaults[vault.directory] = vault }
        return scan
    }

    // MARK: The keychain

    /// Arc's Safe Storage secret, derived into the AES key every row below is sealed with.
    ///
    /// This is the one item Vane reads that is not its own, and macOS treats it as exactly
    /// that: the first read raises the "Vane wants to use your confidential information
    /// stored in Arc Safe Storage" panel, and the answer is remembered for this app.
    ///
    /// ponytail: no fallback and no retry. There is no second way to read a Chromium key —
    /// refuse the panel and the passwords and sessions are simply skipped, while the spaces,
    /// favourites, history and bookmarks still come across. Ceiling: an ad-hoc-signed build
    /// changes identity on every rebuild, so the remembered answer does not stick across a
    /// self-built Vane; a Developer ID build asks once and never again.
    @MainActor private static func safeStorageKey() -> Data? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            // Service *and* account, the pair Chromium writes: a keychain holding another
            // Chromium browser's item under a service that happens to match would otherwise
            // hand back a key that opens none of Arc's rows.
            kSecAttrService as String: "Arc Safe Storage",
            kSecAttrAccount as String: "Arc",
            kSecReturnData as String: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, !data.isEmpty else { return nil }
        // The secret never leaves this function, and goes in as the bytes it is — see
        // `SafeStorage.key(secret: Data)`. What comes back is the derived key, and neither is
        // ever printed.
        let key = SafeStorage.key(secret: data)
        return key.isEmpty ? nil : key
    }

    // MARK: Writing it into Vane

    /// The Vane profile an Arc profile directory becomes.
    ///
    /// `Default` is Vane's default profile by identity, never by name: Arc leaves Chromium's
    /// placeholder ("Your Chromium") in `Local State` for it, and matching on that would
    /// either rename the user's profile or make a second one beside it. Every other Arc
    /// profile is matched to a Vane profile of the same name, and created when there is none.
    ///
    /// Over `scan.directories`, not over the vaults: a directory whose folder is gone has no
    /// vault and still has a space, and is named by the title of that space when `Local State`
    /// has forgotten it too — otherwise the profile would be called "Profile 4".
    @MainActor static func profileIDs(for scan: Scan, counts: inout Counts) -> [String: UUID] {
        var byDirectory: [String: String] = [:]
        for p in scan.profiles { byDirectory[p.directory] = p.name }

        var out: [String: UUID] = [:]
        for directory in scan.directories {
            if directory == "Default" { out[directory] = ProfileManager.defaultID; continue }
            let name = byDirectory[directory]
                ?? scan.sidebar.spaces.first { $0.profileDirectory == directory }?.title
                ?? directory
            if let existing = ProfileManager.shared.profiles
                .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                out[directory] = existing.id
            } else {
                out[directory] = ProfileManager.shared.create(name: name).id
                counts.profiles += 1
            }
        }
        return out
    }

    /// One Arc space, written down as a Vane Space: its theme, its Pinned rows with the
    /// folders around them, its Today tabs, and the titles all of those come up under.
    ///
    /// A space whose name the profile already has is skipped whole. That is what makes a
    /// second run safe: there is no field-by-field merge to get wrong, and a user who wants
    /// one space again can rename or delete the one they have.
    ///
    /// False for a space that was skipped, so the caller knows whether the profile's window
    /// has anything new to be told about.
    @MainActor private static func write(_ arc: ArcSpace, into profileID: UUID,
                                         counts: inout Counts) -> Bool {
        guard !ProfileManager.shared.spaces(for: profileID)
            .contains(where: { $0.name.caseInsensitiveCompare(arc.title) == .orderedSame })
        else { counts.spacesSkipped += 1; return false }

        let (pins, pinnedURLs, pinnedTitles) = shape(arc.pinned)
        // Today has a shape of its own on disk — a second key of exactly the same form, named
        // by url the same way (`TabStore.saveShape`) and read back by `adoptTodayShape`. So
        // Arc's Today folders survive rather than being flattened out of existence, which is
        // what `flatten` used to do to them.
        let (todayShape, todayURLs, todayTitles) = shape(arc.today)

        var space = ProfileManager.shared.createSpace(name: arc.title, in: profileID)
        space.pinnedTabURLs = pinnedURLs
        space.tabURLs = todayURLs
        if let hex = arc.themeHex { Spaces.setThemeColors([hex], on: &space) }
        ProfileManager.shared.updateSpace(space)

        // The folders, beside the urls they order — the same keys `TabStore.saveShape` writes
        // and `restorePins`/`adoptTodayShape` read, so the Space comes up through the ordinary
        // restore path.
        func save(_ shape: Pins, _ kind: TabKind) {
            guard !shape.isEmpty, let data = try? JSONEncoder().encode(shape) else { return }
            UserDefaults.vane.set(data, forKey: TabStore.shapeKey(kind, space: space.id,
                                                                  profileID: profileID))
        }
        save(pins, .pinned)
        save(todayShape, .today)
        // Arc's live folder, kept. It is a `Folder` with a `LiveSource` on it exactly as
        // `newLiveFolder` leaves one, so the next refresh of that Space fills it — only
        // Pinned, because that is the section `LiveFolders` looks in.
        counts.liveFolders += pins.entries.filter { $0.folder?.live != nil }.count

        // And the names, in the sidecar, keyed by url exactly as `saveCurrentSpace` keys it.
        // Without this every restored row comes up named after its host — "github.com"
        // instead of the page Arc was showing.
        var parked: [String: Parked] = [:]
        for (url, title) in pinnedTitles.merging(todayTitles, uniquingKeysWith: { a, _ in a }) {
            parked[url] = Parked(title: title)
        }
        if !parked.isEmpty {
            Suspension.SpaceState.save(parked, space: space.id, profileID: profileID,
                                       in: Store.directory)
        }
        counts.spaces += 1
        return true
    }

    /// The profile's favourites grid, appended to rather than replaced: a user who has
    /// already set Vane up keeps what they put there, and a second run adds nothing.
    ///
    /// Capped at `Spaces.favouritesCap`, which is the same twelve tiles Arc draws and the
    /// same number `Spaces.favourites` would silently trim back to on the next read — so what
    /// the toast counts is what the grid will actually hold.
    @MainActor private static func write(favourites urls: [URL], into profileID: UUID,
                                         counts: inout Counts) {
        let key = TabStore.defaultsKey(.favourite, profileID)
        let have = (UserDefaults.vane.stringArray(forKey: key) ?? []).compactMap(URL.init(string:))
        // The profile's own rule for this list: what is there first, Arc's after, deduped on
        // the absolute string and capped at `Spaces.favouritesCap`. It has to be that rule —
        // `Spaces.favourites` trims the key back to the cap on the next read, so anything
        // past twelve written here would be counted in the toast and then quietly dropped.
        let merged = Spaces.mergedFavourites(existing: have, perSpace: [urls])
        let before = Set(have.map(\.absoluteString))
        let added = merged.filter { !before.contains($0.absoluteString) }
        guard !added.isEmpty else { return }
        counts.favourites += added.count
        UserDefaults.vane.set(merged.map(\.absoluteString), forKey: key)
        // The key on its own is not enough. Every open window rewrites this key wholesale
        // from its own strip on the next `savePins` or `saveCurrentSpace`, so a grid that only
        // reached disk is gone the first time the user pins a tab — and it was never on
        // screen in the meantime either. The tiles have to exist in the windows, which is the
        // same thing `LibraryWindow` does when it moves a row between Spaces.
        for store in TabStore.all
        where store.profileID == profileID && !store.isPrivate && !store.isLittle {
            store.restore(added, as: .favourite, parked: [:])
            // `restore` appends, and the strip is sorted by section: the new tiles are put
            // back at the end of the Favourites run rather than left below Today.
            store.normaliseSections()
        }
    }

    /// One vault's sealed rows, opened.
    ///
    /// `nonisolated`, and the only thing between `read` and the two `write`s that is: a vault
    /// with a couple of hundred logins and a few thousand cookies is that many CBC blocks and
    /// as many SHA-256s, and doing them on the main actor is the window not drawing between
    /// the alert and the first tile. The keychain read stays on the main actor and so does
    /// every write; what crosses is `Data` in and `String` out.
    ///
    /// No value is ever logged, and none is held anywhere but in the returned struct.
    nonisolated static func open(_ vault: Vault, key: Data) -> Opened {
        var out = Opened()
        for login in vault.logins {
            guard !login.account.isEmpty,
                  let host = URLComponents(string: login.origin)?.host?.lowercased(), !host.isEmpty
            else { out.skipped += 1; continue }
            guard let password = SafeStorage.decrypt(login.value, key: key), !password.isEmpty
            else { out.locked += 1; continue }
            out.logins.append((host, login.account, password))
        }
        for row in vault.cookies {
            guard !row.host.isEmpty, !row.name.isEmpty else { out.skipped += 1; continue }
            guard let value = SafeStorage.decrypt(row.value, key: key, hostKey: row.host)
            else { out.locked += 1; continue }
            out.cookies.append((row.host, row.name, row.path, value, row.expires, row.secure))
        }
        return out
    }

    /// Arc's saved logins, into the profile's keychain items.
    ///
    /// An entry the profile already has is left exactly as it is — the keychain's own primary
    /// key for an internet password is host plus account, so overwriting would silently
    /// replace a password the user may have changed in Vane since.
    @MainActor private static func write(logins: [(host: String, account: String, password: String)],
                                         into profileID: UUID, counts: inout Counts) {
        let already = Set(Passwords.all(profileID: profileID).map(\.id))
        for login in logins {
            guard !already.contains(Passwords.key(host: login.host, account: login.account))
            else { counts.passwordsAlready += 1; continue }
            if Passwords.save(host: login.host, account: login.account,
                              password: login.password, profileID: profileID) {
                counts.passwords += 1
            } else {
                counts.refused += 1
            }
        }
    }

    /// Arc's cookies, into the profile's website data store — which is what carries the user
    /// across still signed in to everything they were signed in to.
    ///
    /// ponytail: `HTTPCookie`'s public properties only. SameSite and HttpOnly have no
    /// documented keys, so a cookie arrives without them; WebKit applies its own defaults and
    /// the session still works. Ceiling: a site that depends on a cookie being HttpOnly sees
    /// a script-readable one until the site rewrites it, which is on the first page load.
    @MainActor private static func write(cookies: [(host: String, name: String, path: String,
                                                    value: String, expires: Int64, secure: Bool)],
                                         into profileID: UUID) async -> Int {
        let store = ProfileManager.dataStore(for: profileID).httpCookieStore
        var written = 0
        for row in cookies {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: row.name, .value: row.value, .domain: row.host,
                .path: row.path.isEmpty ? "/" : row.path,
            ]
            if row.secure { properties[.secure] = "TRUE" }
            // nil is a session cookie and stays one; see `chromeTime`.
            if let expires = chromeTime(row.expires) { properties[.expires] = expires }
            guard let cookie = HTTPCookie(properties: properties) else { continue }
            await store.setCookie(cookie)
            written += 1
        }
        return written
    }

    /// The whole import, in the order the design calls for: profiles, then spaces, then
    /// favourites, then passwords, then sessions, then history and bookmarks.
    ///
    /// One profile throwing never stops the next: a locked `History` in Arc's work profile
    /// must not cost the user the personal profile's spaces.
    @MainActor static func apply(_ scan: Scan) async -> Counts {
        var counts = Counts()
        let ids = profileIDs(for: scan, counts: &counts)
        let key = safeStorageKey()
        counts.noKey = key == nil

        var gained: Set<UUID> = []
        for space in scan.sidebar.spaces {
            guard let profileID = ids[space.profileDirectory] else { continue }
            if write(space, into: profileID, counts: &counts) { gained.insert(profileID) }
        }
        for (directory, urls) in scan.sidebar.favourites.sorted(by: { $0.key < $1.key }) {
            guard let profileID = ids[directory] else { continue }
            write(favourites: urls, into: profileID, counts: &counts)
        }
        for (directory, vault) in scan.vaults.sorted(by: { $0.key < $1.key }) {
            guard let profileID = ids[directory] else { continue }
            counts.unreadable += vault.unreadable
            if let key {
                // The AES off the main actor, the keychain and the cookie store on it.
                let opened = await Task.detached(priority: .userInitiated) {
                    open(vault, key: key)
                }.value
                counts.passwordsSkipped += opened.skipped
                counts.locked += opened.locked
                write(logins: opened.logins, into: profileID, counts: &counts)
                counts.cookies += await write(cookies: opened.cookies, into: profileID)
            }
            let fm = FileManager.default
            let hasHistory = fm.fileExists(atPath: vault.path.appendingPathComponent("History").path)
            let hasBookmarks = fm.fileExists(atPath: vault.path.appendingPathComponent("Bookmarks").path)
            guard hasHistory || hasBookmarks else { continue }
            let profile = BrowserProfile(browser: "Arc", profile: directory, path: vault.path,
                                         hasHistory: hasHistory, hasBookmarks: hasBookmarks)
            // `importAll` reaches the right profile's Store because it was given one to reach;
            // before Import from Arc it always wrote into whichever profile was on screen.
            if let done = try? BrowserImport.importAll(from: profile, profileID: profileID) {
                counts.history += done.history
                counts.bookmarks += done.bookmarks
            }
        }
        // `spaces.json` is a file read, and every open window of the profile holds the list it
        // read at launch: without this the imported Spaces are on disk and invisible until the
        // next one. Every other writer of that file does the same — see `Spaces.move` and
        // `TabStore.reorderSpaces`.
        for store in TabStore.all where gained.contains(store.profileID) { store.spacesChanged() }
        return counts
    }

    // MARK: UI

    /// The menu item. One panel, one summary, one toast.
    @MainActor static func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Import from Arc"
        panel.message = "Choose Arc's folder — Library/Application Support/Arc. "
            + "macOS only lets Vane read a folder you pick yourself."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // The sandbox hides ~/Library from the panel's sidebar but not from a path it is
        // opened at, which is why this is set rather than left to the last-used folder.
        panel.directoryURL = LegacyData.realHome
            .appendingPathComponent("Library/Application Support/Arc", isDirectory: true)
        guard panel.runModal() == .OK, let root = panel.url else { return }

        // A Task around the rest of it because the scan reads Arc's SQLite off the main
        // actor: the summary alert is only worth putting up once the counts in it are real.
        Task { @MainActor in
            guard let scan = await scan(root) else {
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "That folder doesn't look like Arc."
                a.informativeText = "Vane looked for StorableSidebar.json in "
                    + "\(root.lastPathComponent) and found none. Arc's folder is usually "
                    + "Library/Application Support/Arc."
                a.runModal()
                return
            }

            let alert = NSAlert()
            alert.messageText = "Import from Arc"
            alert.informativeText = summary(scan) + "\n\n"
                + "Nothing in Arc is changed, and Arc can stay open. macOS will ask once to let "
                + "Vane read Arc's key from your keychain — that is what saved passwords and "
                + "staying signed in need. Spaces you already have with the same name are left "
                + "alone."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // Said before the work rather than only after it: the sessions go in one cookie
            // at a time and a big Arc is a few seconds of nothing happening otherwise.
            Toasts.show("Importing from Arc…")
            let counts = await apply(scan)
            Toasts.show(report(counts))
            rebuild()                       // the History and Bookmarks menus are snapshots
            BookmarkManager.refresh(profileID: ProfileManager.activeProfileID)
        }
    }

    /// What the summary alert says it found. Pure, over the scan, so the sentence can be
    /// read without running an import.
    static func summary(_ scan: Scan) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        return "Found " + [
            // `directories`, not `vaults`: a profile whose folder Arc has lost still gets a
            // Vane profile and still brings its spaces, and the alert has to advertise what
            // the import will actually do.
            plural(scan.directories.count, "profile", "profiles"),
            plural(scan.sidebar.spaces.count, "space", "spaces"),
            plural(scan.pinnedCount, "pinned tab", "pinned tabs"),
            plural(scan.passwordCount, "password", "passwords"),
            plural(scan.cookieCount, "cookie", "cookies"),
        ].joined(separator: ", ") + "."
    }

    /// The toast: what happened, and then what did not.
    ///
    /// The second half is the point. A list of successes alone let a run that read the wrong
    /// key, or could not open `Login Data` at all, come back saying "Imported 3 spaces." —
    /// which reads as an Arc that had no passwords in it. A blocklist row is the one failure
    /// not named: Chromium writes a site you told it never to save as a login with no
    /// username, and nothing was lost by not bringing it across.
    static func report(_ c: Counts) -> String {
        var parts: [String] = []
        if c.profiles > 0 { parts.append("\(c.profiles) profile\(c.profiles == 1 ? "" : "s")") }
        if c.spaces > 0 { parts.append("\(c.spaces) space\(c.spaces == 1 ? "" : "s")") }
        if c.liveFolders > 0 {
            parts.append("\(c.liveFolders) live folder\(c.liveFolders == 1 ? "" : "s")")
        }
        if c.favourites > 0 { parts.append("\(c.favourites) favourite\(c.favourites == 1 ? "" : "s")") }
        if c.passwords > 0 { parts.append("\(c.passwords) password\(c.passwords == 1 ? "" : "s")") }
        if c.cookies > 0 { parts.append("\(c.cookies) session\(c.cookies == 1 ? "" : "s")") }
        if c.history > 0 { parts.append("\(c.history) history entr\(c.history == 1 ? "y" : "ies")") }
        if c.bookmarks > 0 { parts.append("\(c.bookmarks) bookmark\(c.bookmarks == 1 ? "" : "s")") }

        var tail: [String] = []
        if c.noKey {
            tail.append("Passwords and sessions need Arc's keychain key.")
        } else if c.wrongKey {
            tail.append("Arc's keychain key opened none of them — nothing Arc had sealed "
                + "could be read.")
        } else if c.locked + c.refused > 0 {
            tail.append("\(c.locked + c.refused) could not be read.")
        }
        if c.unreadable > 0 {
            tail.append("\(c.unreadable) file\(c.unreadable == 1 ? "" : "s") Arc still has "
                + "would not open — Full Disk Access, most likely.")
        }
        guard !parts.isEmpty else {
            return tail.isEmpty ? "Arc had nothing left to import."
                : (["Nothing came across."] + tail).joined(separator: " ")
        }
        return (["Imported " + parts.joined(separator: ", ") + "."] + tail).joined(separator: " ")
    }

    // MARK: Offline checks

    /// Pure: JSON literals, a known-answer key derivation, an encrypt/decrypt round trip in
    /// memory, and epoch arithmetic. No Arc, no keychain, no panel, no filesystem.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        // MARK: the sidebar
        //
        // A trimmed StorableSidebar.json in the shape this Mac's Arc actually writes: the
        // alternating id/object arrays, three spaces (one of them on a custom profile and one
        // with only a pinned container), a folder holding two tabs of which one is not a web
        // page, a renamed tab, an empty folder, Arc's automatic Pull Requests folder, a Today
        // folder, and a favourites container per profile.
        //
        // The two spaces list `containerIDs` in opposite orders. The real file does not — all
        // three of this Mac's spaces write `unpinned` first — but the flat list is a
        // compatibility spelling beside a structured `newContainerIDs` this parser does not
        // read, so the lookup is by label and this is what proves it.
        let sidebarJSON = """
        {"version": 3, "sidebar": {"containers": [
          {"global": {}},
          {"spaces": [
            "space-default", {"id": "space-default", "title": "Personal",
              "profile": {"default": true},
              "containerIDs": ["unpinned", "d-un", "pinned", "d-pin"],
              "customInfo": {"iconType": {}, "windowTheme": {"background": {},
                "primaryColorPalette": {"shadedDark": {"red": 0, "green": 0, "blue": 0},
                  "midTone": {"red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1,
                              "colorSpace": "extendedSRGB"}}}}},
            "space-work", {"id": "space-work", "title": "Work",
              "profile": {"custom": {"_0": {"directoryBasename": "Profile 1",
                                            "machineID": "A7EBB882"}}},
              "containerIDs": ["pinned", "w-pin", "unpinned", "w-un"],
              "customInfo": {}},
            "space-bare", {"id": "space-bare", "title": "Bare",
              "profile": {"default": true},
              "containerIDs": ["pinned", "b-pin"]}
          ],
          "items": [
            "d-pin", {"id": "d-pin", "parentID": null, "title": null,
              "childrenIds": ["t-apple", "f-reading", "f-empty", "f-live"],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-default"}}}}},
            "t-apple", {"id": "t-apple", "parentID": "d-pin", "title": "Apple Newsroom",
              "childrenIds": [],
              "data": {"tab": {"savedURL": "https://apple.com/", "savedTitle": "Apple"}}},
            "f-reading", {"id": "f-reading", "parentID": "d-pin", "title": "Reading",
              "childrenIds": ["t-swift", "t-library"], "data": {"list": {}}},
            "t-swift", {"id": "t-swift", "parentID": "f-reading", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://swift.org/blog", "savedTitle": "Swift Blog"}}},
            "t-library", {"id": "t-library", "parentID": "f-reading", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "arc://library", "savedTitle": "Library"}}},
            "f-empty", {"id": "f-empty", "parentID": "d-pin", "title": "Empty",
              "childrenIds": [], "data": {"list": {}}},
            "f-live", {"id": "f-live", "parentID": "d-pin", "title": "Pull Requests",
              "childrenIds": [], "data": {"list": {"customInfo": {"iconType": {"icon": "github"}},
                "automaticLiveFolderData": {"hiddenItems": [], "dataSource": {"github": {}},
                  "lastFetch": {"timestamp": 811254387.940695}}}}},
            "d-un", {"id": "d-un", "parentID": null, "title": null,
              "childrenIds": ["t-today", "f-later"],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-default"}}}}},
            "t-today", {"id": "t-today", "parentID": "d-un", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://example.com/today", "savedTitle": "Today"}}},
            "f-later", {"id": "f-later", "parentID": "d-un", "title": "Later",
              "childrenIds": ["t-later"], "data": {"list": {}}},
            "t-later", {"id": "t-later", "parentID": "f-later", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://example.com/later", "savedTitle": "Later Reading"}}},
            "w-pin", {"id": "w-pin", "parentID": null, "title": null, "childrenIds": ["t-github"],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-work"}}}}},
            "t-github", {"id": "t-github", "parentID": "w-pin", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://github.com/", "savedTitle": "GitHub"}}},
            "w-un", {"id": "w-un", "parentID": null, "title": null, "childrenIds": [],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-work"}}}}},
            "b-pin", {"id": "b-pin", "parentID": null, "title": null, "childrenIds": [],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-bare"}}}}},
            "fav-default", {"id": "fav-default", "parentID": null, "title": null,
              "childrenIds": ["t-mail"],
              "data": {"itemContainer": {"containerType": {"topApps": {"_0": {"default": true}}}}}},
            "t-mail", {"id": "t-mail", "parentID": "fav-default", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://mail.example.com/", "savedTitle": "Mail"}}},
            "fav-work", {"id": "fav-work", "parentID": null, "title": null, "childrenIds": ["t-cal"],
              "data": {"itemContainer": {"containerType": {"topApps": {"_0": {"custom": {"_0":
                {"directoryBasename": "Profile 1"}}}}}}}},
            "t-cal", {"id": "t-cal", "parentID": "fav-work", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://calendar.example.com/", "savedTitle": "Cal"}}}
          ],
          "topAppsContainerIDs": [
            {"default": true}, "fav-default",
            {"custom": {"_0": {"directoryBasename": "Profile 1"}}}, "fav-work"]
          }]}}
        """
        guard let sidebar = ArcSidebar.parse(Data(sidebarJSON.utf8)) else {
            assert("arc sidebar: the fixture parses at all", false)
            return out
        }
        assert("arc sidebar: every space is found, in the order Arc lists them",
               sidebar.spaces.map(\.title) == ["Personal", "Work", "Bare"])
        assert("arc sidebar: a default-profile space names the Default directory",
               sidebar.spaces.first?.profileDirectory == "Default")
        assert("arc sidebar: a custom-profile space names its directory basename",
               sidebar.spaces.dropFirst().first?.profileDirectory == "Profile 1")
        assert("arc sidebar: the theme's midtone comes across as hex",
               sidebar.spaces.first?.themeHex == "#FF8000")
        assert("arc sidebar: a space with no theme asks for no colour",
               sidebar.spaces.dropFirst().first?.themeHex == nil)
        assert("arc sidebar: pinned and unpinned are looked up by name, not by position",
               ArcSidebar.flatten(sidebar.spaces[1].pinned).map(\.title) == ["GitHub"]
                   && sidebar.spaces[1].today.isEmpty)
        assert("arc sidebar: a space whose containerIDs name only pinned still parses",
               sidebar.spaces.last?.pinned.isEmpty == true && sidebar.spaces.last?.today.isEmpty == true)
        assert("arc sidebar: Today tabs come from the unpinned container",
               ArcSidebar.flatten(sidebar.spaces[0].today).map(\.url.absoluteString)
                   == ["https://example.com/today", "https://example.com/later"])
        assert("arc sidebar: a folder keeps its name and its children's order",
               sidebar.spaces[0].pinned[1] == .folder(name: "Reading", rows: [
                   .tab(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog")]))
        assert("arc sidebar: a tab that is not a web page is not imported",
               !ArcSidebar.flatten(sidebar.spaces[0].pinned).contains { $0.title == "Library" })
        assert("arc sidebar: a row Arc renamed comes across under the name the user gave it",
               ArcSidebar.flatten(sidebar.spaces[0].pinned).first?.title == "Apple Newsroom")
        assert("arc sidebar: a row nobody renamed keeps the name the page came with",
               ArcSidebar.flatten(sidebar.spaces[0].pinned).map(\.title).contains("Swift Blog"))
        assert("arc sidebar: an empty folder nothing fills is not a row",
               !sidebar.spaces[0].pinned.contains { row in
                   if case .folder(let name, _, _) = row { name == "Empty" } else { false }
               })
        assert("arc sidebar: Arc's own live folder is kept, empty, with Vane's source on it",
               sidebar.spaces[0].pinned.last == .folder(name: "Pull Requests", rows: [],
                                                        live: .github(LiveFolders.defaultQuery)))
        assert("arc sidebar: a folder with no automatic data source is an ordinary one",
               ArcSidebar.liveSource(["customInfo": [:]]) == nil
                   && ArcSidebar.liveSource(nil) == nil)
        assert("arc sidebar: each profile's favourites land under its own directory",
               sidebar.favourites["Default"]?.map(\.absoluteString) == ["https://mail.example.com/"]
                   && sidebar.favourites["Profile 1"]?.map(\.absoluteString) == ["https://calendar.example.com/"])
        assert("arc sidebar: a file that is not a sidebar is nil, not an empty one",
               ArcSidebar.parse(Data(#"{"version": 3}"#.utf8)) == nil)
        assert("arc sidebar: junk is nil rather than a crash",
               ArcSidebar.parse(Data("not json".utf8)) == nil)
        assert("arc sidebar: an out-of-gamut channel is clamped, not wrapped",
               ArcSidebar.hex(red: 1.4, green: -0.2, blue: 0.5) == "#FF0080")

        // MARK: the folder shape
        let shaped = shape(sidebar.spaces[0].pinned)
        assert("arc shape: the flat url list is the section's tabs in drawing order",
               shaped.urls.map(\.absoluteString) == ["https://apple.com/", "https://swift.org/blog"])
        assert("arc shape: a tab inside a folder is parented to it",
               shaped.pins.folder(holding: "https://swift.org/blog")?.name == "Reading")
        assert("arc shape: a tab outside every folder has no parent",
               shaped.pins.folder(holding: "https://apple.com/") == nil)
        assert("arc shape: the shape names its rows by url, the way saveShape writes them",
               shaped.pins.tabs == shaped.urls.map(\.absoluteString))
        assert("arc shape: titles are filed under the url the row is pinned at",
               shaped.titles["https://swift.org/blog"] == "Swift Blog")
        assert("arc shape: a live folder arrives with its source on it, as newLiveFolder leaves one",
               shaped.pins.entries.compactMap(\.folder).first { $0.live != nil }
                   .map { ($0.name, $0.live) }.map { $0 == "Pull Requests"
                       && $1 == .github(LiveFolders.defaultQuery) } == true)
        assert("arc shape: Today's folders are written down like Pinned's rather than flattened",
               shape(sidebar.spaces[0].today).pins
                   .folder(holding: "https://example.com/later")?.name == "Later")
        // Deeper than the sidebar can draw: `Pins.maxDepth` folders of nesting, plus one.
        var tower = ArcRow.tab(url: URL(string: "https://deep.example/")!, title: "Deep")
        for level in 0...(Pins.maxDepth + 1) { tower = .folder(name: "L\(level)", rows: [tower]) }
        let deep = shape([tower])
        assert("arc shape: nesting past what the sidebar can draw keeps the tab",
               deep.urls.map(\.absoluteString) == ["https://deep.example/"])
        assert("arc shape: …and every folder it does keep is inside the cap",
               deep.pins.entries.indices.allSatisfy {
                   deep.pins.entries[$0].folder == nil || deep.pins.depth(of: $0) <= Pins.maxDepth
               })

        // MARK: profiles
        let localState = """
        {"profile": {"last_used": "Default", "info_cache": {
          "Profile 3": {"name": "sparc dev", "is_using_default_name": false},
          "Default": {"name": "Your Chromium", "is_using_default_name": true},
          "Profile 1": {"name": "school", "is_using_default_name": false},
          "Profile 9": {"is_using_default_name": true}}}}
        """
        let profiles = ArcProfiles.parse(Data(localState.utf8))
        assert("arc profiles: every profile directory is found",
               profiles.map(\.directory) == ["Default", "Profile 1", "Profile 3", "Profile 9"])
        assert("arc profiles: Default sorts first however the file orders it",
               profiles.first?.directory == "Default")
        assert("arc profiles: a renamed profile comes across under its name",
               profiles.first { $0.directory == "Profile 1" }?.name == "school")
        assert("arc profiles: a profile with no name falls back to its directory",
               profiles.last?.name == "Profile 9")
        assert("arc profiles: a file with no info_cache yields nothing, no crash",
               ArcProfiles.parse(Data("{}".utf8)).isEmpty)
        // And which of them the import actually mints a Vane profile for.
        assert("arc profiles: a space's profile is imported even with its folder gone",
               directories(in: sidebar, listed: profiles, onDisk: { _ in false })
                   == ["Default", "Profile 1"])
        assert("arc profiles: a directory only Local State remembers, pointed at by nothing, is left",
               !directories(in: sidebar, listed: profiles, onDisk: { _ in false })
                   .contains("Profile 3"))
        assert("arc profiles: a directory with a folder is imported whether or not anything points at it",
               directories(in: sidebar, listed: profiles, onDisk: { _ in true })
                   == ["Default", "Profile 1", "Profile 3", "Profile 9"])

        // MARK: Safe Storage
        //
        // The key derivation is pinned to a known answer computed outside Swift, so a change
        // to the rounds, the salt or the PRF fails here rather than silently decrypting every
        // password to nil. Everything below it round-trips: the ciphertext is built *in the
        // check* with CommonCrypto's encrypt half, and read back by the importer's decrypt.
        let key = SafeStorage.key(secret: "peanuts")
        assert("safe storage: the key is PBKDF2-SHA1(saltysalt, 1003) and 16 bytes long",
               key.map { String(format: "%02x", $0) }.joined() == "d9a09d499b4e1b7461f28e67972c6dbd")
        assert("safe storage: a different secret is a different key",
               SafeStorage.key(secret: "arc-secret") != key)

        let secret = "correct horse battery staple"
        assert("safe storage: a v10 value round-trips",
               SafeStorage.decrypt(seal(secret, key: key), key: key) == secret)
        assert("safe storage: a value exactly one block long round-trips",
               SafeStorage.decrypt(seal("0123456789abcdef", key: key), key: key) == "0123456789abcdef")
        assert("safe storage: the wrong key decrypts to nothing rather than to noise",
               SafeStorage.decrypt(seal(secret, key: key),
                                   key: SafeStorage.key(secret: "wrong")) == nil)
        assert("safe storage: a value with no v10 prefix is left alone",
               SafeStorage.decrypt(Data("plaintext".utf8), key: key) == nil)
        assert("safe storage: an empty value is nil, not a crash",
               SafeStorage.decrypt(Data(), key: key) == nil)
        assert("safe storage: a truncated value is nil, not a crash",
               SafeStorage.decrypt(SafeStorage.prefix + Data([1, 2, 3]), key: key) == nil)

        // The newer cookie format: SHA-256 of the host key in front of the value.
        let host = ".example.com"
        let hashed = seal(secret, key: key, hostKey: host)
        assert("safe storage: a cookie carrying its host hash gives up the value alone",
               SafeStorage.decrypt(hashed, key: key, hostKey: host) == secret)
        assert("safe storage: a cookie whose host does not match keeps its 32 bytes",
               SafeStorage.decrypt(hashed, key: key, hostKey: ".other.com") != secret)
        assert("safe storage: a login value has no host prefix and none is stripped",
               SafeStorage.decrypt(seal(secret, key: key), key: key, hostKey: host) == secret)

        // MARK: what one vault gives up
        //
        // The whole password and cookie half, short of the keychain and the writes: which
        // rows open, which are Arc's own dead weight and which the key will not touch.
        var vault = Vault(directory: "Default", path: URL(fileURLWithPath: "/tmp/Arc/Default"))
        vault.logins = [
            ("https://example.com/login", "ada", seal("hunter2", key: key)),
            // Chromium writes a site you told it never to save as a login with no username.
            ("https://blocked.example/", "", Data()),
            ("not a url at all", "ada", seal("nowhere", key: key)),
            ("https://other.example/", "bob", seal("s3cret", key: SafeStorage.key(secret: "other"))),
        ]
        vault.cookies = [
            (host, "sid", "/", seal(secret, key: key, hostKey: host), 0, true),
            ("", "sid", "/", Data(), 0, false),
        ]
        let opened = open(vault, key: key)
        assert("arc vault: a login opens into a host, an account and a password",
               opened.logins.map(\.host) == ["example.com"]
                   && opened.logins.first?.password == "hunter2")
        assert("arc vault: a blocklist row, an origin with no host and a nameless cookie are "
               + "counted apart from the ones already here",
               opened.skipped == 3)
        assert("arc vault: a row sealed with another key is one that would not open",
               opened.locked == 1)
        assert("arc vault: a cookie gives up its host hash and keeps its value",
               opened.cookies.map(\.value) == [secret])

        // MARK: the favourites grid
        //
        // `write(favourites:)` is this function over the profile's own list, so the cap the
        // toast counts against is the cap `Spaces.favourites` trims the key back to.
        let held = (0..<10).compactMap { URL(string: "https://held\($0).example/") }
        let fromArc = (0..<10).compactMap { URL(string: "https://arc\($0).example/") }
        assert("arc favourites: a grid that is nearly full takes what fits and no more",
               Spaces.mergedFavourites(existing: held, perSpace: [fromArc]).count
                   == Spaces.favouritesCap)
        assert("arc favourites: the tiles already there keep their places",
               Array(Spaces.mergedFavourites(existing: held, perSpace: [fromArc]).prefix(10))
                   == held)

        // MARK: what the user is told
        //
        // Both sentences are pure functions over counts, so what the alert and the toast say
        // is provable without a panel to raise or an Arc to read.
        let scan = Scan(root: URL(fileURLWithPath: "/tmp/Arc"), sidebar: sidebar,
                        profiles: profiles, directories: ["Default"],
                        vaults: ["Default": Vault(directory: "Default",
                                                  path: URL(fileURLWithPath: "/tmp/Arc"))])
        assert("arc summary: the counts are the ones the parse actually found",
               summary(scan) == "Found 1 profile, 3 spaces, 3 pinned tabs, 0 passwords, 0 cookies.")
        var counts = Counts()
        counts.spaces = 3; counts.passwords = 235; counts.cookies = 1
        assert("arc report: only what happened is named, and one of a thing is singular",
               report(counts) == "Imported 3 spaces, 235 passwords, 1 session.")
        assert("arc report: a run with nothing to say does not claim a success",
               report(Counts()) == "Arc had nothing left to import.")
        var locked = Counts()
        locked.spaces = 1; locked.noKey = true
        assert("arc report: a refused keychain says which half was skipped",
               locked.noKey && report(locked).hasSuffix("Passwords and sessions need Arc's keychain key."))
        var wrong = Counts()
        wrong.spaces = 2; wrong.locked = 340
        assert("arc report: a key that opened nothing says so rather than reporting no passwords",
               wrong.wrongKey
                   && report(wrong).hasSuffix("nothing Arc had sealed could be read."))
        var some = Counts()
        some.passwords = 3; some.locked = 2
        assert("arc report: rows that would not open are named beside the ones that did",
               !some.wrongKey && report(some) == "Imported 3 passwords. 2 could not be read.")
        var shut = Counts()
        shut.spaces = 1; shut.unreadable = 1
        assert("arc report: a file that would not open is not reported as an empty one",
               report(shut) == "Imported 1 space. 1 file Arc still has would not open "
                   + "— Full Disk Access, most likely.")
        var kept = Counts()
        kept.spaces = 1; kept.liveFolders = 1
        assert("arc report: a live folder is one of the things the toast counts",
               report(kept) == "Imported 1 space, 1 live folder.")
        var blocked = Counts()
        blocked.passwords = 2; blocked.passwordsSkipped = 40
        assert("arc report: a blocklist row is not a failure and is not named",
               report(blocked) == "Imported 2 passwords.")

        // MARK: timestamps
        assert("chrome time: the FILETIME zero point is the unix epoch",
               chromeTime(11_644_473_600_000_000) == Date(timeIntervalSince1970: 0))
        assert("chrome time: zero is a session cookie, not a date in 1601",
               chromeTime(0) == nil)
        assert("chrome time: a real expiry lands on the right second",
               chromeTime(13_374_473_600_000_000).map { Int($0.timeIntervalSince1970) } == 1_730_000_000)
        return out
    }

    /// The encrypt half of Safe Storage, for `check()` and for nothing else: the importer
    /// only ever reads, so this lives here rather than beside `decrypt` where a future caller
    /// might think Vane is meant to write Chromium's format.
    private static func seal(_ text: String, key: Data, hostKey: String? = nil) -> Data {
        var plain = Data(text.utf8)
        if let hostKey { plain = Data(SHA256.hash(data: Data(hostKey.utf8))) + plain }
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { dst in
            plain.withUnsafeBytes { src in
                SafeStorage.iv.withUnsafeBytes { iv in
                    key.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, SafeStorage.keyLength, iv.baseAddress,
                                src.baseAddress, src.count,
                                dst.baseAddress, dst.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return Data() }
        return SafeStorage.prefix + out.prefix(written)
    }
}
