import AppKit
import SQLite3

/// One detected profile directory. `path` is the directory that holds the data files, so
/// callers never have to know a vendor's layout.
struct BrowserProfile: Sendable {
    let browser: String
    let profile: String
    let path: URL
    var hasHistory: Bool
    var hasBookmarks: Bool
}

/// Read-only browser snapshots. History/bookmarks remain atomic; supported Chromium
/// cookies have their own explicit opt-in review and best-effort verified publication.
enum BrowserImport {

    /// `nonisolated` along with `query` and `guardReadable` below: those three are a file
    /// copy, a `sqlite3_step` loop and the error it can fail with, and `ArcImport` runs them
    /// off the main actor so a heavy profile does not freeze the window.
    nonisolated struct Failure: LocalizedError {
        enum Kind: Sendable, Equatable { case accessDenied, busy, unavailable }
        let errorDescription: String?
        let kind: Kind
        init(_ m: String, kind: Kind = .unavailable) { errorDescription = m; self.kind = kind }
    }

    // MARK: Detection

    static var sourceHome: URL { LegacyData.realHome }

    /// Vendor directory per browser. Opera and Arc are the odd ones — Opera keeps its data
    /// in the vendor directory itself, Arc hides its profiles one level down in "User Data".
    private static let chromiumVendors: [(String, String)] = [
        ("Chrome",   "Google/Chrome"),
        ("Chromium", "Chromium"),
        ("Edge",     "Microsoft Edge"),
        ("Brave",    "BraveSoftware/Brave-Browser"),
        ("Vivaldi",  "Vivaldi"),
        ("Opera",    "com.operasoftware.Opera"),
        ("Arc",      "Arc/User Data"),
    ]

    static func detect() -> [BrowserProfile] { detect(home: sourceHome) }

    struct Discovery: Sendable {
        var profiles: [BrowserProfile] = []
        var unavailable: [String] = []
    }

    static func detect(home: URL) -> [BrowserProfile] { discover(home: home).profiles }

    static func discover(home: URL, installedBrowsers: Set<String> = []) -> Discovery {
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let fm = FileManager.default
        var discovery = Discovery()
        func readable(_ root: URL, browser: String) -> Bool {
            guard fm.fileExists(atPath: root.path) else { return false }
            do { _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil); return true }
            catch {
                // Helpers can leave support folders for browsers never installed.
                // A denied path is not evidence of an installation or a library.
                if installedBrowsers.contains(browser), accessDenied(error) {
                    discovery.unavailable.append(browser)
                }
                return false
            }
        }

        for (name, vendor) in chromiumVendors {
            let root = appSupport.appendingPathComponent(vendor)
            guard readable(root, browser: name) else { continue }
            discovery.profiles += chromiumProfiles(browser: name, root: root)
        }

        for (browser, vendor) in [("Firefox", "Firefox/Profiles"), ("Zen", "zen/Profiles")] {
            let firefox = appSupport.appendingPathComponent(vendor)
            guard readable(firefox, browser: browser) else { continue }
            for dir in (try? fm.contentsOfDirectory(at: firefox, includingPropertiesForKeys: nil)) ?? []
            where fm.fileExists(atPath: dir.appendingPathComponent("places.sqlite").path) {
                discovery.profiles.append(BrowserProfile(browser: browser, profile: dir.lastPathComponent,
                                      path: dir, hasHistory: true, hasBookmarks: true))
            }
        }
        let orion = appSupport.appendingPathComponent("Orion")
        if readable(orion, browser: "Orion") {
            for dir in (try? fm.contentsOfDirectory(at: orion, includingPropertiesForKeys: nil)) ?? [] {
                let history = fm.fileExists(atPath: dir.appendingPathComponent("history").path)
                let bookmarks = fm.fileExists(atPath: dir.appendingPathComponent("favourites.plist").path)
                if history || bookmarks {
                    discovery.profiles.append(BrowserProfile(browser: "Orion", profile: dir.lastPathComponent,
                        path: dir, hasHistory: history, hasBookmarks: bookmarks))
                }
            }
        }

