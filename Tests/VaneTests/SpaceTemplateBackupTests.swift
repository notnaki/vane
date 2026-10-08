import XCTest
@testable import vane

@MainActor final class SpaceTemplateBackupTests: XCTestCase {
    private enum Interrupted: Error { case now }
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        _ = f.seed()
        return f
    }
    private func snapshot() -> SpaceLayout {
        let first = UUID(), second = UUID()
        var folder = Folder(name: "Locked projects"); folder.requiresAuthentication = true
        let url = URL(string: "https://example.test/repeated")!
        return SpaceLayout(tabs: [.init(id: first, url: url, kind: .pinned, title: "First", customName: "Roadmap"),
                                 .init(id: second, url: url, kind: .today, title: "Second", customName: "Notes")],
            pins: Pins(entries: [.init(row: .folder(folder)), .init(row: .tab(first.uuidString), parent: folder.id)]),
            today: Pins(entries: [.init(row: .tab(second.uuidString))]),
            splits: [.init(urls: [url.absoluteString, url.absoluteString], vertical: true, active: 1,
                           ids: [first.uuidString, second.uuidString], weights: [0.25, 0.75])], selected: second)
    }
    @discardableResult private func seedTemplate(_ manager: ProfileManager, profile: UUID, name: String) throws -> WorkspaceTemplate {
        let layout = snapshot()
        return try WorkspaceTemplates(manager: manager).save(name: name, space: Space(name: name, profileID: profile),
            layout: layout, unlocked: Set(layout.protectedFolders.map(\.id)))
    }

    func testMultiProfileTemplateAndCreatedLayoutRoundTripUsesExistingBackup() throws {
        let source = try fixture(), target = try fixture()
        let manager = source.seed(), work = manager.create(name: "Work")
        let personal = try seedTemplate(manager, profile: manager.active.id, name: "Personal")
        let professional = try seedTemplate(manager, profile: work.id, name: "Work")
        let savedSpace = try WorkspaceTemplates(manager: manager).create(professional.id, profile: work.id, name: "Work Copy",
            unlocked: Set(professional.layout.protectedFolders.map(\.id)))
        let archive = try source.library.capture(reason: .manual)
        for profile in [personal.profileID, professional.profileID] {
            let name = WorkspaceTemplates.url(profile: profile, directory: source.root).lastPathComponent
            XCTAssertNotNil(archive.files.first { $0.name == name })
        }
        let restore = BackupRestore(library: target.library)
        try restore.prepare(archive)
        XCTAssertEqual(try restore.recoverAtLaunch(), .restored)
        let restoredManager = target.seed(), templates = WorkspaceTemplates(manager: restoredManager)
        XCTAssertEqual(try templates.load(profile: personal.profileID), [personal])
        XCTAssertEqual(try templates.load(profile: professional.profileID), [professional])
        XCTAssertEqual(restoredManager.spaces(for: work.id).first?.layout, savedSpace.layout)
        XCTAssertEqual(restoredManager.spaces(for: work.id).first?.layout?.splits.first?.weights, [0.25, 0.75])
    }

    func testMissingTemplatesAreRemovedAndInterruptedRemovalRollsBackExactBytes() throws {
        let source = try fixture(), target = try fixture()
        let manager = target.seed()
        let saved = try seedTemplate(manager, profile: manager.active.id, name: "Keep")
        let file = WorkspaceTemplates.url(profile: saved.profileID, directory: target.root)
        let before = try Data(contentsOf: file), incoming = try source.library.capture(reason: .manual)
        let restore = BackupRestore(library: target.library, checkpoint: { name in
            if name == "removed:space-templates.json" { throw Interrupted.now }
        })
        try restore.prepare(incoming)
        XCTAssertThrowsError(try restore.recoverAtLaunch())
        XCTAssertEqual(try BackupRestore(library: target.library).recoverAtLaunch(), .rolledBack)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let retry = BackupRestore(library: target.library)
        try retry.prepare(incoming)
        XCTAssertEqual(try retry.recoverAtLaunch(), .restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidVersionOwnershipAndLayoutRejectBackupWithoutTouchingCurrentFiles() throws {
        let source = try fixture(), target = try fixture()
        let manager = source.seed()
        let saved = try seedTemplate(manager, profile: manager.active.id, name: "Original")
        let file = WorkspaceTemplates.url(profile: manager.active.id, directory: source.root)
        let bytes = try Data(contentsOf: file)
        for invalid in [0, 1, 2] {
            var disk = try JSONDecoder().decode(WorkspaceTemplates.Disk.self, from: bytes)
            if invalid == 0 { disk.version = 999 }
            if invalid == 1 { disk.templates[0].profileID = UUID() }
            if invalid == 2 { disk.templates[0].layout.tabs[1].id = disk.templates[0].layout.tabs[0].id }
            try JSONEncoder().encode(disk).write(to: file)
            XCTAssertThrowsError(try source.library.capture(reason: .manual))
            var archive = try target.library.capture(reason: .manual)
            archive.files.append(.init(name: file.lastPathComponent, data: try Data(contentsOf: file)))
            let originalTarget = try target.library.capture(reason: .manual).files
            XCTAssertThrowsError(try BackupRestore(library: target.library).prepare(archive))
            XCTAssertEqual(try target.library.capture(reason: .manual).files, originalTarget)
        }
        try bytes.write(to: file)
        XCTAssertEqual(try WorkspaceTemplates(manager: manager).load(profile: saved.profileID), [saved])
    }

    func testBackupRejectsInconsistentOptionalSpaceLayout() throws {
        let source = try fixture(), manager = source.seed()
        let saved = try seedTemplate(manager, profile: manager.active.id, name: "Template")
        var space = try WorkspaceTemplates(manager: manager).create(saved.id, profile: manager.active.id, name: "Copy",
            unlocked: Set(saved.layout.protectedFolders.map(\.id)))
        space.layout?.tabs[0].url = URL(string: "https://example.test/changed")!
        try source.write([space], name: "spaces.json")
        XCTAssertThrowsError(try source.library.capture(reason: .manual))
    }

    func testLegacyURLListEditsReconcileTemplateLayoutBeforeBackup() throws {
        let source = try fixture(), manager = source.seed()
        let saved = try seedTemplate(manager, profile: manager.active.id, name: "Template")
        var space = try WorkspaceTemplates(manager: manager).create(saved.id, profile: manager.active.id, name: "Copy",
            unlocked: Set(saved.layout.protectedFolders.map(\.id)))
        let original = try XCTUnwrap(space.layout)
        space.tabURLs.append(URL(string: "https://example.test/incoming")!)
        XCTAssertTrue(manager.updateSpace(space))
        space = try XCTUnwrap(manager.spaces(for: manager.active.id).first)
        XCTAssertTrue(try XCTUnwrap(space.layout).matches(space))
        XCTAssertEqual(space.layout?.tabs.prefix(2).map(\.customName), ["Roadmap", "Notes"])
        XCTAssertEqual(space.layout?.splits, original.splits)
        XCTAssertNoThrow(try source.library.capture(reason: .manual))
        space.pinnedTabURLs = []
        XCTAssertTrue(manager.updateSpace(space))
        space = try XCTUnwrap(manager.spaces(for: manager.active.id).first)
        XCTAssertTrue(try XCTUnwrap(space.layout).matches(space))
        XCTAssertEqual(space.layout?.splits, [])
        XCTAssertNoThrow(try source.library.capture(reason: .manual))
    }
}
