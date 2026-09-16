import CommonCrypto
import CryptoKit
import Foundation

// MARK: - What Arc writes down

/// One row of an Arc space's sidebar: a tab, or a folder holding more rows.
///
/// Arc's own file is a flat `items` array where every row names its parent and every parent
/// lists its children in order; this is that array walked back into the tree it describes,
/// which is the only shape the folder half of the import can be written against. Only
/// `http(s)` tabs survive the walk — see `ArcSidebar.rows`.
enum ArcRow: Equatable, Sendable {
    case tab(url: URL, title: String)
    indirect case folder(name: String, rows: [ArcRow])
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
    /// The order of those pairs is **not** fixed — this Mac's Arc writes unpinned first for
    /// one space and pinned first for another — so everything here looks a container up by
    /// its label and never by its index.
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

    /// The rows of one container, in the order the parent lists its children.
    ///
    /// `seen` is not defensive decoration: `childrenIds` is a plain list of ids and a file
    /// that has been synced, merged and rewritten for two years can name a parent inside its
    /// own subtree. Without it the walk never returns.
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
                // A tab's own `title` is null in every file seen; the name Arc draws is the
                // one it saved with the page.
                out.append(.tab(url: url, title: tab["savedTitle"] as? String ?? ""))
            } else if data["list"] != nil {
                // A folder. Its name is the *item's* title, not anything inside `data` —
                // `{"list": {}}` is empty on every folder.
                let kids = rows(of: id, items: items, seen: &seen)
                guard !kids.isEmpty else { continue }
                out.append(.folder(name: item["title"] as? String ?? "Folder", rows: kids))
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
            case .folder(_, let kids): flatten(kids)
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

    /// The AES key for one browser's keychain secret. Deterministic, so `check()` can pin it
    /// to a known answer without a keychain in the room.
    static func key(secret: String) -> Data {
        var out = Data(count: keyLength)
        let secret = Array(secret.utf8)
        let ok = out.withUnsafeMutableBytes { key in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret, secret.count,
                                     salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                                     key.bindMemory(to: UInt8.self).baseAddress, keyLength)
            }
        }
        return ok == kCCSuccess ? out : Data()
    }

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
                case .folder(let name, let kids):
                    // Arc nests as deep as it likes and Vane's sidebar stops at
                    // `Pins.maxDepth`. A folder past that gives up its rows to the folder it
                    // is in rather than being dropped: losing a name is a cosmetic loss,
                    // losing the tabs is not.
                    guard depth <= Pins.maxDepth else {
                        walk(kids, parent: parent, depth: depth)
                        continue
                    }
                    let folder = Folder(name: name)
                    pins.entries.append(Pins.Entry(row: .folder(folder), parent: parent))
                    walk(kids, parent: folder.id, depth: depth + 1)
                }
            }
        }
        walk(rows, parent: nil, depth: 0)
        return (pins, urls, titles)
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
        // page, and a favourites container per profile. The two spaces' `containerIDs` list
        // pinned and unpinned in opposite orders, because the real file does.
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
              "childrenIds": ["t-apple", "f-reading"],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-default"}}}}},
            "t-apple", {"id": "t-apple", "parentID": "d-pin", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://apple.com/", "savedTitle": "Apple"}}},
            "f-reading", {"id": "f-reading", "parentID": "d-pin", "title": "Reading",
              "childrenIds": ["t-swift", "t-library"], "data": {"list": {}}},
            "t-swift", {"id": "t-swift", "parentID": "f-reading", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://swift.org/blog", "savedTitle": "Swift Blog"}}},
            "t-library", {"id": "t-library", "parentID": "f-reading", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "arc://library", "savedTitle": "Library"}}},
            "d-un", {"id": "d-un", "parentID": null, "title": null, "childrenIds": ["t-today"],
              "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-default"}}}}},
            "t-today", {"id": "t-today", "parentID": "d-un", "title": null, "childrenIds": [],
              "data": {"tab": {"savedURL": "https://example.com/today", "savedTitle": "Today"}}},
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
                   == ["https://example.com/today"])
        assert("arc sidebar: a folder keeps its name and its children's order",
               sidebar.spaces[0].pinned.last == .folder(name: "Reading", rows: [
                   .tab(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog")]))
        assert("arc sidebar: a tab that is not a web page is not imported",
               !ArcSidebar.flatten(sidebar.spaces[0].pinned).contains { $0.title == "Library" })
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
