import Foundation
import XCTest
@testable import vane

/// The empty Space a default profile is born with gives way to an Arc import: an Arc Space
/// sharing its name is imported rather than skipped, and the placeholder goes afterwards.
@MainActor final class PlaceholderRemovalTests: XCTestCase {
    private var saved: [Space] = []
    private var profileName = ""

    override func setUp() async throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        saved = manager.spaces(for: ProfileManager.defaultID)
        profileName = try XCTUnwrap(manager.profiles.first { $0.id == ProfileManager.defaultID }?.name)
        XCTAssertTrue(manager.saveSpaces([], for: ProfileManager.defaultID))
    }

    override func tearDown() async throws {
        ProfileManager.shared.saveSpaces(saved, for: ProfileManager.defaultID)
    }

    private func scan(_ titles: [String]) -> ArcImport.Scan {
        let rows = [ArcRow.tab(url: URL(string: "https://example.test/\(UUID())")!, title: "Page")]
        let sidebar = ArcSidebar(spaces: titles.map {
            ArcSpace(id: UUID().uuidString, title: $0, profileDirectory: "Default",
                     themeHex: nil, pinned: [], today: rows)
        })
        return ArcImport.Scan(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("arc-placeholder-\(UUID())"),
            sidebar: sidebar, profiles: [], directories: ["Default"])
    }

    func testArcSpaceNamedLikeThePlaceholderIsImportedAndThePlaceholderGoes() async throws {
        let manager = ProfileManager.shared
        let placeholder = manager.createSpace(name: profileName, in: ProfileManager.defaultID)

        let counts = try await ArcImport.apply(scan([profileName, "Work"]))

        let spaces = manager.spaces(for: ProfileManager.defaultID)
        XCTAssertEqual(counts.spaces, 2)
        XCTAssertFalse(spaces.contains { $0.id == placeholder.id }, "The empty placeholder should be removed")
        XCTAssertEqual(spaces.map(\.name).sorted(), [profileName, "Work"].sorted())
        XCTAssertFalse(try XCTUnwrap(spaces.first { $0.name == profileName }).tabURLs.isEmpty,
                       "Arc's Space with the placeholder's name was skipped")
    }

    func testPlaceholderWithTabsIsKept() async throws {
        let manager = ProfileManager.shared
        var placeholder = manager.createSpace(name: profileName, in: ProfileManager.defaultID)
        placeholder.tabURLs = [try XCTUnwrap(URL(string: "https://example.test/keep"))]
        XCTAssertTrue(manager.updateSpace(placeholder))

        _ = try await ArcImport.apply(scan([profileName, "Work"]))

        let spaces = manager.spaces(for: ProfileManager.defaultID)
        XCTAssertTrue(spaces.contains { $0.id == placeholder.id }, "A Space holding tabs must not be deleted")
        XCTAssertEqual(spaces.filter { $0.name == profileName }.count, 1, "A real Space of the same name still wins")
    }

    func testPlaceholderWithAnEmptyFolderIsKept() async throws {
        let manager = ProfileManager.shared
        let placeholder = manager.createSpace(name: profileName, in: ProfileManager.defaultID)
        var shape = Pins()
        shape.entries = [Pins.Entry(row: .folder(Folder(name: "Keep")))]
        let key = TabStore.shapeKey(.pinned, space: placeholder.id, profileID: ProfileManager.defaultID)
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        defer { UserDefaults.vane.removeObject(forKey: key) }

        _ = try await ArcImport.apply(scan([profileName, "Work"]))

        XCTAssertTrue(manager.spaces(for: ProfileManager.defaultID).contains { $0.id == placeholder.id },
                      "A Space holding a folder is not a placeholder")
    }
}