        // Safari is listed on existence alone: TCC lets us stat these files but not open
        // them, so whether they are actually readable only comes out at import time.
        let safari = home.appendingPathComponent("Library/Safari")
        let hasHistory = fm.fileExists(atPath: safari.appendingPathComponent("History.db").path)
        let hasMarks = fm.fileExists(atPath: safari.appendingPathComponent("Bookmarks.plist").path)
        if hasHistory || hasMarks {
            discovery.profiles.append(BrowserProfile(browser: "Safari", profile: "Default", path: safari,
                                      hasHistory: hasHistory, hasBookmarks: hasMarks))
        }
        return discovery
    }

    nonisolated static func accessDenied(_ error: any Error) -> Bool {
        if let failure = error as? Failure { return failure.kind == .accessDenied }
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError { return true }
        if e.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(e.code) { return true }
        return (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { accessDenied($0) } ?? false
    }

    static func chromiumProfiles(browser: String, root: URL) -> [BrowserProfile] {
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // Opera has a profile directly at its vendor root. Its Network/Cookies file
        // must not turn Network into a fictitious profile and hide root History.
        if let bare = chromiumProfile(browser, root, "Default") { return [bare] }
        return kids.filter { $0.lastPathComponent != "Network" }
            .compactMap { chromiumProfile(browser, $0, $0.lastPathComponent) }
            .sorted { $0.profile < $1.profile }
    }

    private static func chromiumProfile(_ browser: String, _ dir: URL, _ profile: String) -> BrowserProfile? {
        let fm = FileManager.default
        let h = fm.fileExists(atPath: dir.appendingPathComponent("History").path)
        let b = fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks").path)
        guard h || b || ChromiumCookies.file(at: dir) != nil else { return nil }
        return BrowserProfile(browser: browser, profile: profile, path: dir,
                              hasHistory: h, hasBookmarks: b)
    }

    // MARK: Import

    /// `profileID` is the Vane profile the rows land in. It defaults to the active one,
    /// which is what every existing caller means and what this used to do unconditionally
    /// through `Store.shared`. Import from Arc is the first caller that brings several
    /// browser profiles across at once, and each has to reach its own `Store` — Arc's work
    /// profile's history in Vane's work profile, not all of it in whichever profile happened
    /// to be on screen.
    struct Source: Sendable {
        let visits: [(url: URL, title: String, at: Date)]
        let bookmarks: [BookmarkImportItem]
    }

    static func readSource(from p: BrowserProfile) throws -> Source {
        var visits: [(url: String, title: String, at: Date)] = []
        var marks: [NativeBookmark] = []

        switch family(of: p) {
        case .orion:
            if p.hasHistory {
                let file = p.path.appendingPathComponent("history")
                try query(file, """
                    SELECT i.URL, i.TITLE, strftime('%s', v.VISIT_TIME) FROM history_items i
                    JOIN visits v ON v.HISTORY_ITEM_ID = i.ID
                    WHERE strftime('%s', v.VISIT_TIME) IS NOT NULL ORDER BY v.VISIT_TIME DESC
                    """) { visits.append((text($0, 0), text($0, 1), Date(timeIntervalSince1970: sqlite3_column_double($0, 2)))) }
            }
            if p.hasBookmarks { marks = try orionBookmarks(p.path.appendingPathComponent("favourites.plist")) }
        case .safari:
            if p.hasBookmarks { marks = try safariBookmarksFile(p.path.appendingPathComponent("Bookmarks.plist")) }
            if p.hasHistory { visits = try safariHistory(p.path.appendingPathComponent("History.db")) }

        case .firefox:
            let places = p.path.appendingPathComponent("places.sqlite")
            if p.hasHistory {
                try snapshot(places) { db in
                    let hasVisits = try hasTable("moz_historyvisits", in: db, file: places)
                    let sql = hasVisits ? """
                        SELECT p.url, p.title, v.visit_date FROM moz_historyvisits v
                        JOIN moz_places p ON p.id = v.place_id ORDER BY v.visit_date DESC
                        """ : """
                        SELECT url, title, last_visit_date FROM moz_places
                        WHERE last_visit_date IS NOT NULL AND visit_count > 0 ORDER BY last_visit_date DESC
                        """
                    try query(db: db, file: places, sql: sql) {
                        visits.append((text($0, 0), text($0, 1), firefoxTime(sqlite3_column_int64($0, 2))))
                    }
                }
            }
            if p.hasBookmarks {
                marks = try firefoxBookmarks(places)
            }

        case .chromium:
            if p.hasHistory {
                let file = p.path.appendingPathComponent("History")
                try snapshot(file) { db in
                    let hasVisits = try hasTable("visits", in: db, file: file)
                    let sql = hasVisits ? """
                        SELECT u.url, u.title, v.visit_time FROM visits v
                        JOIN urls u ON u.id = v.url WHERE v.visit_time > 0 ORDER BY v.visit_time DESC
                        """ : """
                        SELECT url, title, last_visit_time FROM urls
                        WHERE last_visit_time > 0 ORDER BY last_visit_time DESC
                        """
                    try query(db: db, file: file, sql: sql) {
                        visits.append((text($0, 0), text($0, 1), chromiumTime(sqlite3_column_int64($0, 2))))
                    }
                }
            }
            if p.hasBookmarks {
                marks = try checkedChromiumBookmarks(read(p.path.appendingPathComponent("Bookmarks")))
            }
        }

        let history = visits.compactMap { visit -> (url: URL, title: String, at: Date)? in
            guard let url = URL(string: visit.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false else { return nil }
            return (url, visit.title, visit.at)
        }
        let bookmarks = marks.compactMap { mark -> BookmarkImportItem? in
            guard let url = URL(string: mark.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false else { return nil }
            return BookmarkImportItem(url: url, title: mark.title, folder: mark.folder, at: mark.at)
        }
        return Source(visits: history, bookmarks: bookmarks)
    }

    @MainActor static func importAll(from p: BrowserProfile,
                                     profileID: UUID = ProfileManager.activeProfileID) throws
        -> (history: Int, bookmarks: Int) {
        let source = try readSource(from: p)
        let store = Store.store(for: profileID)
        guard let result = store.importBrowserData(visits: source.visits, bookmarks: source.bookmarks) else {
            throw Failure("Could not save imported history and bookmarks. " + (store.lastHistoryError ?? "Try again."))
        }
        return (result.history, result.bookmarks.imported)
    }

    @MainActor static func importAllAsync(from p: BrowserProfile, profileID: UUID,
                                           admission: ImportOperations.Admission? = nil) async throws
        -> (history: Int, bookmarks: Int) {
        try await ImportOperations.run(admission) { accepted in
            let destination = Store.store(for: profileID)
            let source = try await ImportWork.run { try readSource(from: p) }
            try Task.checkCancellation()
            let result = try await destination.importBrowserDataAsync(visits: source.visits, bookmarks: source.bookmarks, admission: accepted)
            return (result.history, result.bookmarks.imported)
        }
    }

    @MainActor static func importSnapshot(_ source: Source, profileID: UUID,
        validateDestination: @escaping @MainActor () -> Bool) async throws -> (history: Int, bookmarks: Int) {
        try await ImportOperations.run { admission in
            guard validateDestination() else { throw CancellationError() }
            let result = try await Store.store(for: profileID).importBrowserDataAsync(
                visits: source.visits, bookmarks: source.bookmarks, admission: admission)
            return (result.history, result.bookmarks.imported)
        }
    }

    struct ReviewedResult {
        var history = 0
        var bookmarks = 0
        var sessions: ChromiumCookies.Report?
        var sessionsIssue: String?
    }

    /// One lifecycle admission covers the source worker, atomic library transaction and
    /// optional cookie publication. Cookies are a separately reported best-effort category.
    @MainActor static func importReviewed(from source: BrowserProfile, profileID: UUID, includeSessions: Bool = false,
        validateDestination: @escaping @MainActor () -> Bool,
        readKey: @escaping @Sendable (ChromiumCookies.Identity) -> Data? = { ChromiumCookies.key(identity: $0) },
        cookieAccess: (@MainActor () -> ChromiumCookies.Access)? = nil) async throws -> ReviewedResult {
        try await ImportOperations.run { admission in
            guard profileID != Profile.incognito.id, validateDestination() else { throw CancellationError() }
            let data = try await ImportWork.run { try readSource(from: source) }
            try Task.checkCancellation()
            guard validateDestination() else { throw CancellationError() }
            let destination = Store.store(for: profileID)
            let committed = try await destination.importBrowserDataAsync(visits: data.visits, bookmarks: data.bookmarks, admission: admission)
            var result = ReviewedResult(history: committed.history, bookmarks: committed.bookmarks.imported)
            guard includeSessions else { return result }
            guard let identity = ChromiumCookies.identity(browser: source.browser) else {
                result.sessionsIssue = "Session import is not supported for this source browser."
                return result
            }
            var rowCount = 0
            do {
                let read = try await ImportWork.run {
                    let snapshot = try ChromiumCookies.read(at: source.path)
                    let needsKey = snapshot.rows.contains {
                        ChromiumCookies.cookie($0, value: "") != nil && $0.value.starts(with: SafeStorage.prefix)
                    }
                    return (snapshot, needsKey)
                }
                let snapshot = read.0
                rowCount = snapshot.rows.count
                guard !Task.isCancelled, validateDestination(), !destination.isRetired else {
                    result.sessions = .init(skipped: rowCount, stopped: true); return result
                }
                // No Keychain prompt for plaintext-only or unsupported encrypted rows.
                let needsKey = read.1
                let key = needsKey ? try await ImportWork.run { readKey(identity) } : nil
                guard !Task.isCancelled, validateDestination(), !destination.isRetired else {
                    result.sessions = .init(skipped: rowCount, stopped: true); return result
                }
                let opened = try await ImportWork.run { ChromiumCookies.open(snapshot, key: key) }
                guard !Task.isCancelled, validateDestination(), !destination.isRetired else {
                    result.sessions = .init(skipped: rowCount, stopped: true); return result
                }
                guard !opened.cookies.isEmpty else {
                    result.sessions = .init(skipped: opened.skipped, failed: opened.failed,
                        unsupportedEncryption: opened.unsupportedEncryption)
                    if needsKey && key == nil { result.sessionsIssue = "The source browser's Safe Storage key was unavailable. Encrypted cookies could not be decrypted." }
                    return result
                }
                let access = cookieAccess?() ?? ChromiumCookies.Access(store: ProfileManager.dataStore(for: profileID).httpCookieStore)
                var report = await ChromiumCookies.publish(opened.cookies, validate: {
                    validateDestination() && !destination.isRetired && ImportOperations.isActive(admission)
                }, fetch: access.fetch, set: access.set, remove: access.remove)
                report.skipped += opened.skipped
                report.failed += opened.failed
                report.unsupportedEncryption = opened.unsupportedEncryption
                result.sessions = report
                if needsKey && key == nil {
                    result.sessionsIssue = "The source browser's Safe Storage key was unavailable. Encrypted cookies could not be decrypted."
                }
            } catch is CancellationError {
                result.sessions = .init(skipped: rowCount, stopped: true)
            } catch {
                result.sessionsIssue = "Cookies were not imported. " + error.localizedDescription
            }
            return result
        }
    }

    /// A folder the user picked in the panel. Its family is sniffed from what is inside it,
    /// since the path tells us nothing reliable.
    @MainActor private static func pickProfileFolder() -> BrowserProfile? {
        let panel = NSOpenPanel()
        panel.title = "Choose a browser profile folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }

        let fm = FileManager.default
        let history = fm.fileExists(atPath: folder.appendingPathComponent("History").path)
        let places = fm.fileExists(atPath: folder.appendingPathComponent("places.sqlite").path)
        let marks = fm.fileExists(atPath: folder.appendingPathComponent("Bookmarks").path)
        let cookies = ChromiumCookies.file(at: folder) != nil
        guard history || places || marks || cookies else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "That folder doesn't look like a browser profile."
            a.informativeText = "Vane looked for a History, Bookmarks or places.sqlite file "
                + "or Cookies file in \(folder.lastPathComponent) and found none."
            a.runModal()
            return nil
        }
        var browser = places ? "Firefox" : "Unidentified Chromium"
        if !places && cookies {
            // A powerbox-selected folder says nothing about its vendor. The user must
            // explicitly choose the matching identity before any foreign Keychain read.
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
            popup.addItems(withTitles: ["History and bookmarks only"] + ChromiumCookies.browsers)
            let identity = NSAlert()
            identity.messageText = "Which browser wrote this profile?"
            identity.informativeText = "Choose the source browser to make optional session import available. "
                + "Vane will use only that browser's Safe Storage identity."
            identity.accessoryView = popup
            identity.addButton(withTitle: "Use Profile")
            identity.addButton(withTitle: "Cancel")
            guard identity.runModal() == .alertFirstButtonReturn else { return nil }
            if popup.indexOfSelectedItem > 0 { browser = ChromiumCookies.browsers[popup.indexOfSelectedItem - 1] }
        }
        return BrowserProfile(browser: browser, profile: folder.lastPathComponent, path: folder,
                              hasHistory: history || places, hasBookmarks: marks || places)
    }

    private enum Family { case chromium, firefox, safari, orion }

    private static func family(of p: BrowserProfile) -> Family {
        if p.browser == "Safari" { return .safari }
        if p.browser == "Orion" { return .orion }
        if FileManager.default.fileExists(atPath: p.path.appendingPathComponent("places.sqlite").path) {
            return .firefox
        }
        return .chromium
    }

    private static func hasTable(_ name: String, in db: OpaquePointer, file: URL) throws -> Bool {
        var found = false
        // Names here are fixed schema constants, never user input.
        try query(db: db, file: file, sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") { _ in found = true }
        return found
    }

    // MARK: Timestamps

    /// Chromium counts microseconds from 1601-01-01 UTC — the Windows FILETIME epoch, which
    /// is 11644473600 seconds before the Unix one.
    ///
    /// Shared with `ArcImport.chromeTime`; the parser itself has no UI isolation.
    /// the sake of its panels and its alerts, and one line of arithmetic has no business
    /// being the reason a second copy of the epoch constant exists.
    nonisolated static func chromiumTime(_ micro: Int64) -> Date {
        // Modern Chromium microseconds exceed Double's exact integer range. Shift the
        // whole seconds before conversion so adjacent visits retain their precision.
        let seconds = micro / 1_000_000 - 11_644_473_600
        let fraction = Double(micro % 1_000_000) / 1_000_000
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Firefox counts microseconds from the Unix epoch.
    static func firefoxTime(_ micro: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micro) / 1_000_000)
    }

    /// Safari counts *seconds* from 2001-01-01 UTC — the Core Data reference date.
    static func safariTime(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: Bookmark parsing

    private struct NativeBookmark {
        var url: String
        var title: String
        var folder: String?
        var at: Date?
    }

    private static func folderPath(_ parts: [String]) -> String? {
        parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private static func bookmarkDate(_ date: Date) -> Date? {
        let epoch = date.timeIntervalSince1970
        return epoch.isFinite && epoch >= -62_135_596_800 && epoch < 253_402_300_800 ? date : nil
    }

    private static func firefoxBookmarks(_ file: URL) throws -> [NativeBookmark] {
        try snapshot(file) { db in
            var columns = Set<String>()
            try query(db: db, file: file, sql: "PRAGMA table_info(moz_bookmarks)") { columns.insert(text($0, 1)) }
            let dateColumn = columns.contains("dateAdded") ? "b.dateAdded" : "NULL"
            guard columns.isSuperset(of: ["id", "parent", "position"]) else {
                var out: [NativeBookmark] = []
                try query(db: db, file: file, sql: """
                    SELECT p.url, b.title, \(dateColumn) FROM moz_bookmarks b
                    JOIN moz_places p ON p.id = b.fk WHERE b.type = 1
                    """) { row in
                    let micro = sqlite3_column_int64(row, 2)
                    out.append(NativeBookmark(url: text(row, 0), title: text(row, 1), folder: nil,
                                              at: micro > 0 ? bookmarkDate(firefoxTime(micro)) : nil))
                }
                return out
            }
            struct Node {
                var id: Int64, parent: Int64, type: Int
                var title: String, url: String, guid: String
                var at: Date?
            }
            var nodes: [Int64: Node] = [:], ordered: [Int64] = []
            let guidColumn = columns.contains("guid") ? "b.guid" : "''"
            try query(db: db, file: file, sql: """
                SELECT b.id, b.parent, b.type, b.title, p.url, \(dateColumn), \(guidColumn)
                FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.position, b.id
                """) { row in
                let id = sqlite3_column_int64(row, 0), micro = sqlite3_column_int64(row, 5)
                nodes[id] = Node(id: id, parent: sqlite3_column_int64(row, 1), type: Int(sqlite3_column_int(row, 2)),
                    title: text(row, 3), url: text(row, 4), guid: text(row, 6),
                    at: micro > 0 ? bookmarkDate(firefoxTime(micro)) : nil)
                ordered.append(id)
            }
            let containers: Set<String> = ["root________", "menu________", "toolbar_____", "unfiled_____", "mobile______"]
            var marks: [Int64: NativeBookmark] = [:]
            for id in ordered {
                guard let node = nodes[id], node.type == 1 else { continue }
                var parent = node.parent, seen: Set<Int64> = [id], path: [String] = []
                while parent != 0 {
                    guard seen.insert(parent).inserted, seen.count <= 256,
                          let folder = nodes[parent], folder.type == 2 else {
                        throw Failure("The Firefox bookmark folder tree is damaged.")
                    }
                    let name = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if folder.parent != 0 && !containers.contains(folder.guid) && !name.isEmpty { path.append(name) }
                    parent = folder.parent
                }
                marks[id] = NativeBookmark(url: node.url, title: node.title, folder: folderPath(path.reversed()), at: node.at)
            }
            // Positions belong to siblings, not to the whole database. Preserve
            // depth-first source order so the existing first-URL-wins policy keeps
            // the first bookmark's title, folder and date across different folders.
            let children = Dictionary(grouping: ordered) { nodes[$0]!.parent }
            var out: [NativeBookmark] = []
            func walk(_ id: Int64, depth: Int) throws {
                guard depth <= 256 else { throw Failure("The Firefox bookmark folder tree is too deeply nested.") }
                if let mark = marks[id] { out.append(mark) }
                if nodes[id]?.type == 2 {
                    for child in children[id] ?? [] { try walk(child, depth: depth + 1) }
                }
            }
            for root in children[0] ?? [] { try walk(root, depth: 0) }
            return out
        }
    }

    /// Chromium's Bookmarks file: a tree under `roots`, where only `type == "url"` nodes are
    /// real bookmarks. Folders carry the same shape, so keying off the presence of a `url`
    /// field instead of the type would import folders too.
    static func chromiumBookmarks(_ data: Data) -> [(url: String, title: String)] {
        (try? checkedChromiumBookmarks(data).map { ($0.url, $0.title) }) ?? []
    }

    private static func checkedChromiumBookmarks(_ data: Data) throws -> [NativeBookmark] {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = top["roots"] as? [String: Any] else {
            throw Failure("The Bookmarks file has no supported bookmark roots.")
        }
        var out: [NativeBookmark] = []
        func walk(_ node: Any, path: [String], depth: Int) throws {
            guard depth <= 256 else { throw Failure("The bookmark folder tree is too deeply nested.") }
            guard let n = node as? [String: Any], let type = n["type"] as? String else {
                throw Failure("The Bookmarks file contains a malformed node.")
            }
            switch type {
            case "url":
                guard let url = n["url"] as? String else { throw Failure("A bookmark is missing its URL.") }
                if let name = n["name"], !(name is String) { throw Failure("A bookmark has a malformed title.") }
                let micro = (n["date_added"] as? String).flatMap(Int64.init)
                out.append(NativeBookmark(url: url, title: n["name"] as? String ?? "",
                    folder: folderPath(path), at: micro.flatMap { $0 > 0 ? bookmarkDate(chromiumTime($0)) : nil }))
            case "folder":
                if let name = n["name"], !(name is String) { throw Failure("A bookmark folder has a malformed title.") }
            case "separator": return
            default: throw Failure("The Bookmarks file contains an unsupported node type.")
            }
            if let children = n["children"] {
                guard let children = children as? [Any] else { throw Failure("A bookmark folder has malformed children.") }
                let name = (n["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let next = depth > 0 && type == "folder" && !name.isEmpty ? path + [name] : path
                for child in children { try walk(child, path: next, depth: depth + 1) }
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] { try walk(node, path: [], depth: 0) }
        }
        return out
    }

    /// Safari proxies are unsupported, while damaged leaves/list structures fail closed.
    static func safariBookmarks(_ node: Any?) -> [(url: String, title: String)] {
        (try? checkedSafariBookmarks(node).map { ($0.url, $0.title) }) ?? []
    }

    private static func checkedSafariBookmarks(_ node: Any?, path: [String] = [], depth: Int = 0) throws -> [NativeBookmark] {
        guard depth <= 256 else { throw Failure("The bookmark folder tree is too deeply nested.") }
        guard let n = node as? [String: Any], let type = n["WebBookmarkType"] as? String else {
            throw Failure("The bookmarks plist contains a malformed node.")
        }
        switch type {
        case "WebBookmarkTypeLeaf":
            guard let url = n["URLString"] as? String else { throw Failure("A bookmark is missing its URL.") }
            var title = ""
            if let raw = n["URIDictionary"] {
                guard let dictionary = raw as? [String: Any] else { throw Failure("A bookmark has malformed title metadata.") }
                if let rawTitle = dictionary["title"] {
                    guard let text = rawTitle as? String else { throw Failure("A bookmark has a malformed title.") }
                    title = text
                }
            }
            return [NativeBookmark(url: url, title: title, folder: folderPath(path), at: nil)]
        case "WebBookmarkTypeProxy": return []
        case "WebBookmarkTypeList":
            guard let raw = n["Children"] else { return [] }
            guard let children = raw as? [Any] else { throw Failure("A bookmark folder has malformed children.") }
            if let title = n["Title"], !(title is String) { throw Failure("A bookmark folder has a malformed title.") }
            let title = (n["Title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let next = depth > 0 && !title.isEmpty ? path + [title] : path
            return try children.flatMap { try checkedSafariBookmarks($0, path: next, depth: depth + 1) }
        default: throw Failure("The bookmarks plist contains an unsupported node type.")
        }
    }

    private static func safariBookmarksFile(_ file: URL) throws -> [NativeBookmark] {
        try checkedSafariBookmarks(PropertyListSerialization.propertyList(from: try read(file), format: nil))
    }

    private static func orionBookmarks(_ file: URL) throws -> [NativeBookmark] {
        guard let nodes = try PropertyListSerialization.propertyList(from: read(file), format: nil) as? [String: [String: Any]]
        else { throw Failure("Orion bookmarks are not a readable library.") }
        for node in nodes.values where node["parentId"] != nil && !(node["parentId"] is String) {
            throw Failure("An Orion bookmark has malformed folder metadata.")
        }
        let children = Dictionary(grouping: nodes.keys.filter { nodes[$0]?["parentId"] is String }) {
            nodes[$0]!["parentId"] as! String
        }
        func ordered(_ ids: [String]) -> [String] {
            ids.sorted {
                let a = (nodes[$0]?["index"] as? NSNumber)?.intValue ?? 0
                let b = (nodes[$1]?["index"] as? NSNumber)?.intValue ?? 0
                return a == b ? $0 < $1 : a < b
            }
        }
        var seen: Set<String> = []
        func walk(_ id: String, path: [String], depth: Int) throws -> [NativeBookmark] {
            guard depth <= 256, seen.insert(id).inserted, let node = nodes[id] else {
                throw Failure("The Orion bookmark folder tree is damaged.")
            }
            var out: [NativeBookmark] = []
            if let raw = node["url"] {
                guard let url = raw as? String, let title = node["title"] as? String else {
                    throw Failure("An Orion bookmark has malformed metadata.")
                }
                out.append(NativeBookmark(url: url, title: title, folder: folderPath(path), at: nil))
            }
            let title = node["title"] as? String ?? ""
            let next = depth > 0 && node["url"] == nil && !title.isEmpty ? path + [title] : path
            for child in ordered(children[id] ?? []) { out += try walk(child, path: next, depth: depth + 1) }
            return out
        }
        var out: [NativeBookmark] = []
        for root in ordered(nodes.keys.filter { nodes[$0]?["parentId"] == nil }) {
            out += try walk(root, path: [], depth: 0)
        }
        guard seen.count == nodes.count else { throw Failure("The Orion bookmark folder tree is damaged.") }
        return out
    }

    /// Safari stores a title on each visit, so retain each visit and its own title.
    private static func safariHistory(_ file: URL) throws -> [(url: String, title: String, at: Date)] {
        var out: [(url: String, title: String, at: Date)] = []
        try query(file, """
            SELECT i.url, v.title, v.visit_time FROM history_items i
            JOIN history_visits v ON v.history_item = i.id
            ORDER BY v.visit_time DESC
            """) { out.append((text($0, 0), text($0, 1), safariTime(sqlite3_column_double($0, 2)))) }
        return out
    }

    // MARK: File access

    private static func read(_ file: URL) throws -> Data {
        try guardReadable(file)
        return try Data(contentsOf: file)
    }

    /// Full Disk Access is the usual reason a file that exists cannot be opened; TCC lets
    /// stat through and denies open, so `isReadableFile` is what actually distinguishes it.
    nonisolated private static func guardReadable(_ file: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else {
            throw Failure("\(file.lastPathComponent) is not there.")
        }
        guard fm.isReadableFile(atPath: file.path) else {
            throw Failure("macOS is blocking access to \(file.lastPathComponent).", kind: .accessDenied)
        }
    }

    /// SQLite's backup API makes a consistent snapshot, including committed WAL rows,
    /// while the source browser is running. The source connection is read-only and the
    /// snapshot lives in memory, so no credential database is copied to temporary files.
    nonisolated static func query(_ file: URL, _ sql: String, _ row: (OpaquePointer) -> Void) throws {
        try snapshot(file) { db in try query(db: db, file: file, sql: sql, row) }
    }

    nonisolated static func snapshot<Value>(_ file: URL, _ read: (OpaquePointer) throws -> Value) throws -> Value {
        try guardReadable(file)
        var source: OpaquePointer?
        defer { sqlite3_close(source) }
        let opened = sqlite3_open_v2(file.path, &source, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK else {
            throw snapshotFailure(file, code: opened)
        }
        sqlite3_busy_timeout(source, 1_000)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(":memory:", &db) == SQLITE_OK,
              let backup = sqlite3_backup_init(db, "main", source, "main") else {
            throw Failure("Could not snapshot \(file.lastPathComponent).")
        }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else {
            let code = copied == SQLITE_DONE ? finished : copied
            // A source failure can leave the destination message as "not an error".
            throw snapshotFailure(file, code: code)
        }
        return try read(db!)
    }

    nonisolated static func snapshotFailure(_ file: URL, code: Int32) -> Failure {
        // READONLY/CANTOPEN can mean WAL recovery or missing shared-memory files,
        // not a live lock or a privacy denial. Only actual locking codes say busy.
        let busy = [SQLITE_BUSY, SQLITE_LOCKED].contains(code & 0xff)
        return Failure("Could not read \(file.lastPathComponent) consistently (SQLite \(code): \(String(cString: sqlite3_errstr(code)))).",
                       kind: busy ? .busy : .unavailable)
    }

    nonisolated static func query(db: OpaquePointer, file: URL, sql: String,
                                 _ row: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw Failure("\(file.lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
        }
        var status = sqlite3_step(st)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            row(st!)
            status = sqlite3_step(st)
        }
        guard status == SQLITE_DONE else {
            throw Failure("Could not finish reading \(file.lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func text(_ st: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }

    @MainActor struct SessionReview {
        let option = NSButton(checkboxWithTitle: "Also copy cookies / sessions", target: nil, action: nil)
        var includeSessions: Bool { option.isEnabled && option.state == .on }
        init(source: BrowserProfile) {
            option.state = .off
            option.isEnabled = ChromiumCookies.identity(browser: source.browser) != nil
                && ChromiumCookies.file(at: source.path) != nil
            option.toolTip = option.isEnabled
                ? "Optional. macOS may ask to read this browser's Safe Storage key. Existing Vane cookies are kept."
                : "Session import requires a supported Chromium browser and its cookie database."
        }
    }

    // MARK: UI

    @MainActor static func chooseAndImport(browser: String? = nil) {
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                detect().filter { browser == nil || $0.browser == browser }
            }.value
            chooseAndImport(found: found)
        }
    }

    @MainActor private static func chooseAndImport(found: [BrowserProfile]) {
        guard !found.isEmpty else {
            let a = NSAlert()
            a.messageText = "No browser data is available to import."
            a.informativeText = "Vane checks supported browsers automatically. If macOS protects a browser’s data, allow access in Privacy & Security and try again."
            a.addButton(withTitle: "OK")
            a.runModal()
            return
        }

        // ponytail: NSAlert plus a popup, not a SwiftUI sheet. This runs once per machine.
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for p in found {
            var parts: [String] = []
            if p.hasHistory { parts.append("history") }
            if p.hasBookmarks { parts.append("bookmarks") }
            if ChromiumCookies.file(at: p.path) != nil { parts.append("optional sessions") }
            popup.addItem(withTitle: "\(p.browser) — \(p.profile) (\(parts.joined(separator: " + ")))")
        }

        let alert = NSAlert()
        alert.messageText = "Import from another browser"
        alert.informativeText = "History and bookmarks are copied into Vane. "
            + "Nothing in the other browser is changed."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        report(importing: found[max(0, popup.indexOfSelectedItem)])
    }

    /// Shared by detected and explicitly identified folder imports. The checkbox starts
    /// off on every review; only this reviewed choice can authorize Safe Storage access.
    @MainActor private static func report(importing chosen: BrowserProfile) {
        let owner = Windows.current
        let profileID = owner?.profileID ?? ProfileManager.activeProfileID
        guard owner?.isPrivate != true, profileID != Profile.incognito.id,
              let profile = ProfileManager.shared.profiles.first(where: { $0.id == profileID }) else {
            let refused = NSAlert()
            refused.messageText = "Choose a regular browsing profile before importing."
            refused.runModal()
            return
        }
        let scoped = chosen.path.startAccessingSecurityScopedResource()
        let review = SessionReview(source: chosen)
        let alert = NSAlert()
        alert.messageText = "Import from \(chosen.browser) — \(chosen.profile)"
        alert.informativeText = "Destination: \(profile.name). History and bookmarks are copied together. "
            + "Existing Vane cookies are kept. Optional cookies may carry sessions, but do not guarantee a completed sign-in; "
            + "site storage, passkeys and device-bound credentials are not copied. "
            + "Unsupported encryption, expired and partitioned cookies are skipped."
        alert.accessoryView = review.option
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if scoped { chosen.path.stopAccessingSecurityScopedResource() }
            return
        }
        let includeSessions = review.includeSessions
        let hadOwner = owner != nil
        let validate: @MainActor () -> Bool = { [weak owner] in
            ChromiumCookies.destinationAllowed(profileID: profileID, currentProfileID: ProfileManager.activeProfileID,
                isPrivate: owner?.isPrivate == true || Windows.current?.isPrivate == true,
                profiles: ProfileManager.shared.profiles.map(\.id))
                && (!hadOwner || (owner?.profileID == profileID && owner?.window != nil))
        }
        let progress = ImportProgress()
        progress.task = Task {
            defer { if scoped { chosen.path.stopAccessingSecurityScopedResource() } }
            let done = NSAlert()
            do {
                let result = try await importReviewed(from: chosen, profileID: profileID,
                    includeSessions: includeSessions, validateDestination: validate)
                done.messageText = "Imported \(result.history) history entries and \(result.bookmarks) bookmarks from \(chosen.browser)."
                var details: [String] = []
                if let sessions = result.sessions {
                    details.append("Cookies: \(sessions.imported) imported, \(sessions.skipped) skipped, \(sessions.failed) failed.")
                    if sessions.unsupportedEncryption > 0 {
                        details.append("\(sessions.unsupportedEncryption) cookies used unsupported encryption (only macOS v10 is supported).")
                    }
                    if sessions.stopped { details.append("Session import stopped. Completed writes were kept; remaining cookies were skipped.") }
                    if sessions.failed > 0 { done.alertStyle = .warning }
                }
                if let issue = result.sessionsIssue { details.append(issue); done.alertStyle = .warning }
                if includeSessions { details.append("Cookies do not guarantee sign-in. Some sites require signing in again.") }
                done.informativeText = details.joined(separator: "\n\n")
            } catch is CancellationError {
                done.messageText = "Import stopped."
                done.informativeText = "The destination changed or the import was cancelled. Completed changes were kept."
            } catch {
                done.alertStyle = .warning
                done.messageText = "Could not import from \(chosen.browser)."
                done.informativeText = error.localizedDescription
            }
            progress.close()
            done.runModal()
            rebuild()
            BookmarkManager.refresh(profileID: profileID)
        }
        progress.show(in: owner?.window)
    }

    @MainActor private final class ImportProgress {
        let alert = NSAlert()
        var task: Task<Void, Never>?
        var finishing = false
        func show(in window: NSWindow?) {
            guard let window else { return }
            alert.messageText = "Importing browser data…"
            alert.informativeText = "Cancel keeps completed history/bookmark batches and verified cookies."
            alert.addButton(withTitle: "Cancel Import")
            alert.beginSheetModal(for: window) { [self] _ in
                if !finishing { task?.cancel() }
            }
        }
        func close() {
            finishing = true
            if let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
            task = nil
        }
    }

    // MARK: Offline checks

    /// Pure-logic assertions: epoch maths and tree walking, on fixtures, with no installed
    /// browser required. The filesystem half is covered by actually running the import.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []

        out.append(("chromium: the FILETIME zero point maps to the unix epoch",
                    chromiumTime(11_644_473_600_000_000) == Date(timeIntervalSince1970: 0)))
        // A real date_added lifted out of a Chrome Bookmarks file: 2021-04-30 09:47:33 UTC.
        out.append(("chromium: a real timestamp lands on the right second",
                    Int(chromiumTime(13_264_249_653_682_696).timeIntervalSince1970) == 1_619_776_053))
        out.append(("chromium: microseconds are not read as seconds",
                    chromiumTime(13_264_249_653_682_696) != chromiumTime(13_264_249_653)))
        out.append(("firefox: microseconds count from the unix epoch",
                    firefoxTime(1_700_000_000_000_000) == Date(timeIntervalSince1970: 1_700_000_000)))
        out.append(("firefox and chromium epochs are 1601-vs-1970 apart",
                    firefoxTime(0).timeIntervalSince(chromiumTime(0)) == 11_644_473_600))
        out.append(("safari: seconds count from the 2001 reference date",
                    safariTime(0) == Date(timeIntervalSince1970: 978_307_200)))

        let json = """
        {"roots": {
          "bookmark_bar": {"type": "folder", "name": "Bar", "children": [
            {"type": "url", "name": "Apple", "url": "https://apple.com"},
            {"type": "folder", "name": "Work", "url": "https://folder.example", "children": [
              {"type": "url", "name": "Nested", "url": "https://nested.example"}]}]},
          "other": {"type": "folder", "children": [
            {"type": "url", "name": "Other", "url": "https://other.example"}]},
          "synced": {"type": "folder", "children": []}}}
        """
        let chrome = chromiumBookmarks(Data(json.utf8))
        out.append(("chromium json: every url node across all three roots is found",
                    chrome.count == 3))
        out.append(("chromium json: children of a nested folder are walked",
                    chrome.contains { $0.url == "https://nested.example" }))
        out.append(("chromium json: a folder carrying a url field is not a bookmark",
                    !chrome.contains { $0.url == "https://folder.example" }))
        out.append(("chromium json: names come across as titles",
                    chrome.first?.title == "Apple"))
        out.append(("chromium json: a file with no roots yields nothing, no crash",
                    chromiumBookmarks(Data("{\"checksum\": \"x\"}".utf8)).isEmpty))

        let leaf: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf",
                                   "URLString": "https://apple.com",
                                   "URIDictionary": ["title": "Apple"]]
        let nested: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Work",
                                     "Children": [["WebBookmarkType": "WebBookmarkTypeLeaf",
                                                   "URLString": "https://nested.example",
                                                   "URIDictionary": ["title": "Nested"]]]]
        let proxy: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"]
        let root: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "",
                                   "Children": [leaf, nested, proxy]]
        // Round-trip through a real binary plist so the walk sees the types plists actually
        // produce, not the Swift literals.
        let plist = (try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        let safari = safariBookmarks(plist)
        out.append(("safari plist: leaves at both levels are found",
                    safari.map(\.url) == ["https://apple.com", "https://nested.example"]))
        out.append(("safari plist: the title comes out of URIDictionary",
                    safari.first?.title == "Apple"))
        out.append(("safari plist: proxy nodes (History, Bonjour) are skipped",
                    !safari.contains { $0.title == "History" }))
        out.append(("safari plist: a non-dictionary root yields nothing, no crash",
                    safariBookmarks("nope").isEmpty))

        return out
    }
}
