import AppKit
import XCTest
import SwiftUI
@testable import vane

@MainActor final class TabOrganizationTests: XCTestCase {
    private func fixture() -> (TabStore, Space, Space) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        addTeardownBlock { @MainActor in
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile)
        }
        return (store, first, second)
    }

    private func tab(_ url: String, in store: TabStore, kind: TabKind = .today) -> vane.Tab {
        let tab = store.newBlankTab(focus: false, as: kind)
        tab.restore(url: URL(string: url)!, home: kind == .today ? nil : URL(string: url),
                    parked: Parked(title: "Page"))
        return tab
    }

    func testTidyApplyDoesNotStealTabsFiledAfterPlanning() {
        let (store, _, _) = fixture()
        let a = tab("https://example.com/a", in: store)
        let b = tab("https://example.com/b", in: store)
        let manual = store.todayShape.newFolder(named: "Mine")!
        store.todayShape.move(a.id.uuidString, into: manual.id)
        let before = store.todayShape
        XCTAssertEqual(TidyTabs.apply([.init(name: "Proposed", tabIDs: [a.id, b.id])], to: store), 0)
        XCTAssertEqual(store.todayShape, before)
    }
    func testDuplicateCleanupKeepsPinnedAndFavouritesAndCanUndo() {
        let (store, first, _) = fixture()
        let url = "https://example.com/same?q=1#section"
        let pin = tab(url, in: store, kind: .pinned)
        let favourite = tab(url, in: store, kind: .favourite)
        let a = tab(url, in: store), b = tab(url, in: store)
        let folder = store.todayShape.newFolder(named: "Reading")!
        store.todayShape.move(a.id.uuidString, into: folder.id)
        let shape = store.todayShape
        TidyTitles.rename(a, to: "My page")
        let model = TabOrganization(store: store)
        XCTAssertEqual(model.duplicateGroups.count, 1)
        model.selection = [a.id, b.id]
        XCTAssertTrue(model.archiveSelected(duplicatesOnly: true))
        XCTAssertEqual(store.tabs.map(\.id), [favourite.id, pin.id])
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == first.id }?.tabURLs, [])
        XCTAssertTrue(model.undo())
        XCTAssertEqual(Set(store.tabs.map(\.id)), [pin.id, favourite.id, a.id, b.id])
        XCTAssertEqual(store.todayShape, shape)
        XCTAssertEqual(TidyTitles.title(for: store.tabs.first { $0.id == a.id }!), "My page")
    }

    func testDuplicateCleanupRequiresASurvivorAndKeepsQueryAndFragmentDifferences() {
        let (store, _, _) = fixture()
        let a = tab("https://example.com/?q=1#one", in: store)
        let b = tab("https://example.com/?q=1#one", in: store)
        _ = tab("https://example.com/?q=2#one", in: store)
        _ = tab("https://example.com/?q=1#two", in: store)
        let model = TabOrganization(store: store)
        XCTAssertEqual(model.duplicateGroups.count, 1)
        model.selection = [a.id, b.id]
        XCTAssertFalse(model.archiveSelected(duplicatesOnly: true))
        XCTAssertEqual(store.tabs.count, 4)
    }

    func testBulkMovePreservesIdentityNamesAndUndoAndRejectsAnotherProfile() {
        let (store, first, second) = fixture()
        let a = tab("https://example.com/a", in: store)
        let b = tab("https://example.com/b", in: store)
        TidyTitles.rename(a, to: "Custom")
        let model = TabOrganization(store: store)
        model.selection = [a.id, b.id]
        XCTAssertFalse(model.moveSelected(to: UUID()))
        XCTAssertTrue(model.moveSelected(to: second.id))
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == second.id }?.tabURLs.count, 2)
        XCTAssertTrue(model.undo())
        XCTAssertEqual(store.tabs.map(\.id), [a.id, b.id])
        XCTAssertTrue(store.tabs.first === a)
        XCTAssertEqual(TidyTitles.title(for: a), "Custom")
        XCTAssertEqual(store.currentSpaceID, first.id)
    }

    func testLockedTabsHiddenAndSplitAndProtectedTabsCannotBeArchived() {
        let (store, _, _) = fixture()
        let a = tab("https://example.com/secret", in: store)
        let b = tab("https://example.com/pinned", in: store, kind: .pinned)
        let folder = store.todayShape.newFolder(named: "Locked")!
        store.todayShape.move(a.id.uuidString, into: folder.id)
        store.todayShape.edit(folder: folder.id) { $0.requiresAuthentication = true }
        let model = TabOrganization(store: store)
        XCTAssertFalse(model.rows.contains { $0.id == a.id })
        model.selection = [a.id, b.id]
        XCTAssertFalse(model.archiveSelected())
        XCTAssertEqual(store.tabs.count, 2)
        let c = tab("https://example.com/split-a", in: store)
        let d = tab("https://example.com/split-b", in: store)
        store.splits = [Split(tabs: [c.id, d.id])!]
        model.refresh()
        XCTAssertFalse(model.rows.first { $0.id == c.id }!.canChange)
        model.selection = [c.id, d.id]
        XCTAssertFalse(model.archiveSelected())
        XCTAssertEqual(store.splits.count, 1)
    }

    func testPreviewDoesNotApplyAcrossSpacesOrAfterNavigation() {
        let (store, _, second) = fixture()
        let a = tab("https://example.com/a", in: store)
        _ = tab("https://example.com/b", in: store)
        let preview = TidyPreview(store: store)
        XCTAssertTrue(preview.isCurrent(in: store))
        a.park(url: URL(string: "https://example.com/changed")!, Parked(title: "Changed"))
        XCTAssertFalse(preview.isCurrent(in: store))
        store.switchTo(space: second)
        XCTAssertFalse(preview.isCurrent(in: store))
    }

    func testUndoDoesNotOverwriteLaterTabChanges() {
        let (store, _, _) = fixture()
        let a = tab("https://example.com/a", in: store)
        let model = TabOrganization(store: store)
        model.selection = [a.id]
        XCTAssertTrue(model.archiveSelected())
        let newer = tab("https://example.com/newer", in: store)
        XCTAssertFalse(model.undo())
        XCTAssertEqual(store.tabs.map(\.id), [newer.id])
    }

    func testSavedSpaceCleanupAndUndoRestoreFolderAndPageState() {
        let (store, _, second) = fixture()
        let url = URL(string: "https://saved.example/page")!
        var saved = second
        saved.tabURLs = [url, url]
        XCTAssertTrue(ProfileManager.shared.updateSpace(saved))
        var shape = Pins()
        shape.sync(tabs: [url.absoluteString, url.absoluteString])
        let folder = shape.newFolder(named: "Saved folder")!
        shape.move(url.absoluteString, into: folder.id)
        UserDefaults.vane.set(try! JSONEncoder().encode(shape),
            forKey: TabStore.shapeKey(.today, space: second.id, profileID: store.profileID))
        XCTAssertTrue(Suspension.SpaceState.save([url.absoluteString: Parked(title: "Saved page", state: Data([1, 2, 3]))],
            space: second.id, profileID: store.profileID, in: Store.directory))
        let model = TabOrganization(store: store)
        let copies = model.rows.filter { $0.spaceID == second.id }
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(store.stashes.isEmpty, "Review must not create or wake saved Spaces")
        model.selection = [copies[0].id]
        XCTAssertTrue(model.archiveSelected(duplicatesOnly: true))
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == second.id }?.tabURLs, [url])
        XCTAssertTrue(model.undo())
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == second.id }?.tabURLs, [url, url])
        XCTAssertEqual(TabStore.savedShape(.today, space: second.id, profileID: store.profileID), shape)
        XCTAssertEqual(Suspension.SpaceState.load(space: second.id, profileID: store.profileID,
            in: Store.directory)[url.absoluteString]?.state, Data([1, 2, 3]))
    }

    func testArchiveReachesStashesAndMirrorsEveryWindow() {
        let (store, first, second) = fixture()
        let a = tab("https://example.com/a", in: store)
        let peer = TabStore(profileID: store.profileID, space: first)
        addTeardownBlock { @MainActor in
            peer.dropStashes()
            TabStore.all.removeAll { $0 === peer }
            SharedTabs.release(peer.tabs)
        }
        store.switchTo(space: second)
        let b = tab("https://example.com/b", in: store)
        let model = TabOrganization(store: store)
        model.selection = [a.id, b.id]
        XCTAssertTrue(model.archiveSelected())
        XCTAssertTrue(peer.tabs.isEmpty)
        XCTAssertTrue(store.stashes[first.id]?.tabs.isEmpty == true)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertTrue(model.undo())
        XCTAssertEqual(peer.tabs.map(\.id), [a.id])
        XCTAssertEqual(store.stashes[first.id]?.tabs.map(\.id), [a.id])
        XCTAssertEqual(store.tabs.map(\.id), [b.id])
    }

    func testNavigationAfterReviewAndAnotherProfileAreRejected() {
        let (store, _, _) = fixture()
        let (foreign, _, foreignSpace) = fixture()
        let a = tab("https://example.com/a", in: store)
        let model = TabOrganization(store: store)
        model.selection = [a.id]
        XCTAssertFalse(model.moveSelected(to: foreignSpace.id))
        XCTAssertTrue(foreign.tabs.isEmpty)
        a.park(url: URL(string: "https://example.com/new")!, Parked(title: "New"))
        XCTAssertFalse(model.archiveSelected())
        XCTAssertTrue(store.tabs.contains { $0.id == a.id })
    }

    func testUnavailableSpaceDataLeavesLiveTabsAndArchiveUntouched() throws {
        let (store, _, _) = fixture()
        let a = tab("https://example.com/a", in: store)
        let model = TabOrganization(store: store)
        model.selection = [a.id]
        let file = ProfileManager.spacesURL(for: store.profileID, in: Store.directory)
        let backup = file.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: backup, to: file)
        }
        XCTAssertFalse(model.archiveSelected())
        XCTAssertEqual(store.tabs.map(\.id), [a.id])
        XCTAssertTrue(Archive.shared(for: store.profileID).entries.isEmpty)
    }

    func testFailedSidecarWriteDoesNotChangeMembershipOrArchive() throws {
        let (store, first, _) = fixture()
        let a = tab("https://example.com/a", in: store)
        let model = TabOrganization(store: store)
        model.selection = [a.id]
        XCTAssertTrue(Suspension.SpaceState.save([:], space: first.id, profileID: store.profileID, in: Store.directory))
        let actual = Suspension.SpaceState.url(for: store.profileID, in: Store.directory)
        let backup = actual.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: actual, to: backup)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: actual)
            try? FileManager.default.moveItem(at: backup, to: actual)
        }
        XCTAssertFalse(model.archiveSelected())
        XCTAssertEqual(store.tabs.map(\.id), [a.id])
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == first.id }?.tabURLs, [])
        XCTAssertTrue(Archive.shared(for: store.profileID).entries.isEmpty)
    }

    func testReviewSheetsRenderAtTheirDefaultSizes() async throws {
        let (store, _, _) = fixture()
        for number in 0..<6 { _ = tab("https://example.com/\(number)", in: store) }
        var preview = TidyPreview(store: store)
        preview.groups = [.init(name: "Research", tabIDs: Array(store.tabs.prefix(3)).map(\.id)),
                          .init(name: "Reading", tabIDs: Array(store.tabs.suffix(3)).map(\.id))]
        @MainActor func render<V: View>(_ view: V, name: String, size: NSSize) async throws {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            defer { window.close() }
            XCTAssertEqual(host.fittingSize.width, size.width, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, size.height, accuracy: 1)
            if let path = ProcessInfo.processInfo.environment["VANE_ORGANIZATION_SNAPSHOTS"] {
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(250))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber),
                    URL(fileURLWithPath: path).appendingPathComponent(name + ".png").path]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0)

            }
        }
        try await render(TidyPreviewSheet(store: store, preview: preview), name: "tidy", size: NSSize(width: 520, height: 540))
        try await render(TabOrganizationSheet(store: store), name: "organize", size: NSSize(width: 760, height: 580))
    }

}
