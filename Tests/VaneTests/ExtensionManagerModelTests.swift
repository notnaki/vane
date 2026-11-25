import XCTest
import AppKit
@testable import vane

final class ExtensionManagerModelTests: XCTestCase {
    private let items: [ExtensionManagerModel.Item] = [
        .init(id: "a", name: "Café Reader", version: "2.4", summary: "Comfortable reading", enabled: true, needsAttention: false),
        .init(id: "b", name: "Blocker", version: "1.8", summary: "Hide distractions", enabled: false, needsAttention: false),
        .init(id: "c", name: "Broken utility", version: "3.0", summary: "Missing source", enabled: true, needsAttention: true),
        .init(id: "d", name: "Paused utility", version: "1.0", summary: "Update failed", enabled: false, needsAttention: true),
    ]

    func testSearchFindsInactiveMetadataAndFoldsCaseAndDiacritics() {
        XCTAssertEqual(ExtensionManagerModel.visible(items, query: " CAFE ", filter: .all).map(\.id), ["a"])
        XCTAssertEqual(ExtensionManagerModel.visible(items, query: "DISTRACTIONS", filter: .all).map(\.id), ["b"])
        XCTAssertEqual(ExtensionManagerModel.visible(items, query: "1.8", filter: .all).map(\.id), ["b"])
    }

    func testCountsReflectTheProfileCollectionEvenWhenSearchHasNoResults() {
        let counts = ExtensionManagerModel.counts(items)
        XCTAssertEqual(counts[.all], 4)
        XCTAssertEqual(counts[.enabled], 2)
        XCTAssertEqual(counts[.disabled], 2)
        XCTAssertEqual(counts[.attention], 2)
        XCTAssertTrue(ExtensionManagerModel.visible(items, query: "unmatched", filter: .attention).isEmpty)
        XCTAssertEqual(ExtensionManagerModel.counts(Array(items.prefix(1)))[.all], 1)
    }

    func testAttentionCanIncludeEnabledOrDisabledExtensions() {
        XCTAssertEqual(ExtensionManagerModel.visible(items, query: "", filter: .attention).map(\.id), ["c", "d"])
        XCTAssertEqual(ExtensionManagerModel.visible(items, query: "utility", filter: .disabled).map(\.id), ["d"])
    }

    func testSelectionClearsWhenFilteredOrRemovedAndPreservesVisibleSelection() {
        let visible = ExtensionManagerModel.visible(items, query: "", filter: .enabled)
        XCTAssertEqual(ExtensionManagerModel.selection("a", in: visible), "a")
        XCTAssertNil(ExtensionManagerModel.selection("b", in: visible))
        XCTAssertNil(ExtensionManagerModel.selection("removed", in: visible))
        XCTAssertNil(ExtensionManagerModel.selection(nil, in: visible))
    }
}

@MainActor final class ExtensionManagerPaletteTests: XCTestCase {
    private var ownedProfiles = Set<UUID>()

    override func tearDown() async throws {
        let released = ownedProfiles
        ownedProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(released)
    }

    func testManagerSearchOwnsCommandFOnlyInItsWindow() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profileID = UUID()
        ownedProfiles.insert(profileID)
        let host = ExtensionHost.host(for: profileID)
        defer { ExtensionManagement.close(for: profileID); ExtensionHost.forget(profileID) }
        ExtensionManagement.show(for: host)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Extensions — Profile" && $0.isVisible })
        var requested = false
        let token = NotificationCenter.default.addObserver(forName: ExtensionManagement.searchRequest,
            object: nil, queue: nil) { note in
                if note.object as? UUID == profileID { MainActor.assumeIsolated { requested = true } }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        func event(_ number: Int, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: number, context: nil, characters: "f",
                charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        }
        XCTAssertTrue(ExtensionManagement.handleKey(try event(window.windowNumber)))
        XCTAssertTrue(requested)
        XCTAssertFalse(ExtensionManagement.handleKey(try event(0)))
        XCTAssertFalse(ExtensionManagement.handleKey(try event(window.windowNumber, [.command, .shift])))
    }

    func testManageExtensionsUsesTheOriginatingWindowsProfile() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Extension Palette Fixture")
        XCTAssertNotEqual(manager.active.id, profile.id)
        let store = TabStore(profileID: profile.id, session: [])
        // The page opens in the originating window, so give the store one; without it the page
        // would go to (or open) another window and leak into later tests.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        store.window = window
        defer {
            store.window = nil
            window.close()
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            _ = manager.delete(profile.id)
        }
        let command = try XCTUnwrap(PaletteCommand.all(for: store).first { $0.id == "manageExtensions" })
        command.run()
        let tab = store.tabs.first { $0.vanePage?.section == .extensions }
        XCTAssertEqual(tab?.vanePage?.selection.profileID, profile.id,
                       "The action must retain its originating store rather than resolve the active profile when invoked")
        XCTAssertEqual(tab?.address, "vane://settings/extensions")
        // Extensions is a section of vane://settings: another section reuses the same tab,
        // and so does an old vane://extensions address.
        XCTAssertTrue(VanePages.open(.settings(.passwords), from: store) === tab)
        XCTAssertEqual(tab?.vanePage?.section, .passwords)
        let alias = try XCTUnwrap(VanePage(URL(string: "vane://extensions")))
        XCTAssertTrue(VanePages.open(alias, from: store) === tab)
        XCTAssertEqual(tab?.vanePage?.section, .extensions)
        XCTAssertEqual(store.tabs.filter { $0.vanePage != nil }.count, 1)
    }
}
