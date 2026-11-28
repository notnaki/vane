import XCTest
@testable import Vane

/// A Mac backup becomes the records the Mac's iCloud capture would publish, and importing
/// it twice leaves one copy of each.
@MainActor final class MacBackupTests: XCTestCase {
    func testBackupBecomesMacRecords() async throws {
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
        try await library.importBackup(records)
        try await library.importBackup(records)
        XCTAssertEqual(library.items.values.filter { $0.category == .pinnedTabs && $0.parentID == space.uuidString }.count, 1)
        let folders = library.folders(space: space)
        XCTAssertEqual(folders.map(\.name), ["Docs", "Reading"], "Pinned folders first, then Today's")
        XCTAssertEqual(folders.first?.links.map(\.title), ["A"])
        XCTAssertEqual(folders.last?.today, true)
        XCTAssertEqual(library.favourites(profile: profile).map(\.title), ["Fav"])
        records.forEach { library.remove($0.key) }
    }
}
