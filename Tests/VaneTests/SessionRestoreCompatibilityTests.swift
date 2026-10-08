import AppKit
import XCTest
@testable import vane

@MainActor final class SessionRestoreCompatibilityTests: XCTestCase {
    func testDiskSessionRestoresDuplicateURLsDistinctHistoriesSelectionAndPrivateExclusion() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let oldHTTPS = HTTPSOnly.enabled; HTTPSOnly.enabled = false
        defer { HTTPSOnly.enabled = oldHTTPS }
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        let profile = UUID(), privateProfile = Profile.incognito.id
        let space = Space(name: "Session fixture", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let original = TabStore(profileID: profile, space: space, session: [])
        let privateStore = TabStore(isPrivate: true, session: [])
        var stores = [original, privateStore]
        defer {
            for store in stores {
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
            }
            ExtensionHost.forget(profile)
            // History writes queued by navigation may still hold this scratch database.
            // TestEnvironment removes the directory after the entire bundle finishes.
        }
        let sharedURL = try server.url("/same")
        let first = original.newBlankTab(), second = original.newBlankTab()
        for (tab, path) in [(first, "/first-history"), (second, "/second-history")] {
            tab.navigate(to: try server.url(path))
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Page \(path)" }
            if tab === second { tab.kind = .pinned }
            tab.navigate(to: sharedURL)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Page /same" }
        }
        original.current = second.id
        let secret = privateStore.newBlankTab()
        secret.navigate(to: try server.url("/private-sentinel"))
        try await compatibilityWait { !secret.web.isLoading && secret.web.title == "Page /private-sentinel" }
        let privateFile = ProfileManager.sessionURL(for: privateProfile, in: Store.directory)
        let previousPrivateData = try? Data(contentsOf: privateFile)
        XCTAssertTrue(Session.save())
        XCTAssertEqual(try? Data(contentsOf: privateFile), previousPrivateData, "Saving cannot persist private windows")
        let data = try Data(contentsOf: ProfileManager.sessionURL(for: profile, in: Store.directory))
        let entries = try XCTUnwrap(Session.decode(data).first)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.url), [sharedURL.absoluteString, sharedURL.absoluteString])
        XCTAssertTrue(entries.allSatisfy { $0.state != nil })
        XCTAssertEqual(Session.decodeSelected(data).first, second.id)
        // Release all old pages before rebuilding from bytes read back from disk.
        original.dropStashes(); TabStore.all.removeAll { $0 === original }; SharedTabs.release(original.tabs)
        let savedSpace = try XCTUnwrap(ProfileManager.shared.spaces(for: profile).first)
        let restored = TabStore(profileID: profile, space: savedSpace, session: entries, selected: second.id)
        stores.append(restored)
        XCTAssertEqual(restored.current, second.id)
        let restoredFirst = try XCTUnwrap(restored.tabs.first { $0.id == first.id })
        let restoredSecond = try XCTUnwrap(restored.tabs.first { $0.id == second.id })
        XCTAssertNil(restoredFirst.existingWeb, "Unselected restored rows stay lazy")
        XCTAssertEqual(restoredSecond.kind, .pinned)
        XCTAssertEqual(restoredSecond.homeURL, try server.url("/second-history"))
        for (tab, path) in [(restoredFirst, "/first-history"), (restoredSecond, "/second-history")] {
            tab.resume()
            XCTAssertEqual(tab.currentURL, sharedURL)
            XCTAssertTrue(tab.web.canGoBack)
            tab.web.goBack()
            try await compatibilityWait { !tab.web.isLoading && tab.web.url?.path == path }
            XCTAssertEqual(tab.web.title, "Page \(path)")
        }
    }
}
