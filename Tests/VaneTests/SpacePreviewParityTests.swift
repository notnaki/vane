import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpacePreviewParityTests: XCTestCase {
    func testTallSidebarGhostDoesNotLoseRowsOrItsTodaySection() {
        TestEnvironment.prepare()
        let profile = UUID()
        let pins = (0..<22).map { URL(string: "https://example.com/pin/\($0)")! }
        let today = URL(string: "https://example.com/today")!
        let preview = SpacePreviewList(space: Space(name: "Tall", profileID: profile,
            tabURLs: [today], pinnedTabURLs: pins), liveTabs: nil)
        XCTAssertEqual(preview.rows.pinned.count, 22)
        XCTAssertEqual(preview.rows.today.count, 1)
        Store.forget(profile)
    }

    func testBlankTabKeepsItsRowInTheGhost() {
        TestEnvironment.prepare()
        let profile = UUID()
        let tab = Tab(profileID: profile)
        defer { tab.tearDown(); Store.forget(profile) }
        let preview = SpacePreviewList(space: Space(name: "Blank", profileID: profile), liveTabs: [tab])
        XCTAssertEqual(preview.rows.today.count, 1)
        XCTAssertEqual(preview.rows.today.first.map { preview.title(for: $0) }, "New Tab")
    }

    func testRememberedSelectionIsVisibleBeforeLanding() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Tab(profileID: profile), second = Tab(profileID: profile)
        defer { first.tearDown(); second.tearDown(); Store.forget(profile) }
        first.park(url: URL(string: "https://example.com/first")!, Parked(title: "First"))
        second.park(url: URL(string: "https://example.com/second")!, Parked(title: "Second"))
        let tabs = [first, second]
        let shape = Pins(entries: tabs.map { .init(row: .tab($0.id.uuidString)) })
        let space = Space(name: "Work", profileID: profile)
        func preview(current: UUID) -> SpacePreviewList {
            SpacePreviewList(space: space, liveTabs: tabs,
                state: Stash(tabs: tabs, pins: Pins(), todayShape: shape,
                             splits: [], current: current, fingerprint: ""))
        }
        let firstPixels = try pixels(preview(current: first.id))
        let secondPixels = try pixels(preview(current: second.id))
        let changed = zip(firstPixels, secondPixels).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertGreaterThan(changed, 100, "Moving the remembered selection must move the ghost's row fill")
    }

    func testRenderedGhostMatchesSettledSidebarWithFoldersSplitsAndTidyPreferences() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let space = Space(name: "Work", profileID: profile)
        let outgoing = Space(name: "Outgoing", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([outgoing, space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        let tidyEnabled = TidyTabs.enabled
        defer {
            TidyTabs.enabled = tidyEnabled
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        let pin = store.newBlankTab(focus: false, as: .pinned)
        pin.restore(url: URL(string: "https://example.com/home")!, home: nil, parked: Parked(title: "Pinned"))
        let today = (0..<7).map { _ in store.newBlankTab(focus: false) }
        let folder = Folder(name: "Projects")
        store.pins = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(pin.id.uuidString), parent: folder.id)])
        store.todayShape = Pins(entries: today.map { .init(row: .tab($0.id.uuidString)) })
        store.splits = [try XCTUnwrap(Split(tabs: [today[0].id, today[1].id])).focusing(today[1].id)]
        store.current = today[1].id
        for collapsed in [false, true] {
            if store.pinnedSectionCollapsed != collapsed { store.togglePinnedSection() }
            for enabled in [false, true] {
                TidyTabs.enabled = enabled
                store.switchTo(space: outgoing)
                let ghost = store.swipePreview(in: space)
                let preview = try pixels(ghost)
                store.switchTo(space: space)
                let settled = try pixels(SidebarSpaceSections().environmentObject(store))
                let changed = zip(preview, settled).filter { abs(Int($0) - Int($1)) > 2 }.count
                XCTAssertEqual(preview.count, settled.count)
                XCTAssertLessThanOrEqual(changed, 10,
                    "Ghost must match the settled sidebar (collapsed: \(collapsed), tidy: \(enabled))")
            }
        }
    }

    func testSavedEaselGhostUsesTheRestoredBoardTitle() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let repository = EaselStore.shared(profileID: profile, directory: Store.directory)
        defer { EaselStore.forget(profile, directory: Store.directory); Store.forget(profile) }
        let board = try repository.create(title: "Sketches")
        let preview = SpacePreviewList(space: Space(name: "Work", profileID: profile,
            tabURLs: [EaselAddress.url(board.id)]), liveTabs: nil)
        XCTAssertEqual(preview.rows.today.map { preview.title(for: $0) }, ["Sketches"])
    }

    func testSavedTodayGhostUsesHistoryWhenTheSidecarHasNoTitle() {
        TestEnvironment.prepare()
        let profile = UUID()
        defer { Store.forget(profile) }
        let url = URL(string: "https://example.com/document")!
        XCTAssertTrue(Store.store(for: profile).record(url, title: "Saved document"))
        let preview = SpacePreviewList(space: Space(name: "Work", profileID: profile,
            tabURLs: [url]), liveTabs: nil)
        XCTAssertEqual(preview.rows.today.map { preview.title(for: $0) }, ["Saved document"])
    }

    func testSavedGhostMatchesRestorationWithHiddenRememberedTab() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let outgoing = Space(name: "Outgoing", profileID: profile)
        let hidden = URL(string: "https://invalid.test/hidden")!
        let visible = URL(string: "https://invalid.test/visible")!
        let incoming = Space(name: "Incoming", profileID: profile, tabURLs: [hidden, visible])
        let folder = Folder(name: "Locked", requiresAuthentication: true)
        let key = TabStore.shapeKey(.today, space: incoming.id, profileID: profile)
        let shape = Pins(entries: [.init(row: .folder(folder)),
            .init(row: .tab(hidden.absoluteString), parent: folder.id),
            .init(row: .tab(visible.absoluteString))])
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        Spaces.rememberTab(hidden.absoluteString, in: incoming.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([outgoing, incoming], for: profile))
        let store = TabStore(profileID: profile, space: outgoing, session: [])
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            UserDefaults.vane.removeObject(forKey: key)
            Spaces.rememberTab(nil, in: incoming.id)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        let ghost = store.swipePreview(in: incoming)
        let before = try pixels(ghost)
        XCTAssertTrue(store.tabs.isEmpty, "Previewing a saved Space must not create tabs or pages")
        store.switchTo(space: incoming)
        let after = try pixels(SidebarSpaceSections().environmentObject(store))
        XCTAssertEqual(before.count, after.count)
        XCTAssertLessThanOrEqual(zip(before, after).filter { abs(Int($0) - Int($1)) > 2 }.count, 10)
    }

    func testForcedAppearanceGhostMatchesDestinationWhileOutgoingWindowHasOppositeAppearance() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let incoming = Space(name: "Incoming", profileID: profile, appearance: "dark")
        let ghost = SpacePreviewList(space: incoming, liveTabs: nil)
        let before = try SidebarSnapshot.pixels(ghost.environment(\.colorScheme, ghost.colorScheme), appearance: .aqua)
        let after = try SidebarSnapshot.pixels(ghost, appearance: .darkAqua)
        XCTAssertLessThanOrEqual(zip(before, after).filter { abs(Int($0) - Int($1)) > 2 }.count, 10,
                                "Ink must already use the incoming Space's appearance")
        Store.forget(profile)
    }

    func testNewProfileGhostMatchesFreshProfileRestoration() throws {
        TestEnvironment.prepare()
        let outgoing = Space(name: "Outgoing", profileID: UUID())
        let profile = UUID()
        let pin = URL(string: "https://invalid.test/pin")!
        let incoming = Space(name: "Incoming", profileID: profile, pinnedTabURLs: [pin])
        XCTAssertTrue(ProfileManager.shared.saveSpaces([incoming], for: profile))
        let source = TabStore(profileID: outgoing.profileID, space: outgoing, session: [])
        var destination: TabStore?
        defer {
            for store in [source, destination].compactMap({ $0 }) {
                store.dropStashes()
                let tabs = store.tabs
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
                Store.forget(store.profileID)
            }
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        let before = try pixels(source.swipePreview(in: incoming))
        let restored = TabStore(profileID: profile, space: incoming)
        destination = restored
        XCTAssertNil(restored.current, "A freshly mounted profile with no Today tabs leaves its selection empty")
        let after = try pixels(SidebarSpaceSections().environmentObject(restored))
        XCTAssertEqual(before.count, after.count)
        XCTAssertLessThanOrEqual(zip(before, after).filter { abs(Int($0) - Int($1)) > 2 }.count, 10)
    }

    private func pixels<V: View>(_ preview: V) throws -> Data {
        try SidebarSnapshot.pixels(preview)
    }
}
