import XCTest
@testable import vane

@MainActor final class PaletteSpaceCatalogTests: XCTestCase {
    private func manager() throws -> ProfileManager {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-palette-spaces-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ProfileManager(directory: root, sandboxed: true)
    }

    func testSuccessiveQueriesReuseMetadataAndSavedChangesRefreshIt() throws {
        let manager = try manager()
        var docs = manager.createSpace(name: "Documents", in: manager.active.id)
        var loads = 0
        let catalog = PaletteSpaceCatalog { manager, profiles in
            loads += 1
            return Spaces.strip(profiles: profiles) { manager.spaces(for: $0.id) }
        }
        for query in ["d", "do", "doc", "documents"] {
            let matches = Palette.rank(query, catalog.strip(manager: manager), key: \.name)
            XCTAssertTrue(matches.contains { $0.id == docs.id })
        }
        XCTAssertEqual(loads, 1, "Typing another query must not reread spaces.json")
        docs.name = "Live Documents"
        XCTAssertTrue(manager.updateSpace(docs))
        XCTAssertEqual(catalog.strip(manager: manager).first { $0.id == docs.id }?.name, docs.name)
        XCTAssertEqual(loads, 2)
        let extra = manager.createSpace(name: "New Space", in: manager.active.id)
        XCTAssertTrue(catalog.strip(manager: manager).contains { $0.id == extra.id })
        XCTAssertEqual(loads, 3)
        XCTAssertTrue(manager.deleteSpace(docs.id, in: manager.active.id))
        XCTAssertFalse(catalog.strip(manager: manager).contains { $0.id == docs.id })
        XCTAssertEqual(loads, 4)
    }

    func testUnsavedPreviewAndOwnProfileFilterStayLiveWithoutReloading() throws {
        let manager = try manager()
        let first = manager.active
        let home = manager.createSpace(name: "Home", in: first.id)
        let other = manager.create(name: "Other")
        let work = manager.createSpace(name: "Work", in: other.id)
        var loads = 0
        let catalog = PaletteSpaceCatalog { manager, profiles in
            loads += 1
            return Spaces.strip(profiles: profiles) { manager.spaces(for: $0.id) }
        }
        XCTAssertEqual(catalog.strip(manager: manager).map(\.id), [home.id, work.id])
        var preview = home
        preview.name = "Unsaved name"
        XCTAssertEqual(catalog.spaces(for: first.id, manager: manager, preview: preview), [preview])
        XCTAssertEqual(catalog.spaces(for: other.id, manager: manager, preview: preview), [work])
        XCTAssertEqual(catalog.strip(manager: manager).first?.name, "Home", "A preview must not overwrite the saved snapshot")
        XCTAssertEqual(manager.spaces(for: first.id), [home], "A preview must not persist")
        XCTAssertEqual(loads, 1)
        let empty = manager.create(name: "Empty")
        XCTAssertEqual(catalog.strip(manager: manager).map(\.id), [home.id, work.id])
        XCTAssertEqual(loads, 2, "A profile-list change invalidates even before that profile gains a Space")
        XCTAssertTrue(manager.delete(empty.id))
        _ = catalog.strip(manager: manager)
        XCTAssertEqual(loads, 3)
    }

    func testASecondManagerCannotReuseAnotherManagersSnapshot() throws {
        let first = try manager(), second = try manager()
        let one = first.createSpace(name: "One", in: first.active.id)
        let two = second.createSpace(name: "Two", in: second.active.id)
        XCTAssertEqual(first.profiles.map(\.id), second.profiles.map(\.id))
        XCTAssertEqual(first.spacesRevision, second.spacesRevision)
        let catalog = PaletteSpaceCatalog()
        XCTAssertEqual(catalog.strip(manager: first), [one])
        XCTAssertEqual(catalog.strip(manager: second), [two])
    }
}
