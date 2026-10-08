import AppKit
import SQLite3

/// One detected profile directory. `path` is the directory that holds the data files, so
/// callers never have to know a vendor's layout.
struct BrowserProfile {
    let browser: String
    let profile: String
    let path: URL
    var hasHistory: Bool
    var hasBookmarks: Bool
}

/// Pull history and bookmarks out of the browsers already on this Mac.
///
/// Everything here is read-only and unencrypted: Chromium's `History` is plain SQLite,
/// its `Bookmarks` is plain JSON, Safari's bookmarks are a plist, Firefox's are SQLite.
/// ponytail: no keychain, no Safe Storage key, no NSS — those are only needed for cookies
/// and passwords, and passwords already have their own CSV path in Import.swift. The
/// ceiling is that session cookies do not come across; the upgrade path is the same
/// Safe Storage decryption PasswordImport deliberately avoids.
@MainActor enum BrowserImport {

    /// `nonisolated` along with `query` and `guardReadable` below: those three are a file
    /// copy, a `sqlite3_step` loop and the error it can fail with, and `ArcImport` runs them
    /// off the main actor so a heavy profile does not freeze the window.
    nonisolated struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    // MARK: Detection

    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

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

    static func detect() -> [BrowserProfile] {
        let fm = FileManager.default
        var out: [BrowserProfile] = []

        for (name, vendor) in chromiumVendors {
            let root = appSupport.appendingPathComponent(vendor)
            let kids = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            var found = kids.compactMap { chromiumProfile(name, $0, $0.lastPathComponent) }
            // Opera writes History straight into the vendor directory, with no profile level.
            if found.isEmpty, let bare = chromiumProfile(name, root, "Default") { found = [bare] }
            out += found
        }

        let firefox = appSupport.appendingPathComponent("Firefox/Profiles")
        for dir in (try? fm.contentsOfDirectory(at: firefox, includingPropertiesForKeys: nil)) ?? []
        where fm.fileExists(atPath: dir.appendingPathComponent("places.sqlite").path) {
            out.append(BrowserProfile(browser: "Firefox", profile: dir.lastPathComponent,
                                      path: dir, hasHistory: true, hasBookmarks: true))
        }

        // Safari is listed on existence alone: TCC lets us stat these files but not open
        // them, so whether they are actually readable only comes out at import time.
        let safari = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")
        let hasHistory = fm.fileExists(atPath: safari.appendingPathComponent("History.db").path)
        let hasMarks = fm.fileExists(atPath: safari.appendingPathComponent("Bookmarks.plist").path)
        if hasHistory || hasMarks {
            out.append(BrowserProfile(browser: "Safari", profile: "Default", path: safari,
                                      hasHistory: hasHistory, hasBookmarks: hasMarks))
        }
        return out
    }

