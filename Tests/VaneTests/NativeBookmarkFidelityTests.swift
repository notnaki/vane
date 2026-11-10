import XCTest
import SQLite3
@testable import vane

@MainActor final class NativeBookmarkFidelityTests: XCTestCase {
    private func directory() throws -> URL {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func source(_ browser: String, _ directory: URL) throws -> BrowserImport.Source {
        try BrowserImport.readSource(from: .init(browser: browser, profile: "Fixture", path: directory,
                                               hasHistory: false, hasBookmarks: true))
    }

    func testChromiumKeepsNestedFolderPathsDatesAndSourceOrder() throws {
        let root = try directory()
        try Data(#"""
        {"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
          {"type":"folder","name":"Work 🚀","children":[
            {"type":"folder","name":"Café","children":[
              {"type":"url","name":"First","url":"https://first.invalid/","date_added":"13344473600000000"},
              {"type":"url","name":"Second","url":"https://second.invalid/","date_added":"0"}]}]},
          {"type":"url","name":"Root","url":"https://root.invalid/","date_added":"bad"}]}}}
        """#.utf8).write(to: root.appendingPathComponent("Bookmarks"))
        let marks = try source("Chrome", root).bookmarks
        XCTAssertEqual(marks.map(\.title), ["First", "Second", "Root"])
        XCTAssertEqual(marks.map(\.folder), ["Work 🚀 / Café", "Work 🚀 / Café", nil])
        XCTAssertEqual(marks.first?.at?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNil(marks[1].at)
        XCTAssertNil(marks[2].at)
        let store = Store(path: ":memory:")
        XCTAssertEqual(store.importBookmarks(marks)?.imported, 3)
        XCTAssertEqual(store.bookmarkFolders().map(\.name), ["Work 🚀 / Café"])
        XCTAssertEqual(store.managedBookmarks().first(where: { $0.title == "First" })?.at.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(store.importBookmarks(marks)?.imported, 0)
    }

    func testSafariKeepsFolderPathsWithoutInventingCreationDates() throws {
        let root = try directory()
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Research", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "Web", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.invalid/",
                     "URIDictionary": ["title": "Saved page"]]]]]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: root.appendingPathComponent("Bookmarks.plist"))
        let mark = try XCTUnwrap(source("Safari", root).bookmarks.first)
        XCTAssertEqual(mark.folder, "Research / Web")
        XCTAssertEqual(mark.title, "Saved page")
        XCTAssertNil(mark.at)
    }

    private func firefox() throws -> URL {
        let root = try directory()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("places.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, fk INTEGER, type INTEGER, parent INTEGER,
                                       position INTEGER, title TEXT, dateAdded INTEGER, guid TEXT);
            INSERT INTO moz_places VALUES (1, 'https://firefox.invalid/', 'Page');
            INSERT INTO moz_bookmarks VALUES (1, NULL, 2, 0, 0, '', 0, 'root________'),
                (2, NULL, 2, 1, 0, 'Bookmarks Toolbar', 0, 'toolbar_____'),
                (3, NULL, 2, 2, 0, 'Work', 0, 'folder'),
                (4, NULL, 2, 3, 0, 'Café', 0, 'nested'),
                (5, 1, 1, 4, 0, 'Saved title', 1700000000125000, 'bookmark');
            """, nil, nil, nil), SQLITE_OK)
        return root
    }

    func testFirefoxKeepsAncestryAndCreationDate() throws {
        let mark = try XCTUnwrap(source("Firefox", firefox()).bookmarks.first)
        XCTAssertEqual(mark.title, "Saved title")
        XCTAssertEqual(mark.folder, "Work / Café")
        XCTAssertEqual(mark.at?.timeIntervalSince1970, 1_700_000_000.125)
    }

    func testFirefoxCyclicFolderGraphFailsBeforeImport() throws {
        let root = try firefox()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("places.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE moz_bookmarks SET parent = 4 WHERE id = 3", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try source("Firefox", root))
    }

    func testFirefoxDuplicateURLKeepsFirstBookmarkInFolderTreeOrder() throws {
        let root = try firefox()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("places.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            UPDATE moz_bookmarks SET position = 9 WHERE id = 5;
            INSERT INTO moz_bookmarks VALUES (6, NULL, 2, 2, 1, 'Later folder', 0, 'later'),
                (7, 1, 1, 6, 0, 'Later duplicate', 1700000000000000, 'duplicate');
            """, nil, nil, nil), SQLITE_OK)
        let marks = try source("Firefox", root).bookmarks
        XCTAssertEqual(marks.map(\.title), ["Saved title", "Later duplicate"])
        let store = Store(path: ":memory:")
        XCTAssertEqual(store.importBookmarks(marks)?.imported, 1)
        XCTAssertEqual(store.managedBookmarks().first?.title, "Saved title")
        XCTAssertEqual(store.bookmarkFolders().map(\.name), ["Work / Café"])
    }
}
