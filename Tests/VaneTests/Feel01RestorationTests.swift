import AppKit
import XCTest
@testable import vane

@MainActor final class Feel01RestorationTests: XCTestCase {
    func testUsableParkedTitleAvoidsOpeningHistoryButPlaceholderStillUsesIt() {
        TestEnvironment.prepare()
        let profile = UUID(), url = URL(string: "https://feel01-title.invalid/page")!
        let database = ProfileManager.dbURL(for: profile, in: Store.directory)
        let tab = Tab(profileID: profile)
        defer { tab.tearDown(); Store.forget(profile) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        tab.park(url: url, Parked(title: "Saved title"))
        XCTAssertEqual(tab.title, "Saved title")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path),
                       "Restoring a usable saved title must not open/query a history database")
        XCTAssertTrue(Store.store(for: profile).record(url, title: "Remembered title"))
        tab.park(url: url, Parked(title: url.host!))
        XCTAssertEqual(tab.title, "Remembered title", "Placeholder titles still consult profile history")
        XCTAssertNil(tab.existingWeb)
    }

    func testLargeSessionKeepsIdentityStateTitlesAndBackgroundRowsParked() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let state = Data([0, 1, 2, 3])
        let entries = (0..<1000).map { index in
            Session.Entry(id: UUID().uuidString, url: "https://feel01.invalid/duplicate",
                          title: "Saved \(index)", state: state.base64EncodedString(), kind: .pinned,
                          home: "https://feel01.invalid/duplicate", customName: "Custom \(index)")
        }
        let store = TabStore(profileID: profile, session: entries)
        defer { cleanup([store], profile: profile) }
        XCTAssertEqual(store.tabs.map(\.id.uuidString), entries.compactMap(\.id))
        XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil && $0.suspended })
        XCTAssertNil(store.current)
        for (index, tab) in store.tabs.enumerated() {
            XCTAssertEqual(tab.snapshot.state, state)
            XCTAssertEqual(tab.title, "Saved \(index)")
            XCTAssertEqual(tab.workspaceName, "Custom \(index)")
            XCTAssertEqual(tab.currentURL?.absoluteString, entries[index].url)
        }
        print("FEEL01 restored_rows=\(store.tabs.count) background_webviews=\(store.tabs.filter { $0.existingWeb != nil }.count)")
    }

    func testMixedRestoreReusesOnlyMatchingProfileIdentitiesAndKeepsSectionOrder() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), foreignProfile = UUID()
        let space = Space(name: "Shared restore fixture", profileID: profile)
        let source = TabStore(profileID: profile, space: space, session: [])
        source.sharingReady = false
        let shared = Tab(profileID: profile)
        shared.kind = .pinned
        source.tabs = [shared]
        let foreign = TabStore(profileID: foreignProfile, space: Space(name: "Foreign", profileID: foreignProfile), session: [])
        foreign.sharingReady = false
        let foreignTab = Tab(profileID: foreignProfile)
        foreignTab.kind = .pinned
        foreign.tabs = [foreignTab]
        let kinds: [TabKind] = [.pinned, .favourite, .pinned, .favourite, .pinned]
        var entries = kinds.map { kind in
            Session.Entry(id: UUID().uuidString, url: "https://feel01.invalid/duplicate", title: "Saved", kind: kind)
        }
        entries[2].id = shared.id.uuidString
        entries[4].id = foreignTab.id.uuidString
        let restored = TabStore(profileID: profile, space: space, session: entries)
        defer {
            cleanup([source, restored], profile: profile)
            cleanup([foreign], profile: foreignProfile)
        }
        XCTAssertEqual(restored.tabs.map(\.id.uuidString), [1, 3, 0, 2, 4].compactMap { entries[$0].id })
        XCTAssertTrue(restored.tabs.first { $0.id == shared.id } === shared)
        XCTAssertFalse(restored.tabs.first { $0.id == foreignTab.id } === foreignTab)
        XCTAssertTrue(restored.tabs.allSatisfy { $0.existingWeb == nil })
    }

    private func cleanup(_ stores: [TabStore], profile: UUID) {
        let tabs = stores.flatMap(\.everyTab)
        TabStore.all.removeAll { candidate in stores.contains { $0 === candidate } }
        SharedTabs.flush()
        SharedTabs.release(tabs)
        Store.forget(profile)
        ExtensionHost.forget(profile)
    }
}
