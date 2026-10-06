import XCTest
import WebKit
import LocalAuthentication
@testable import vane

@MainActor final class LockedFolderTests: XCTestCase {
    // Supply the new persisted flag as a session from a newer Vane version would.
    private func protected(_ folder: Folder) throws -> Folder {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(folder)) as! [String: Any]
        json["requiresAuthentication"] = true
        return try JSONDecoder().decode(Folder.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testLockedFolderHidesNestedContentsEvenWhenExpandedOnDisk() throws {
        let outer = try protected(Folder(name: "Private"))
        let inner = Folder(name: "Nested")
        let pins = Pins(entries: [.init(row: .folder(outer), parent: nil),
                                 .init(row: .folder(inner), parent: outer.id),
                                 .init(row: .tab("secret"), parent: inner.id),
                                 .init(row: .tab("public"), parent: nil)])
        XCTAssertEqual(pins.visible.map(\.entry.id), [outer.id.uuidString, "public"])
    }

    func testLockedTabCannotBecomeActiveOrBeMovedOut() throws {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer {
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        let tab = store.newBlankTab(focus: false, as: .pinned)
        let folder = try protected(Folder(name: "Private"))
        store.pins = Pins(entries: [.init(row: .folder(folder), parent: nil),
                                   .init(row: .tab(tab.id.uuidString), parent: folder.id)])
        store.current = tab.id
        XCTAssertNil(store.active)
        XCTAssertTrue(store.onScreenTabs.isEmpty)
        store.dropAtSectionRoot([tab.id], into: .pinned)
        XCTAssertEqual(store.pins.spot(of: tab.id.uuidString)?.parent, folder.id)
        store.move(tab.id, to: .today)
        XCTAssertEqual(tab.kind, .pinned)
        store.deleteFolder(folder.id)
        XCTAssertNotNil(store.pins.folder(folder.id))
    }

    func testCancelledAuthenticationCannotGrantAccess() {
        var finish: FolderAuthentication.Reply?
        let authentication = FolderAuthentication { _, reply in finish = reply; return nil }
        let profile = UUID(), folder = UUID()
        var result: Bool?
        authentication.unlock(folder, profile: profile, reason: "Unlock") { result = $0 }
        finish?(false)
        XCTAssertEqual(result, false)
        XCTAssertTrue(authentication.grants(for: profile).isEmpty)
    }

    func testRelockingInvalidatesSuccessfulButStaleAuthenticationReply() {
        var finish: FolderAuthentication.Reply?
        let authentication = FolderAuthentication { _, reply in finish = reply; return nil }
        let profile = UUID(), folder = UUID()
        var result: Bool?
        authentication.unlock(folder, profile: profile, reason: "Unlock") { result = $0 }
        authentication.lock(folder, profile: profile)
        finish?(true)
        XCTAssertEqual(result, false)
        XCTAssertTrue(authentication.grants(for: profile).isEmpty)
    }

    func testSessionLockCancelsPendingRepliesAndClearsAllGrants() {
        var finishes: [FolderAuthentication.Reply] = []
        let authentication = FolderAuthentication { _, reply in finishes.append(reply); return nil }
        let profile = UUID(), first = UUID(), second = UUID()
        authentication.unlock(first, profile: profile, reason: "Unlock") { _ in }
        finishes[0](true)
        XCTAssertEqual(authentication.grants(for: profile), [first])
        authentication.unlock(second, profile: profile, reason: "Unlock") { _ in }
        authentication.lockAll()
        finishes[1](true)
        XCTAssertTrue(authentication.grants(for: profile).isEmpty)
    }

    func testGrantDoesNotUnlockSameFolderIdentityInAnotherProfileOrSession() {
        let authentication = FolderAuthentication { _, reply in reply(true); return nil }
        let profile = UUID(), folder = UUID()
        authentication.unlock(folder, profile: profile, reason: "Unlock") { _ in }
        XCTAssertEqual(authentication.grants(for: profile), [folder])
        XCTAssertTrue(authentication.grants(for: UUID()).isEmpty)
        XCTAssertTrue(FolderAuthentication().grants(for: profile).isEmpty)
    }

    func testLockingOpenTabKeepsLockedPageAndUnlockReturnsToIt() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        var finish: FolderAuthentication.Reply?
        store.folderAuthentication = FolderAuthentication { _, reply in finish = reply; return nil }
        let tab = store.newBlankTab(focus: false, as: .pinned)
        let folder = store.pins.newFolder(named: "Private")!
        store.pins.move(tab.id.uuidString, into: folder.id)
        store.current = tab.id

        store.lockFolder(folder.id)

        XCTAssertEqual(store.current, tab.id)
        XCTAssertEqual(store.lockedPageFolder?.id, folder.id)
        XCTAssertNil(store.active)
        XCTAssertNil(tab.existingWeb)
        XCTAssertTrue(tab.suspended)
        XCTAssertTrue(store.accessibleTabs.isEmpty)
        XCTAssertEqual(SidebarRows(tabs: store.accessibleTabs, splits: [], shape: store.pins,
                                   unlocked: store.unlockedFolders).rows.map(\.id), [folder.id.uuidString])
        store.toggleFolder(folder.id)
        finish?(true)
        XCTAssertNil(store.lockedPageFolder)
        XCTAssertEqual(store.active?.id, tab.id)
        XCTAssertFalse(store.pins.folder(folder.id)!.collapsed)
        XCTAssertEqual(store.accessibleTabs.map(\.id), [tab.id])
    }

    func testNestedFolderRequiresBothGrantsAndOuterRelockRevokesInnerGrant() throws {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        store.folderAuthentication = FolderAuthentication { _, reply in reply(true); return nil }
        let outer = try protected(Folder(name: "Outer"))
        let inner = try protected(Folder(name: "Inner"))
        let tab = store.newBlankTab(focus: false, as: .pinned)
        store.pins = Pins(entries: [.init(row: .folder(outer), parent: nil),
                                   .init(row: .folder(inner), parent: outer.id),
                                   .init(row: .tab(tab.id.uuidString), parent: inner.id)])
        store.unlockFolder(inner.id)
        XCTAssertFalse(store.isTabLocked(tab.id))
        store.lockFolder(outer.id)
        XCTAssertTrue(store.unlockedFolders.isEmpty)
        XCTAssertTrue(store.isTabLocked(tab.id))
    }

    func testLibraryCardCannotExposeLockedFolderContentsAsLooseURLs() throws {
        let secret = URL(string: "https://secret.example")!
        let publicURL = URL(string: "https://public.example")!
        let folder = try protected(Folder(name: "Private"))
        let shape = Pins(entries: [.init(row: .folder(folder), parent: nil),
                                  .init(row: .tab(secret.absoluteString), parent: folder.id),
                                  .init(row: .tab(publicURL.absoluteString), parent: nil)])
        let rows = Library.cardRows(shape: shape, urls: [secret, publicURL])
        XCTAssertEqual(rows.compactMap(\.url), [publicURL])
        XCTAssertEqual(rows.compactMap(\.folder?.id), [folder.id])
    }

    func testOldFoldersDecodeAndProtectionSurvivesRelaunchWithoutGrant() throws {
        let old = Data(#"{"id":"E32B2C20-C76D-4A68-B6B7-EC49AC309C54","name":"Old","icon":"folder","collapsed":false}"#.utf8)
        let legacy = try JSONDecoder().decode(Folder.self, from: old)
        XCTAssertNil(legacy.requiresAuthentication)
        let folder = try protected(legacy)
        let shape = Pins(entries: [.init(row: .folder(folder), parent: nil),
                                  .init(row: .tab("secret"), parent: folder.id)])
        XCTAssertEqual(shape.visible(unlocked: [folder.id]).compactMap(\.entry.tab), ["secret"])
        let restored = try JSONDecoder().decode(Pins.self, from: JSONEncoder().encode(shape))
        XCTAssertTrue(restored.folder(folder.id)!.requiresAuthentication!)
        XCTAssertTrue(restored.visible.compactMap(\.entry.tab).isEmpty)
    }

    func testSharedWindowsLockTogetherAndKeepTheirCurrentPage() {
        TestEnvironment.prepare()
        let profile = UUID()
        let space = Space(name: "Shared", profileID: profile)
        ProfileManager.shared.saveSpaces([space], for: profile)
        let first = TabStore(profileID: profile, space: space, session: [])
        let second = TabStore(profileID: profile, space: space, session: [])
        defer { cleanUp(first); cleanUp(second) }
        let authentication = FolderAuthentication { _, reply in reply(true); return nil }
        first.folderAuthentication = authentication
        second.folderAuthentication = authentication
        let tab = first.newBlankTab(focus: false, as: .pinned)
        let folder = first.pins.newFolder(named: "Private")!
        first.pins.move(tab.id.uuidString, into: folder.id)
        SharedTabs.flush()
        first.current = tab.id
        second.current = tab.id
        tab.windowSnapshot = NSImage(size: NSSize(width: 640, height: 480))
        first.lockFolder(folder.id)
        for store in [first, second] {
            XCTAssertNotNil(store.lockedFolderBackdrop, "Every window captures before the shared page is released")
            XCTAssertEqual(store.current, tab.id)
            XCTAssertEqual(store.lockedPageFolder?.id, folder.id)
            XCTAssertNil(store.active)
            XCTAssertTrue(store.accessibleTabs.isEmpty)
        }
        first.unlockFolder(folder.id)
        XCTAssertEqual(first.active?.id, tab.id)
        XCTAssertEqual(second.active?.id, tab.id)
    }

    func testLockedTodayTabsAreExcludedFromBulkSelectionAndParentArchive() throws {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let secret = store.newBlankTab(focus: false)
        let publicTab = store.newBlankTab(focus: false)
        let outer = Folder(name: "Outer")
        let inner = try protected(Folder(name: "Private"))
        store.todayShape = Pins(entries: [.init(row: .folder(outer), parent: nil),
                                         .init(row: .folder(inner), parent: outer.id),
                                         .init(row: .tab(secret.id.uuidString), parent: inner.id),
                                         .init(row: .tab(publicTab.id.uuidString), parent: nil)])
        store.current = publicTab.id
        store.selectAllTabs()
        XCTAssertEqual(store.selectedTabs.map(\.id), [publicTab.id])
        store.archiveFolder(outer.id, in: \.todayShape)
        XCTAssertTrue(store.tabs.contains { $0.id == secret.id })
        XCTAssertEqual(store.todayShape.spot(of: secret.id.uuidString)?.parent, inner.id)
    }

    func testLockedPaneCannotRenderThroughAnotherPaneOfSplit() throws {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let secret = store.newBlankTab(focus: false, as: .pinned)
        let publicTab = store.newBlankTab(focus: false)
        let folder = try protected(Folder(name: "Private"))
        store.pins = Pins(entries: [.init(row: .folder(folder), parent: nil),
                                   .init(row: .tab(secret.id.uuidString), parent: folder.id)])
        store.splits = [Split(tabs: [secret.id, publicTab.id])!.focusing(publicTab.id)]
        store.current = publicTab.id
        XCTAssertEqual(store.lockedPageFolder?.id, folder.id)
        XCTAssertNil(store.activeSplit)
        XCTAssertFalse(store.onScreenTabs.contains { $0.id == secret.id })
    }

    func testExtensionCannotReadOrNavigatePreviouslyRetainedLockedTab() async throws {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"manifest_version":3,"name":"Folder test","version":"1.0"}"#.utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let tab = store.newBlankTab(focus: false, as: .pinned)
        tab.open(URL(string: "https://secret.example")!, parked: nil)
        let folder = store.pins.newFolder(named: "Private")!
        store.pins.move(tab.id.uuidString, into: folder.id)
        let adapter = ExtTab(tab, in: store)
        store.lockFolder(folder.id)
        XCTAssertTrue(ExtWindow(store).tabs(for: context).isEmpty)
        XCTAssertNil(adapter.url(for: context))
        XCTAssertNil(adapter.title(for: context))
        XCTAssertNil(adapter.webView(for: context))
        XCTAssertFalse(adapter.shouldGrantPermissionsOnUserGesture(for: context))
        var error: Error?
        adapter.loadURL(URL(string: "https://leak.example")!, for: context) { error = $0 }
        XCTAssertNotNil(error)
        XCTAssertNil(tab.existingWeb)
        do {
            try await adapter.activate(for: context)
            XCTFail("A retained extension adapter cannot activate a protected tab")
        } catch {}
    }

    func testDefaultUnlockStaysInPageUntilAnAuthenticationAction() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        store.folderAuthentication = FolderAuthentication()
        store.folderAuthentication.inlineAvailable = { true }
        Prefs.folderUnlockMethod = .touchID
        let tab = store.newBlankTab(focus: false, as: .pinned)
        let folder = store.pins.newFolder(named: "Private")!
        store.pins.move(tab.id.uuidString, into: folder.id)
        store.lockFolder(folder.id)
        var result: Bool?
        store.unlockFolder(folder.id) { result = $0 }
        XCTAssertEqual(store.folderUnlockPage?.id, folder.id)
        XCTAssertNotNil(store.folderUnlockRequest)
        XCTAssertNil(result)
        XCTAssertTrue(store.isTabLocked(tab.id))
        store.runFolderUnlock(using: { _, reply in reply(false); return nil }) { _ in }
        XCTAssertTrue(store.isTabLocked(tab.id))
        XCTAssertNotNil(store.folderUnlockRequest, "A failed attempt stays inline for retry")
        store.runFolderUnlock(using: { _, reply in reply(true); return nil }) { _ in }
        XCTAssertEqual(result, true)
        XCTAssertNil(store.folderUnlockRequest)
        XCTAssertFalse(store.isTabLocked(tab.id))
    }

