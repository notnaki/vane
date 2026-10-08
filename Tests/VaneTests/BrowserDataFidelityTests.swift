import XCTest
import SQLite3
@testable import vane

@MainActor final class BrowserDataFidelityTests: XCTestCase {

    private func directory() throws -> URL {
        TestEnvironment.prepare()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vane-fidelity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func destination() -> UUID {
        TestEnvironment.prepare()
        let id = UUID()
        _ = Store.store(for: id)
        addTeardownBlock { await MainActor.run { Store.forget(id) } }
        return id
    }

    private func sql(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func chromium(in dir: URL) throws -> BrowserProfile {
        try sql(dir.appendingPathComponent("History"), """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER);
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1, 'https://example.invalid/a?x=1&y=2#fragment', '雪 "Title"', 13344473600000000);
            INSERT INTO visits VALUES (1, 1, 13344473600000000), (2, 1, 13344473599000000);
            """)
        try Data("""
            {"roots":{"bookmark_bar":{"type":"folder","children":[
                {"type":"url","url":"https://book.invalid/","name":"Bookmark"}]}}}
            """.utf8).write(to: dir.appendingPathComponent("Bookmarks"))
        return BrowserProfile(browser: "Chrome", profile: "Synthetic", path: dir,
                              hasHistory: true, hasBookmarks: true)
    }

    func testHTMLVariationsPreserveNestedPathUnicodeAndMultilineText() {
        let entries = Export.parseNetscapeEntries("""
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <dl><p><dt><h3>Work &#x1F680;</h3><dl><dt><h3>Caf&#233;</h3><dl>
            <dt> <a add_date = '1700000000' href = 'https://example.invalid/?a=1&amp;b=2'>雪
            &quot;Quoted&quot; &#39;title&#39;</a>
            </dl></dl></dl>
            """)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.folder, "Work 🚀 / Café")
        XCTAssertEqual(entries.first?.row.url, "https://example.invalid/?a=1&b=2")
        XCTAssertEqual(entries.first?.row.title, "雪\n\"Quoted\" 'title'")
        XCTAssertEqual(entries.first?.importedAt?.timeIntervalSince1970, 1700000000)
    }

    func testHTMLQuotedGreaterThanAndEntityDecodingAreSinglePass() {
        let rows = Export.parseNetscape("<DT><A HREF=\"https://example.invalid/?q=>&amp;literal=&amp;lt;\" ADD_DATE=\"12\">a &amp;lt; b</A>")
        XCTAssertEqual(rows.first?.url, "https://example.invalid/?q=>&literal=&lt;")
        XCTAssertEqual(rows.first?.title, "a &lt; b")
        XCTAssertEqual(rows.first?.at.timeIntervalSince1970, 12)
    }

    func testTruncatedBookmarkFileDoesNotImportItsValidPrefix() throws {
        let id = destination(), file = try directory().appendingPathComponent("bookmarks.html")
        try Data("<DL><DT><A HREF=\"https://keep.invalid\">Complete</A><DT><A HREF=\"https://truncated".utf8).write(to: file)
        XCTAssertThrowsError(try BookmarkImport.importFile(file, profileID: id))
        XCTAssertTrue(Store.store(for: id).bookmarks().isEmpty)
    }

    func testPasswordMalformedQuotesRejectBeforeAnySaveAndNeverEchoInput() throws {
        let dir = try directory(), file = dir.appendingPathComponent("passwords.csv")
        for malformed in ["url,username,password\nhttps://valid.invalid,a,valid\nhttps://bad.invalid,b,\"truncated",
                          "url,username,password\nhttps://bad.invalid,b,un\"quoted",
                          "url,username,password\nhttps://bad.invalid,b,\"closed\"junk"] {
            try Data(malformed.utf8).write(to: file)
            var saves = 0
            XCTAssertThrowsError(try PasswordImport.importFile(file) { _ in saves += 1; return true })
            XCTAssertEqual(saves, 0)
        }
        let secret = "SYNTHETIC-SECRET-HEADER"
        XCTAssertThrowsError(try PasswordImport.parse(secret + ",unknown\n")) { error in
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testPasswordBOMAliasesOriginAndQuotedFields() throws {
        let aliases = [("url", "username", "password"), ("Website URL", "User Name", "Password"),
                       ("login_uri", "login_username", "login_password"), ("Web Site", "Login", "Password"),
                       ("hostname", "email", "password")]
        for (u, a, p) in aliases {
            let csv = "\u{FEFF}" + Export.csv([[u, a, p], ["https://EXAMPLE.invalid:8443/login", " 雪,\"a\" ", "line1\r\nline2 🔑"],
                                             ["file:///tmp/no", "a", "ignored"], ["https://empty.invalid", "", ""]])
            let result = try PasswordImport.parse(csv)
            XCTAssertEqual(result.entries.count, 1)
            XCTAssertEqual(result.skipped, 2)
            XCTAssertEqual(result.entries.first?.origin, PasswordOrigin(host: "example.invalid", port: 8443))
            XCTAssertEqual(result.entries.first?.account, " 雪,\"a\" ")
            XCTAssertEqual(result.entries.first?.password, "line1\r\nline2 🔑")
        }
    }

    func testPasswordDuplicateRowsKeepFirstSuccessfulCredential() throws {
        let file = try directory().appendingPathComponent("passwords.csv")
        try Export.write(Export.csv([["url", "username", "password"],
            ["https://fixture.invalid/login", "ada", "first"],
            ["https://fixture.invalid/other", "ada", "older"],
            ["https://fixture.invalid:8443", "ada", "other-port"]]), to: file)
        var saved: [String: String] = [:]
        let result = try PasswordImport.importFile(file) { entry in
            saved[entry.origin.key(account: entry.account)] = entry.password; return true
        }
        XCTAssertEqual(saved[PasswordOrigin(host: "fixture.invalid").key(account: "ada")], "first")
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failed, 0)
    }

    func testNativeImportPreservesEveryVisitAndRepeatedImportAddsNothing() throws {
        let profile = try chromium(in: directory()), id = destination()
        let first = try BrowserImport.importAll(from: profile, profileID: id)
        XCTAssertEqual(first.history, 2)
        XCTAssertEqual(first.bookmarks, 1)
        let original = Store.store(for: id).history()
        XCTAssertEqual(original.map { $0.at.timeIntervalSince1970 }, [1700000000, 1699999999])
        let second = try BrowserImport.importAll(from: profile, profileID: id)
        XCTAssertEqual(second.history, 0)
        XCTAssertEqual(second.bookmarks, 0)
        XCTAssertEqual(Store.store(for: id).history(), original)
    }

    func testBookmarkStorageFailureRollsBackBrowserHistoryAndPreservesExistingData() throws {
        let profile = try chromium(in: directory()), id = destination(), store = Store.store(for: id)
        XCTAssertTrue(store.record(URL(string: "https://existing.invalid")!, title: "Keep"))
        let before = store.history()
        let path = ProfileManager.dbURL(for: id, in: Store.directory)
        try sql(path, "CREATE TRIGGER reject_bookmark BEFORE INSERT ON bookmarks BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertThrowsError(try BrowserImport.importAll(from: profile, profileID: id))
        XCTAssertEqual(store.history(), before)
        XCTAssertTrue(store.bookmarks().isEmpty)
        try sql(path, "DROP TRIGGER reject_bookmark")
        XCTAssertEqual(try BrowserImport.importAll(from: profile, profileID: id).history, 2)
    }

    func testMalformedChromiumBookmarksRejectBeforeHistoryCommit() throws {
        let profile = try chromium(in: directory()), id = destination()
        try Data("{\"roots\": {".utf8).write(to: profile.path.appendingPathComponent("Bookmarks"))
        XCTAssertThrowsError(try BrowserImport.importAll(from: profile, profileID: id))
        XCTAssertTrue(Store.store(for: id).history().isEmpty)
    }

    func testLargeBookmarkRoundTripAndFirstURLWinsWithinProfile() throws {
        let id = destination(), other = destination(), file = try directory().appendingPathComponent("bookmarks.html")
        let entries = (0..<2500).map { index in
            Export.BookmarkEntry(row: .init(url: "https://fixture.invalid/\(index)?q=雪&x=1#part", title: "Title \(index)\n雪 \"&\"", at: Date(timeIntervalSince1970: Double(1700000000 + index))), folder: index % 2 == 0 ? "Work / Café" : nil)
        }
        let normalizedURLs = entries.map { URL(string: $0.row.url)!.absoluteString }
        try Export.write(Export.bookmarksHTML(entries + [entries[0]]), to: file)
        XCTAssertEqual(try BookmarkImport.importFile(file, profileID: id).imported, 2500)
        let saved = try Export.bookmarkEntries(profileID: id)
        XCTAssertEqual(Set(saved.map(\.row.url)), Set(normalizedURLs))
        XCTAssertEqual(Set(saved.map(\.row.title)), Set(entries.map(\.row.title)))
        XCTAssertEqual(Set(saved.map(\.row.at)), Set(entries.map(\.row.at)))
        XCTAssertEqual(saved.filter { $0.folder == "Work / Café" }.count, 1250)
        XCTAssertEqual(try BookmarkImport.importFile(file, profileID: id).imported, 0)
        XCTAssertTrue(Store.store(for: other).bookmarks().isEmpty)
        try Export.write(Export.bookmarksHTML(saved), to: file)
        XCTAssertEqual(try BookmarkImport.importFile(file, profileID: other).imported, 2500)
        XCTAssertEqual(try Export.bookmarkEntries(profileID: other).map(\.row).sorted { $0.url < $1.url }, saved.map(\.row).sorted { $0.url < $1.url })
    }

    func testFirefoxAndSafariKeepAllVisitsWithMissingOptionalTitles() throws {
        let firefox = try directory(), safari = try directory()
        try sql(firefox.appendingPathComponent("places.sqlite"), """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE moz_historyvisits (place_id INTEGER, visit_date INTEGER);
            CREATE TABLE moz_bookmarks (fk INTEGER, type INTEGER, title TEXT);
            INSERT INTO moz_places VALUES (1, 'https://firefox.invalid/', NULL);
            INSERT INTO moz_historyvisits VALUES (1, 1700000000000000), (1, 1699999999000000);
            INSERT INTO moz_bookmarks VALUES (1, 1, '雪 Bookmark'), (1, 2, 'Not a bookmark');
            """)
        try sql(safari.appendingPathComponent("History.db"), """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (history_item INTEGER, title TEXT, visit_time REAL);
            INSERT INTO history_items VALUES (1, 'https://safari.invalid/');
            INSERT INTO history_visits VALUES (1, 'Newest', 721692800), (1, NULL, 721692799);
            """)
        let leaf: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.invalid/",
                                   "URIDictionary": ["title": "雪 Bookmark"]]
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [leaf]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: safari.appendingPathComponent("Bookmarks.plist"))
        for (name, dir) in [("Firefox", firefox), ("Safari", safari)] {
            let id = destination(), profile = BrowserProfile(browser: name, profile: "Synthetic", path: dir,
                                                             hasHistory: true, hasBookmarks: true)
            let result = try BrowserImport.importAll(from: profile, profileID: id)
            XCTAssertEqual(result.history, 2)
            XCTAssertEqual(result.bookmarks, 1)
            let rows = try Export.historyRows(profileID: id)
            XCTAssertEqual(rows.map { $0.at.timeIntervalSince1970 }, [1700000000, 1699999999])
            XCTAssertEqual(rows.last?.title, "")
            XCTAssertEqual(Export.parseHistoryCSV(Export.historyCSV(rows)), rows)
            XCTAssertEqual(try BrowserImport.importAll(from: profile, profileID: id).history, 0)
        }
    }

    func testSafariUnreadableHistoryDoesNotSilentlyImportBookmarks() throws {
        let dir = try directory(), id = destination()
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.invalid/"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Bookmarks.plist"))
        let profile = BrowserProfile(browser: "Safari", profile: "Synthetic", path: dir, hasHistory: true, hasBookmarks: true)
        XCTAssertThrowsError(try BrowserImport.importAll(from: profile, profileID: id))
        XCTAssertTrue(Store.store(for: id).bookmarks().isEmpty)
    }

    func testLargeNativeHistoryRoundTripAndRepeatedImport() throws {
        let dir = try directory(), id = destination()
        try sql(dir.appendingPathComponent("History"), """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, last_visit_time INTEGER);
            CREATE TABLE visits (url INTEGER, visit_time INTEGER);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<10000)
            INSERT INTO urls SELECT i, 'https://large.invalid/' || i, '雪 title ' || i, 13344473600000000 + i FROM n;
            INSERT INTO visits SELECT id, last_visit_time FROM urls;
            """)
        let profile = BrowserProfile(browser: "Chrome", profile: "Synthetic", path: dir, hasHistory: true, hasBookmarks: false)
        XCTAssertEqual(try BrowserImport.importAll(from: profile, profileID: id).history, 10000)
        let rows = try Export.historyRows(profileID: id)
        XCTAssertEqual(rows.count, 10000)
        XCTAssertEqual(Export.parseHistoryCSV(Export.historyCSV(rows)), rows)
        XCTAssertEqual(try BrowserImport.importAll(from: profile, profileID: id).history, 0)
        XCTAssertEqual(try Export.historyRows(profileID: id), rows)
    }

    func testHistoryExportsPreserveFractionalDatesAndQuotedFields() throws {
        let rows = [Export.Row(url: "https://fixture.invalid/path?a=1&b=2#frag", title: "雪, \"quote\"\nnext", at: Date(timeIntervalSince1970: 1700000000.125))]
        XCTAssertEqual(Export.parseHistoryCSV(Export.historyCSV(rows)), rows)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Export.historyJSON(rows).utf8)) as? [[String: Any]])
        XCTAssertEqual(objects.first?["url"] as? String, rows[0].url)
        XCTAssertEqual(objects.first?["title"] as? String, rows[0].title)
        XCTAssertEqual(objects.first?["epoch"] as? Double, 1700000000.125)
    }

    func testUnreadableSourcesAndFailedExportsPreserveExistingOutput() throws {
        let id = destination(), dir = try directory(), file = dir.appendingPathComponent("existing.html")
        try Data("existing output".utf8).write(to: file)
        XCTAssertThrowsError(try BookmarkImport.importFile(dir, profileID: id))
        XCTAssertThrowsError(try PasswordImport.importFile(dir))
        try sql(ProfileManager.dbURL(for: id, in: Store.directory), "DROP TABLE bookmarks")
        XCTAssertThrowsError(try Export.write(Export.text(for: .bookmarks, profileID: id), to: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "existing output")
        XCTAssertThrowsError(try Export.write("new output", to: dir.appendingPathComponent("absent/out.html")))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "existing output")
    }
}
