import XCTest
@testable import Vane

/// A Mac backup becomes the records the Mac's iCloud capture would publish, and importing
/// it twice leaves one copy of each.
@MainActor final class MacBackupTests: XCTestCase {
    func testBackupBecomesMacRecords() throws {
        let profile = MacBackup.defaultProfile, space = UUID(), tab = UUID(), pinned = UUID(), today = UUID()
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let profiles = try json(["profiles": [["id": profile.uuidString, "name": "Personal", "colorHex": "#6E7DD2"]],
                                 "activeID": profile.uuidString, "spaceOrder": [space.uuidString]])
        func folder(_ id: UUID, _ name: String) -> [String: Any] {
            ["row": ["folder": ["_0": ["id": id.uuidString, "name": name, "icon": "folder", "collapsed": false, "owned": ["x"]]]]]
        }
        let spaces = try json([[
            "id": space.uuidString, "name": "Work", "profileID": profile.uuidString, "tabURLs": [], "pinnedURLs": [],
            "pinnedTabURLs": ["https://a.example/"], "colorHex": "#112233",
            "layout": ["tabs": [["id": tab.uuidString, "url": "https://a.example/", "kind": 1, "title": "A"]],
                       "pins": ["entries": [folder(pinned, "Docs"), ["row": ["tab": ["_0": tab.uuidString]], "parent": pinned.uuidString]]],
                       "today": ["entries": [folder(today, "Reading")]], "splits": [], "omitted": 0]]])
        let prefs = try PropertyListSerialization.data(fromPropertyList: [
            "pinnedTabs": ["https://fav.example/", "file:///etc/hosts"], "tidyTitleOverrides": ["https://fav.example/": "Fav"]], format: .binary, options: 0)
        let archive = BackupArchive(preferences: prefs, files: [.init(name: "profiles.json", data: profiles), .init(name: "spaces.json", data: spaces)])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let sealed = try BackupEncryption.seal(try encoder.encode(archive), password: "pw")

        XCTAssertThrowsError(try MacBackup.records(sealed)) { XCTAssertEqual($0.localizedDescription, BackupError.passwordRequired.localizedDescription) }
        let records = try MacBackup.records(sealed, password: "pw")
        func record(_ category: ICloudCategory, _ id: String) throws -> ICloudItem { try XCTUnwrap(records.first { $0.category == category && $0.id == id }) }
        let enc = JSONEncoder()

        let pin = try record(.pinnedTabs, tab.uuidString)
        XCTAssertEqual(pin.parentID, space.uuidString)
        XCTAssertEqual(pin.fields["url"], try enc.encode(URL(string: "https://a.example/")!))
        XCTAssertEqual(pin.fields["parentFolderID"], try enc.encode(pinned))
        let docs = try record(.sidebarFolders, pinned.uuidString)
        XCTAssertEqual(docs.fields["section"], Data("1".utf8))
        XCTAssertNil(docs.fields["owned"], "live-folder bookkeeping stays on the Mac")
        XCTAssertEqual(try record(.sidebarFolders, today.uuidString).fields["section"], Data("2".utf8))
        let work = try record(.spaces, space.uuidString)
        XCTAssertEqual(work.fields["name"], Data(#""Work""#.utf8))
        XCTAssertNil(work.fields["layout"])
        let favourite = try record(.favourites, ICloudIdentity.digest("\(profile)|https://fav.example/"))
        XCTAssertEqual(favourite.fields["customName"], try enc.encode("Fav"))
        XCTAssertEqual(records.filter { $0.category == .favourites }.count, 1, "only web pages, as the Mac publishes")
        XCTAssertNotNil(records.first(where: \.isSpaceOrder))

        let library = Library(deviceID: "device-\(UUID())")
        XCTAssertFalse(library.importBackup(records).isEmpty)
        XCTAssertEqual(library.importBackup(records).count, 0, "importing again adds nothing")
        XCTAssertEqual(library.items.values.filter { $0.category == .pinnedTabs && $0.parentID == space.uuidString }.count, 1)
        let folders = library.folders(space: space)
        XCTAssertEqual(folders.map(\.name), ["Docs", "Reading"], "Pinned folders first, then Today's")
        XCTAssertEqual(folders.first?.links.map(\.title), ["A"])
        XCTAssertEqual(folders.last?.today, true)
        XCTAssertEqual(library.favourites(profile: profile).map(\.title), ["Fav"])
        records.forEach { library.remove($0.key) }
    }

    private func backup(spaces: [[String: Any]], profile: UUID = MacBackup.defaultProfile) throws -> Data {
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let profiles = try json(["profiles": [["id": profile.uuidString, "name": "Personal"]], "activeID": profile.uuidString])
        let prefs = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let archive = BackupArchive(preferences: prefs, files: [.init(name: "profiles.json", data: profiles), .init(name: "spaces.json", data: try json(spaces))])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(archive)
    }

    /// An import adds only what the phone lacks: a renamed Space keeps its name, and a
    /// record iCloud knows but this phone deleted stays deleted.
    func testImportNeverOverwritesOrRevives() throws {
        let space = UUID(), gone = UUID()
        let data = try backup(spaces: [
            ["id": space.uuidString, "name": "Work", "pinnedTabURLs": ["https://a.example/", "https://b.example/"],
             "layout": ["tabs": [["id": gone.uuidString, "url": "https://a.example/", "kind": 1]], "pins": ["entries": []], "splits": []]]])
        let records = try MacBackup.records(data)
        let spaceKey = ICloudIdentity.recordKey(category: .spaces, id: space.uuidString, profileID: MacBackup.defaultProfile)
        let goneKey = ICloudIdentity.recordKey(category: .pinnedTabs, id: gone.uuidString, profileID: MacBackup.defaultProfile)
        let library = Library(deviceID: "device-\(UUID())")
        defer { records.forEach { library.remove($0.key) } }
        var renamed = try XCTUnwrap(records.first { $0.key == spaceKey })
        renamed.fields["name"] = Data(#""Renamed""#.utf8)
        _ = library.importBackup(records.filter { $0.category != .pinnedTabs }.map { $0.key == spaceKey ? renamed : $0 })

        let added = library.importBackup(records, known: [goneKey])
        XCTAssertEqual(added.map(\.category), [.pinnedTabs], "only the pinned tab the phone never had")
        XCTAssertEqual(library.space(space)?.name, "Renamed")
        XCTAssertNil(library.items[goneKey])
        XCTAssertEqual(library.pinned(space: space).map(\.url.absoluteString), ["https://b.example/"])
    }

    /// A crafted backup is bounded: folders nest three deep at most, and counts, sizes and
    /// placeholder names are held to what the Mac would publish.
    func testCraftedBackupIsBounded() throws {
        let space = UUID(), chain = (0..<12).map { _ in UUID() }
        let entries: [[String: Any]] = chain.enumerated().map { index, id in
            var entry: [String: Any] = ["row": ["folder": ["_0": ["id": id.uuidString, "name": "L\(index)"]]]]
            if index > 0 { entry["parent"] = chain[index - 1].uuidString }
            return entry
        } + [["row": ["folder": ["_0": ["id": UUID().uuidString, "name": "Synced folder"]]]]]
        let many = (0..<600).map { ["id": UUID().uuidString, "name": "S\($0)"] as [String: Any] }
        let records = try MacBackup.records(try backup(spaces: [["id": space.uuidString, "name": "Deep", "layout": ["pins": ["entries": entries]]]] + many))
        XCTAssertEqual(records.filter { $0.category == .spaces }.count, 500)
        let folders = records.filter { $0.category == .sidebarFolders }
        XCTAssertEqual(folders.count, chain.count, "the placeholder folder is skipped")
        let topLevel = folders.filter { $0.fields["parentFolderID"] == Data("null".utf8) }.count
        XCTAssertEqual(topLevel, 4, "L0, L3, L6 and L9 start new chains of three")

        let library = Library(deviceID: "device-\(UUID())")
        defer { records.forEach { library.remove($0.key) } }
        _ = library.importBackup(records)
        func depth(_ rows: [FolderRow]) -> Int { rows.map { 1 + depth($0.folders) }.max() ?? 0 }
        XCTAssertEqual(depth(library.folders(space: space)), 3)

        XCTAssertThrowsError(try MacBackup.records(Data(count: MacBackup.limit + 1)))
        XCTAssertFalse(MacBackup.allowed("../profiles.json"))
        XCTAssertFalse(MacBackup.allowed("notes.txt"))
        XCTAssertTrue(MacBackup.allowed("spaces-\(UUID().uuidString.lowercased()).json"))
    }
}
