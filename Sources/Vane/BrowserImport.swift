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

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    /// ponytail: newest N urls, not the whole table. Store.record is one INSERT per row on
    /// the main thread, and a heavy Chrome profile has six figures of them. If someone ever
    /// wants the full archive the fix is a batched transaction in Store, not a bigger number.
    private static let historyLimit = 5000

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

    static func importAll(from p: BrowserProfile) throws -> (history: Int, bookmarks: Int) {
        var visits: [(url: String, title: String, at: Date)] = []
        var marks: [(url: String, title: String)] = []

        switch family(of: p) {
        case .safari:
            // Two independent TCC-protected files. Bookmarks are the ones people actually
            // want, so a locked History.db must not sink the whole import.
            var firstFailure: Error?
            if p.hasBookmarks {
                do { marks = try safariBookmarksFile(p.path.appendingPathComponent("Bookmarks.plist")) }
                catch { firstFailure = error }
            }
            if p.hasHistory {
                do { visits = try safariHistory(p.path.appendingPathComponent("History.db")) }
                catch { firstFailure = firstFailure ?? error }
            }
            if let firstFailure, visits.isEmpty, marks.isEmpty { throw firstFailure }

        case .firefox:
            let places = p.path.appendingPathComponent("places.sqlite")
            try query(places, """
                SELECT url, title, last_visit_date FROM moz_places
                WHERE last_visit_date IS NOT NULL AND visit_count > 0
                ORDER BY last_visit_date DESC LIMIT \(historyLimit)
                """) { visits.append((text($0, 0), text($0, 1), firefoxTime(sqlite3_column_int64($0, 2)))) }
            // type 1 is a bookmark; 2 and 3 are folders and separators.
            try query(places, """
                SELECT p.url, b.title FROM moz_bookmarks b
                JOIN moz_places p ON p.id = b.fk WHERE b.type = 1
                """) { marks.append((text($0, 0), text($0, 1))) }

        case .chromium:
            if p.hasHistory {
                try query(p.path.appendingPathComponent("History"), """
                    SELECT url, title, last_visit_time FROM urls
                    WHERE last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(historyLimit)
                    """) { visits.append((text($0, 0), text($0, 1), chromiumTime(sqlite3_column_int64($0, 2)))) }
            }
            if p.hasBookmarks {
                marks = chromiumBookmarks(try read(p.path.appendingPathComponent("Bookmarks")))
            }
        }

        return (commit(visits), commit(marks))
    }

    private enum Family { case chromium, firefox, safari }

    private static func family(of p: BrowserProfile) -> Family {
        if p.browser == "Safari" { return .safari }
        if FileManager.default.fileExists(atPath: p.path.appendingPathComponent("places.sqlite").path) {
            return .firefox
        }
        return .chromium
    }

    /// Store stamps every imported visit with Date.now, so the *insertion order* is the only
    /// thing carrying the source browser's recency ranking — hence oldest first.
    /// ponytail: this loses real visit dates and visit counts, because Store.record takes
    /// neither. Upgrade path is a `record(_:title:at:)` overload; not worth widening the
    /// Store API for a one-shot migration.
    private static func commit(_ visits: [(url: String, title: String, at: Date)]) -> Int {
        var n = 0
        for v in visits.sorted(by: { $0.at < $1.at }) {
            guard let u = URL(string: v.url), u.scheme == "http" || u.scheme == "https" else { continue }
            Store.shared.record(u, title: v.title)
            n += 1
        }
        return n
    }

    /// toggleBookmark is a toggle, so an already-bookmarked url would be *deleted* by a
    /// second import. Check first. The Set also collapses urls filed in two folders.
    private static func commit(_ marks: [(url: String, title: String)]) -> Int {
        var seen = Set<String>()
        var n = 0
        for m in marks {
            guard let u = URL(string: m.url), u.scheme == "http" || u.scheme == "https",
                  seen.insert(u.absoluteString).inserted, !Store.shared.isBookmarked(u) else { continue }
            Store.shared.toggleBookmark(u, title: m.title)
            n += 1
        }
        return n
    }

    // MARK: Timestamps

    /// Chromium counts microseconds from 1601-01-01 UTC — the Windows FILETIME epoch, which
    /// is 11644473600 seconds before the Unix one.
    static func chromiumTime(_ micro: Int64) -> Date {
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
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = top["roots"] as? [String: Any] else { return [] }
        var out: [(url: String, title: String)] = []
        func walk(_ node: Any?) {
            guard let n = node as? [String: Any] else { return }
            if n["type"] as? String == "url", let u = n["url"] as? String {
                out.append((u, n["name"] as? String ?? ""))
            }
            for child in n["children"] as? [Any] ?? [] { walk(child) }
        }
        for key in ["bookmark_bar", "other", "synced"] { walk(roots[key]) }
        return out
    }

    /// Safari's Bookmarks.plist: WebBookmarkTypeList nodes hold Children, WebBookmarkTypeLeaf
    /// nodes hold the url. Anything else (WebBookmarkTypeProxy — History, Bonjour) has no
    /// Children and falls out on its own.
    static func safariBookmarks(_ node: Any?) -> [(url: String, title: String)] {
        guard let n = node as? [String: Any] else { return [] }
        if n["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" {
            guard let u = n["URLString"] as? String else { return [] }
            return [(u, (n["URIDictionary"] as? [String: Any])?["title"] as? String ?? "")]
        }
        return (n["Children"] as? [Any] ?? []).flatMap { safariBookmarks($0) }
    }

    private static func safariBookmarksFile(_ file: URL) throws -> [(url: String, title: String)] {
        safariBookmarks(try PropertyListSerialization.propertyList(from: try read(file),
                                                                   format: nil))
    }

    /// Titles live on the visit, not the item, so take the title from the newest visit.
    /// SQLite's bare-column rule makes `v.title` come from the row that produced MAX().
    private static func safariHistory(_ file: URL) throws -> [(url: String, title: String, at: Date)] {
        var out: [(url: String, title: String, at: Date)] = []
        try query(file, """
            SELECT i.url, v.title, MAX(v.visit_time) FROM history_items i
            JOIN history_visits v ON v.history_item = i.id
            GROUP BY i.id ORDER BY 3 DESC LIMIT \(historyLimit)
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
    private static func guardReadable(_ file: URL) throws {
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

    private static let sidecars = ["", "-wal", "-shm", "-journal"]

    /// Copy before opening: the other browser is probably running and holds a lock, and the
    /// newest rows may still be sitting in the WAL sidecar rather than the main file — so
    /// the sidecars have to travel with it or the import silently misses recent history.
    private static func query(_ file: URL, _ sql: String, _ row: (OpaquePointer) -> Void) throws {
        try guardReadable(file)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vane-import-\(UUID().uuidString)")
        defer { for s in sidecars { try? FileManager.default.removeItem(atPath: tmp.path + s) } }
        for s in sidecars {
            guard FileManager.default.fileExists(atPath: file.path + s) else { continue }
            do { try FileManager.default.copyItem(atPath: file.path + s, toPath: tmp.path + s) }
            catch {
                // Losing a sidecar only costs the most recent rows; losing the main file
                // means there is nothing to import at all.
                if s.isEmpty { throw Failure("could not read \(file.lastPathComponent): \(error.localizedDescription)") }
            }
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure("\(file.lastPathComponent) is not a database Vane can read.")
        }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw Failure("\(file.lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st!) }
    }

    private static func text(_ st: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(st, col).map { String(cString: $0) } ?? ""
    }

    // MARK: UI

    static func chooseAndImport() {
        let found = detect()
        guard !found.isEmpty else {
            let a = NSAlert()
            a.messageText = "No other browsers found."
            a.informativeText = "Vane looked for Chrome, Edge, Brave, Vivaldi, Opera, Arc, "
                + "Firefox and Safari profiles in your Library folder."
            a.runModal()
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

        let chosen = found[max(0, popup.indexOfSelectedItem)]
        let done = NSAlert()
        do {
            let (h, b) = try importAll(from: chosen)
            done.messageText = "Imported \(h) history entr\(h == 1 ? "y" : "ies") "
                + "and \(b) bookmark\(b == 1 ? "" : "s") from \(chosen.browser)."
            if h == historyLimit { done.informativeText = "History was capped at the \(historyLimit) most recent pages." }
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
