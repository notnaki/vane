import AppKit
import XCTest
@testable import vane

@MainActor final class PinnedSectionTests: XCTestCase {
    func testMovingTodaySelectionsIntoCollapsedPinsClearsHiddenSelection() {
        TestEnvironment.prepare()
        for route in 0..<3 {
            let space = Space(name: "Work", profileID: UUID(),
                              tabURLs: [URL(string: "about:blank#1")!, URL(string: "about:blank#2")!])
            let store = TabStore(profileID: space.profileID, space: space)
            defer {
                store.dropStashes()
                let tabs = store.tabs
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
                Store.forget(store.profileID)
                try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: store.profileID, in: Store.directory))
            }
            store.selection.selectAll(in: store.section(.today))
            let selected = store.selectedTabs.map(\.id)
            XCTAssertEqual(selected.count, 2)
            store.togglePinnedSection()
            XCTAssertEqual(store.selectedTabs.count, 2, "Collapsing pins keeps Today selections")
            switch route {
            case 0: store.moveSelection(to: .pinned)
            case 1:
                selected.forEach { store.move($0, to: .pinned) }
                store.selectionLanded(selected, in: .pinned)
            default:
                let folder = store.pins.newFolder(named: "Pinned folder")!
                store.moveSelection(into: folder.id)
            }
            XCTAssertEqual(store.tabs.filter { $0.kind == .pinned }.count, 2)
            XCTAssertTrue(store.selection.isEmpty, "Moving into hidden rows must clear bulk selection (route \(route))")
        }
    }

    func testCrossProfilePreviewOnlyUsesThisWindowsCollapseState() {
        TestEnvironment.prepare()
        let first = Space(name: "First", profileID: UUID())
        let second = Space(name: "Second", profileID: UUID(),
                           pinnedTabURLs: [URL(string: "https://example.com")!])
        let receiver = TabStore(profileID: first.profileID, space: first)
        let owner = TabStore(profileID: second.profileID, space: second)
        let receiverWindow = NSWindow(), otherWindow = NSWindow()
        receiver.window = receiverWindow
        owner.window = otherWindow
        defer {
            for store in [receiver, owner] {
                store.dropStashes()
                let tabs = store.tabs
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
                Store.forget(store.profileID)
                try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: store.profileID, in: Store.directory))
            }
        }
        owner.togglePinnedSection()
        XCTAssertFalse(receiver.swipePreview(in: second).rows.pinned.isEmpty,
                       "A fresh profile in this window expands even if another window collapsed it")
        owner.window = nil
        owner.parkedIn = receiverWindow
        XCTAssertTrue(receiver.swipePreview(in: second).rows.pinned.isEmpty,
                      "A parked profile in this same window retains its collapsed presentation")
    }

    func testCollapseKeepsPinsAndCurrentTabAndIsIndependentPerSpace() {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Space(name: "First", profileID: profile,
                          tabURLs: [URL(string: "about:blank")!],
                          pinnedTabURLs: [URL(string: "https://example.com")!])
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first)
        defer {
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        let pins = store.pins
        let selected = store.current
        store.selection.selectAll(in: store.section(.pinned))
        XCTAssertFalse(store.selection.isEmpty)
        XCTAssertFalse(store.pinnedSectionCollapsed)
        store.togglePinnedSection()
        XCTAssertTrue(store.pinnedSectionCollapsed)
        XCTAssertEqual(store.pins, pins)
        XCTAssertEqual(store.current, selected)
        XCTAssertTrue(store.selection.isEmpty, "Hidden rows must not remain a bulk-action target")
        store.selection.selectAll(in: store.section(.pinned))
        XCTAssertTrue(store.selectedTabs.isEmpty, "Select All must not select collapsed rows")
        XCTAssertTrue(store.swipePreview(in: first).rows.pinned.isEmpty)
        XCTAssertEqual(store.swipePreview(in: first).rows.today.count, 1)

        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertFalse(store.pinnedSectionCollapsed)
        store.switchTo(space: first)
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertTrue(store.pinnedSectionCollapsed)
        store.togglePinnedSection()
        XCTAssertFalse(store.pinnedSectionCollapsed)
        XCTAssertEqual(store.pins, pins)
        XCTAssertFalse(store.swipePreview(in: first).rows.pinned.isEmpty)
    }
}