    private static func chromiumProfile(_ browser: String, _ dir: URL, _ profile: String) -> BrowserProfile? {
        let fm = FileManager.default
        let h = fm.fileExists(atPath: dir.appendingPathComponent("History").path)
        let b = fm.fileExists(atPath: dir.appendingPathComponent("Bookmarks").path)
        guard h || b else { return nil }
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
    static func importAll(from p: BrowserProfile,
                          profileID: UUID = ProfileManager.activeProfileID) throws
        -> (history: Int, bookmarks: Int) {
        var visits: [(url: String, title: String, at: Date)] = []
        var marks: [(url: String, title: String)] = []

        switch family(of: p) {
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
                // type 1 is a bookmark; 2 and 3 are folders and separators.
                try query(places, """
                    SELECT p.url, b.title FROM moz_bookmarks b
                    JOIN moz_places p ON p.id = b.fk WHERE b.type = 1
                    """) { marks.append((text($0, 0), text($0, 1))) }
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
            return BookmarkImportItem(url: url, title: mark.title, folder: nil)
        }
        let store = Store.store(for: profileID)
        guard let result = store.importBrowserData(visits: history, bookmarks: bookmarks) else {
            throw Failure("Could not save imported history and bookmarks. " + (store.lastHistoryError ?? "Try again."))
        }
        return (result.history, result.bookmarks.imported)
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
        guard history || places || marks else {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "That folder doesn't look like a browser profile."
            a.informativeText = "Vane looked for a History, Bookmarks or places.sqlite file "
                + "in \(folder.lastPathComponent) and found none."
            a.runModal()
            return nil
        }
        return BrowserProfile(browser: places ? "Firefox" : "Chromium",
                              profile: folder.lastPathComponent,
                              path: folder,
                              hasHistory: history || places,
                              hasBookmarks: marks || places)
    }

    private enum Family { case chromium, firefox, safari }

    private static func family(of p: BrowserProfile) -> Family {
        if p.browser == "Safari" { return .safari }
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
    /// `nonisolated` only so `ArcImport.chromeTime` can wrap it: this type is @MainActor for
    /// the sake of its panels and its alerts, and one line of arithmetic has no business
    /// being the reason a second copy of the epoch constant exists.
    nonisolated static func chromiumTime(_ micro: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micro) / 1_000_000 - 11_644_473_600)
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

    /// Chromium's Bookmarks file: a tree under `roots`, where only `type == "url"` nodes are
    /// real bookmarks. Folders carry the same shape, so keying off the presence of a `url`
    /// field instead of the type would import folders too.
    static func chromiumBookmarks(_ data: Data) -> [(url: String, title: String)] {
        (try? checkedChromiumBookmarks(data)) ?? []
    }

    private static func checkedChromiumBookmarks(_ data: Data) throws -> [(url: String, title: String)] {
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = top["roots"] as? [String: Any] else {
            throw Failure("The Bookmarks file has no supported bookmark roots.")
        }
        var out: [(url: String, title: String)] = []
        func walk(_ node: Any) throws {
            guard let n = node as? [String: Any], let type = n["type"] as? String else {
                throw Failure("The Bookmarks file contains a malformed node.")
            }
            switch type {
            case "url":
                guard let url = n["url"] as? String else { throw Failure("A bookmark is missing its URL.") }
                out.append((url, n["name"] as? String ?? ""))
            case "folder": break
            case "separator": return
            default: throw Failure("The Bookmarks file contains an unsupported node type.")
            }
            if let children = n["children"] {
                guard let children = children as? [Any] else { throw Failure("A bookmark folder has malformed children.") }
                for child in children { try walk(child) }
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] { try walk(node) }
        }
        return out
    }

    /// Safari proxies are unsupported, while damaged leaves/list structures fail closed.
    static func safariBookmarks(_ node: Any?) -> [(url: String, title: String)] {
        (try? checkedSafariBookmarks(node)) ?? []
    }

    private static func checkedSafariBookmarks(_ node: Any?) throws -> [(url: String, title: String)] {
        guard let n = node as? [String: Any], let type = n["WebBookmarkType"] as? String else {
            throw Failure("The bookmarks plist contains a malformed node.")
        }
        switch type {
        case "WebBookmarkTypeLeaf":
            guard let url = n["URLString"] as? String else { throw Failure("A bookmark is missing its URL.") }
            return [(url, (n["URIDictionary"] as? [String: Any])?["title"] as? String ?? "")]
        case "WebBookmarkTypeProxy": return []
        case "WebBookmarkTypeList":
            guard let raw = n["Children"] else { return [] }
            guard let children = raw as? [Any] else { throw Failure("A bookmark folder has malformed children.") }
            return try children.flatMap { try checkedSafariBookmarks($0) }
        default: throw Failure("The bookmarks plist contains an unsupported node type.")
        }
    }

    private static func safariBookmarksFile(_ file: URL) throws -> [(url: String, title: String)] {
        try checkedSafariBookmarks(PropertyListSerialization.propertyList(from: try read(file), format: nil))
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
            throw Failure("macOS is blocking access to \(file.lastPathComponent).\n\n"
                + "Open System Settings → Privacy & Security → Full Disk Access, turn it on "
                + "for Vane, then try the import again.")
        }
    }

    /// SQLite's backup API makes a consistent snapshot, including committed WAL rows,
    /// while the source browser is running. The source connection is read-only and the
    /// snapshot lives in memory, so no credential database is copied to temporary files.
    nonisolated static func query(_ file: URL, _ sql: String, _ row: (OpaquePointer) -> Void) throws {
        try snapshot(file) { db in try query(db: db, file: file, sql: sql, row) }
    }

    nonisolated static func snapshot(_ file: URL, _ read: (OpaquePointer) throws -> Void) throws {
        try guardReadable(file)
        var source: OpaquePointer?
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(file.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure("\(file.lastPathComponent) is not a database Vane can read.")
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
            throw Failure("Could not snapshot \(file.lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
        }
        try read(db!)
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

    // MARK: UI

    static func chooseAndImport() {
        let found = detect()
        guard !found.isEmpty else {
            // Under the App Sandbox this is the normal case, not an error: scanning
            // ~/Library/Application Support/Google/Chrome is denied outright, so detect()
            // finds nothing however many browsers are installed. A folder the user picks
            // themselves comes with a powerbox grant, which is the way through.
            let a = NSAlert()
            a.messageText = "Vane can't look for browsers on its own."
            a.informativeText = "macOS only lets Vane read a folder you choose yourself. "
                + "Pick a browser profile folder — for Chrome that is usually "
                + "Library/Application Support/Google/Chrome/Default, and for Firefox a "
                + "folder inside Firefox/Profiles."
            a.addButton(withTitle: "Choose Folder…")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn, let picked = pickProfileFolder() else { return }
            report(importing: picked)
            return
        }

        // ponytail: NSAlert plus a popup, not a SwiftUI sheet. This runs once per machine.
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for p in found {
            var parts: [String] = []
            if p.hasHistory { parts.append("history") }
            if p.hasBookmarks { parts.append("bookmarks") }
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

    /// Shared by the detected-profile path and the pick-a-folder path.
    @MainActor private static func report(importing chosen: BrowserProfile) {
        let done = NSAlert()
        do {
            let (h, b) = try importAll(from: chosen)
            done.messageText = "Imported \(h) history entr\(h == 1 ? "y" : "ies") "
                + "and \(b) bookmark\(b == 1 ? "" : "s") from \(chosen.browser)."
        } catch {
            done.alertStyle = .warning
            done.messageText = "Could not import from \(chosen.browser)."
            done.informativeText = error.localizedDescription
        }
        done.runModal()
        rebuild()   // the Bookmarks and History menus are snapshots taken at build time
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
