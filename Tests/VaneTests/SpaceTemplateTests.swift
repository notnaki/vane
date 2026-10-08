import XCTest
@testable import vane

@MainActor final class SpaceTemplateTests: XCTestCase {
    private func fixture() throws -> (ProfileManager, WorkspaceTemplates) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-templates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = ProfileManager(directory: root, sandboxed: true)
        return (manager, WorkspaceTemplates(manager: manager))
    }

    private func layout(locked: Bool = false) -> SpaceLayout {
        let first = UUID(), second = UUID()
        var outer = Folder(name: "Projects"), inner = Folder(name: "Design")
        outer.requiresAuthentication = locked ? true : nil
        inner.collapsed = true
        return SpaceLayout(tabs: [
            .init(id: first, url: URL(string: "https://example.com/same")!, kind: .pinned,
                  title: "First", customName: "Roadmap"),
            .init(id: second, url: URL(string: "https://example.com/same")!, kind: .today,
                  title: "Second", customName: "Notes")],
            pins: Pins(entries: [.init(row: .folder(outer)), .init(row: .folder(inner), parent: outer.id),
                                 .init(row: .tab(first.uuidString), parent: inner.id)]),
            today: Pins(entries: [.init(row: .tab(second.uuidString))]),
            splits: [.init(urls: ["https://example.com/same", "https://example.com/same"],
                           vertical: true, active: 1, ids: [first.uuidString, second.uuidString],
                           weights: [0.3, 0.7])], selected: second)
    }

    func testCredentialAddressesAreCleanedWithoutLosingPageNavigation() {
        let raw = URL(string: "https://alice:secret@example.com/docs?chapter=2&access_token=hidden&code=oauth#page=3&session=hidden")!
        XCTAssertEqual(SpaceLayout.templateURL(raw)?.absoluteString,
                       "https://example.com/docs?chapter=2#page=3")
        XCTAssertNil(SpaceLayout.templateURL(URL(string: "file:///tmp/private.pdf")!))
        XCTAssertNil(SpaceLayout.templateURL(URL(string: "vane://easel/\(UUID())")!))
    }

    func testFreshCopiesPreserveDuplicateRowsNamesHierarchyAndSplits() throws {
        let original = layout()
        let copy = try original.recreated()
        XCTAssertEqual(copy.tabs.map(\.url), [URL(string: "https://example.com/same")!, URL(string: "https://example.com/same")!])
        XCTAssertEqual(copy.tabs.map(\.customName), ["Roadmap", "Notes"])
        XCTAssertEqual(copy.tabs.map(\.kind), [.pinned, .today])
        XCTAssertTrue(Set(copy.tabs.map(\.id)).isDisjoint(with: original.tabs.map(\.id)))
        XCTAssertEqual(copy.pins.entries.compactMap { $0.folder?.name }, ["Projects", "Design"])
        XCTAssertEqual(copy.pins.entries[1].parent, copy.pins.entries[0].folder?.id)
        XCTAssertEqual(copy.pins.entries[2].parent, copy.pins.entries[1].folder?.id)
        XCTAssertEqual(copy.pins.entries[2].tab, copy.tabs[0].id.uuidString)
        XCTAssertEqual(copy.splits[0].ids, copy.tabs.map { $0.id.uuidString })
        XCTAssertEqual(copy.splits[0].weights, [0.3, 0.7])
        XCTAssertEqual(copy.selected, copy.tabs[1].id)
    }

    func testLockedSnapshotRequiresGrantAndDoesNotCopyLiveSource() throws {
        var original = layout(locked: true)
        let protected = try XCTUnwrap(original.pins.entries.first?.folder?.id)
        XCTAssertThrowsError(try original.forTemplate(unlocked: []))
        let captured = try original.forTemplate(unlocked: [protected])
        XCTAssertEqual(captured.pins.entries.first?.folder?.requiresAuthentication, true)
        original.pins.edit(folder: protected) { $0.owned = ["private-source"]; $0.dismissed = ["private-source"] }
        let plain = try original.forTemplate(unlocked: [protected])
        XCTAssertNil(plain.pins.entries.first?.folder?.owned)
        XCTAssertNil(plain.pins.entries.first?.folder?.dismissed)
    }

    func testProfileScopeAndCRUDPersistAcrossReload() throws {
        let (manager, library) = try fixture()
        let profile = manager.active.id
        let other = manager.create(name: "Other").id
        let source = Space(name: "Work", profileID: profile)
        let saved = try library.save(name: "Research", space: source, layout: layout(), unlocked: [])
        XCTAssertEqual(try library.load(profile: other).count, 0)
        XCTAssertThrowsError(try library.create(saved.id, profile: other, name: "Wrong", unlocked: []))
        try library.rename(saved.id, profile: profile, name: "Writing")
        var changed = layout(); changed.tabs[0].customName = "Updated"
        try library.update(saved.id, space: source, layout: changed, unlocked: [])
        let reopened = WorkspaceTemplates(manager: manager)
        XCTAssertEqual(try reopened.load(profile: profile).first?.name, "Writing")
        XCTAssertEqual(try reopened.load(profile: profile).first?.layout.tabs.first?.customName, "Updated")
        try reopened.delete(saved.id, profile: profile)
        XCTAssertTrue(try library.load(profile: profile).isEmpty)
    }

    func testCreationIsOneCommittedSpaceAndFailedWriteCreatesNothing() throws {
        let (manager, library) = try fixture()
        let profile = manager.active.id
        let saved = try library.save(name: "Setup", space: Space(name: "Source", profileID: profile),
                                     layout: layout(), unlocked: [])
        let target = ProfileManager.spacesURL(for: profile, in: manager.directory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.create(saved.id, profile: profile, name: "New", unlocked: []))
        XCTAssertTrue(manager.spaces(for: profile).isEmpty)
        try FileManager.default.removeItem(at: target)
        let created = try library.create(saved.id, profile: profile, name: "New", unlocked: [])
        XCTAssertEqual(manager.spaces(for: profile).map(\.id), [created.id])
        let disk = try XCTUnwrap(manager.spaces(for: profile).first?.layout)
        XCTAssertEqual(disk.pins.entries.compactMap { $0.folder?.name }, ["Projects", "Design"])
        XCTAssertEqual(disk.tabs.count, 2)
        XCTAssertEqual(disk.splits.count, 1)
    }

    func testCorruptOrFutureFilesCannotBeOverwritten() throws {
        let (manager, library) = try fixture()
        let file = WorkspaceTemplates.url(profile: manager.active.id, directory: manager.directory)
        for bytes in [Data("broken".utf8), Data("{\"version\":999,\"profileID\":\"\(manager.active.id)\",\"templates\":[]}".utf8)] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try library.load(profile: manager.active.id))
            XCTAssertThrowsError(try library.save(name: "Try", space: Space(name: "Source", profileID: manager.active.id),
                                                 layout: layout(), unlocked: []))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testFailedTemplateMutationPreservesPreviousFileAndCanRetry() throws {
        let (manager, library) = try fixture()
        let profile = manager.active.id
        let saved = try library.save(name: "Keep", space: Space(name: "Source", profileID: profile), layout: layout(), unlocked: [])
        let file = WorkspaceTemplates.url(profile: profile, directory: manager.directory)
        let committed = try Data(contentsOf: file)
        let failing = WorkspaceTemplates(manager: manager, writer: { _, _ in false })
        XCTAssertThrowsError(try failing.rename(saved.id, profile: profile, name: "Rejected"))
        XCTAssertThrowsError(try failing.delete(saved.id, profile: profile))
        XCTAssertEqual(try Data(contentsOf: file), committed)
        try library.rename(saved.id, profile: profile, name: "Retry")
        XCTAssertEqual(try library.load(profile: profile).first?.name, "Retry")
    }
}