    func testCancellingInlineUnlockRejectsLateAuthentication() {
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        store.folderAuthentication = FolderAuthentication()
        store.folderAuthentication.inlineAvailable = { true }
        Prefs.folderUnlockMethod = .touchID
        let folder = store.pins.newFolder(named: "Private")!
        store.lockFolder(folder.id)
        var result: Bool?
        store.unlockFolder(folder.id) { result = $0 }
        var finish: FolderAuthentication.Reply?
        store.runFolderUnlock(using: { _, reply in finish = reply; return nil }) { _ in }
        store.cancelFolderUnlock()
        finish?(true)
        XCTAssertEqual(result, false)
        XCTAssertNil(store.folderUnlockRequest)
        XCTAssertTrue(store.isFolderLocked(folder.id))
    }

    func testInlineControlRetiresSuccessfulContextEvenWhenNestedPageStaysMounted() {
        let control = FolderUnlockControl()
        let authenticated = control.context
        control.finish(true)
        XCTAssertFalse(control.context === authenticated)
        var error: NSError?
        XCTAssertFalse(authenticated.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error))
        XCTAssertEqual(error?.code, LAError.invalidContext.rawValue)
        let failed = control.context
        control.finish(false)
        XCTAssertFalse(control.context === failed)
        XCTAssertTrue(control.failed)
        let cancelled = control.context
        control.cancel()
        XCTAssertFalse(control.context === cancelled)
        XCTAssertFalse(control.failed)
        XCTAssertFalse(control.authenticating)
        error = nil
        XCTAssertFalse(cancelled.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error))
        XCTAssertEqual(error?.code, LAError.invalidContext.rawValue)
    }

    func testUnavailableTouchIDAndSystemPreferenceOpenNativeAuthenticationDirectly() {
        TestEnvironment.prepare()
        let previous = Prefs.folderUnlockMethod
        defer { Prefs.folderUnlockMethod = previous }
        for (available, method) in [(false, FolderUnlockMethod.touchID), (true, .system)] {
            let store = TabStore(profileID: UUID(), session: [])
            defer { cleanUp(store) }
            let authentication = FolderAuthentication()
            authentication.inlineAvailable = { available }
            var nativeRequests = 0
            authentication.systemAuthenticator = { _, reply in
                nativeRequests += 1
                reply(true)
                return nil
            }
            store.folderAuthentication = authentication
            Prefs.folderUnlockMethod = method
            let folder = store.pins.newFolder(named: "Private")!
            store.lockFolder(folder.id)
            var result: Bool?
            store.unlockFolder(folder.id) { result = $0 }
            XCTAssertEqual(nativeRequests, 1)
            XCTAssertEqual(result, true)
            XCTAssertNil(store.folderUnlockRequest, "Native authentication needs no second inline action")
            XCTAssertFalse(store.isFolderLocked(folder.id))
        }
    }

    func testSwitchingToSystemCompletesAnAlreadyPresentedInlineRequest() {
        TestEnvironment.prepare()
        let previous = Prefs.folderUnlockMethod
        defer { Prefs.folderUnlockMethod = previous }
        let store = TabStore(profileID: UUID(), session: [])
        defer { cleanUp(store) }
        let authentication = FolderAuthentication()
        authentication.inlineAvailable = { true }
        authentication.systemAuthenticator = { _, reply in reply(true); return nil }
        store.folderAuthentication = authentication
        let folder = store.pins.newFolder(named: "Private")!
        store.lockFolder(folder.id)
        Prefs.folderUnlockMethod = .touchID
        var inlineResult: Bool?
        store.unlockFolder(folder.id) { inlineResult = $0 }
        XCTAssertNotNil(store.folderUnlockRequest)
        Prefs.folderUnlockMethod = .system
        var nativeResult: Bool?
        store.unlockFolder(folder.id) { nativeResult = $0 }
        XCTAssertEqual(inlineResult, true)
        XCTAssertEqual(nativeResult, true)
        XCTAssertNil(store.folderUnlockRequest)
        XCTAssertNil(store.folderUnlockPage)
    }

    private func cleanUp(_ store: TabStore) {
        store.tabs.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
        Store.forget(store.profileID)
    }
}
