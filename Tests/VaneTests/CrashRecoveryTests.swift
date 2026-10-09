import AppKit
import XCTest
@testable import vane

@MainActor final class CrashRecoveryTests: XCTestCase {
    func testTerminationBeforeFirstCommitKeepsTheRequestedURL() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let tab = Tab(isPrivate: true)
        defer { tab.tearDown() }
        let url = URL(string: "https://recovery.invalid/first-commit")!
        tab.navigate(to: url)
        tab.webViewWebContentProcessDidTerminate(tab.web)
        XCTAssertEqual(tab.currentURL, url)
        XCTAssertTrue(tab.needsRecovery)
    }

    func testUnavailableStorageAndInterruptedWriteKeepLastCompletedSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let first = try XCTUnwrap(Session.encode([[.init(url: "https://recovery.invalid/first")]]))
        let next = try XCTUnwrap(Session.encode([[.init(url: "https://recovery.invalid/next")]]))
        try first.write(to: file)
        // A partially staged write is not a published session generation.
        XCTAssertFalse(SnapshotPersistence.write(next, to: file, writer: { bytes, _, options in
            XCTAssertTrue(options.contains(.atomic))
            try bytes.prefix(8).write(to: dir.appendingPathComponent("session.json.tmp"))
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        XCTAssertEqual(RecoverySnapshots.read(file, valid: Session.readable), first)
        // Real filesystem failure during backup publication must prevent primary replacement.
        try FileManager.default.createDirectory(at: file.appendingPathExtension("previous"), withIntermediateDirectories: false)
        XCTAssertFalse(RecoverySnapshots.write(next, to: file, valid: Session.readable))
        XCTAssertEqual(try Data(contentsOf: file), first)
        try FileManager.default.removeItem(at: file.appendingPathExtension("previous"))
        XCTAssertTrue(RecoverySnapshots.write(next, to: file, valid: Session.readable))
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("previous")), first)
        XCTAssertFalse(RecoverySnapshots.write(next, to: dir.appendingPathComponent("missing/session.json"), valid: Session.readable))
    }

    func testDamagedAndFutureOriginalsArePreservedBeforeReplacement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        let good = try XCTUnwrap(Session.encode([[.init(url: "https://recovery.invalid/saved")]]))
        for original in [Data("{broken".utf8), Data(#"{"version":99,"windows":[]}"#.utf8)] {
            try original.write(to: file)
            XCTAssertTrue(RecoverySnapshots.write(good, to: file, valid: Session.readable))
            let preserved = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(".damaged-") }
            XCTAssertTrue(preserved.contains { (try? Data(contentsOf: $0)) == original })
        }
        let original = Data("{cannot archive".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        XCTAssertFalse(RecoverySnapshots.write(good, to: file, valid: Session.readable))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRecoveryPauseSurvivesSessionAndSpaceSidecar() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true, session: [])
        defer {
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
        }
        let tab = store.newBlankTab()
        let url = URL(string: "https://recovery.invalid/form")!
        tab.park(url: url, Parked(title: "Saved form", needsRecovery: true))
        XCTAssertTrue(tab.needsRecovery)
        store.current = tab.id
        tab.resume()
        XCTAssertNil(store.activePageResponder, "Focusing recovery chrome must not create a blank WebKit page")
        XCTAssertFalse(PageCapture.available(tab), "Menu validation must not create a blank WebKit page")
        XCTAssertNil(tab.existingWeb)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let space = UUID(), profile = UUID()
        XCTAssertTrue(Suspension.SpaceState.save([url.absoluteString: tab.snapshot], space: space, profileID: profile, in: dir))
        XCTAssertTrue(try XCTUnwrap(Suspension.SpaceState.load(space: space, profileID: profile, in: dir)[url.absoluteString]).needsRecovery)
        let data = try XCTUnwrap(Session.encode([[.init(url: url.absoluteString, needsRecovery: true)]]))
        XCTAssertTrue(try XCTUnwrap(Session.decode(data).first?.first?.needsRecovery))
        XCTAssertTrue(try XCTUnwrap(Session.parked([.init(url: url.absoluteString, needsRecovery: true)])[url.absoluteString]).needsRecovery)
        // A healthy older sidecar remains usable after a later publication is corrupted.
        XCTAssertTrue(Suspension.SpaceState.save([url.absoluteString: Parked(title: "Next")], space: space, profileID: profile, in: dir))
        let sidecar = Suspension.SpaceState.url(for: profile, in: dir)
        let corrupt = Data("{sidecar interrupted".utf8)
        try corrupt.write(to: sidecar)
        let fallback = try XCTUnwrap(Suspension.SpaceState.load(space: space, profileID: profile, in: dir)[url.absoluteString])
        XCTAssertEqual(fallback.title, "Saved form")
        XCTAssertTrue(fallback.needsRecovery)
        XCTAssertEqual(try Data(contentsOf: sidecar), corrupt)
    }

    func testLegacySessionFallbackKeepsPauseWhenHealthySidecarWinsMetadata() throws {
        try checkLegacySessionRecovery(unclean: false)
    }

    func testUncleanReadableLegacySessionKeepsLayoutAndExtraURLsPaused() throws {
        try checkLegacySessionRecovery(unclean: true)
    }

    private func checkLegacySessionRecovery(unclean: Bool) throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let marker = Store.directory.appendingPathComponent("running")
        let realWrite = Crash.write
        if unclean {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            Crash.write = { true }
            try Data().write(to: marker)
            XCTAssertTrue(Crash.begin())
            XCTAssertTrue(Crash.didCrashLastLaunch)
        }
        defer {
            if unclean {
                Crash.markClean()
                _ = Crash.begin()
                Crash.markClean()
                Crash.write = realWrite
            }
        }
        let profile = manager.create(name: "Legacy recovery")
        let before = Set(TabStore.all.map(ObjectIdentifier.init))
        defer {
            for store in TabStore.all where !before.contains(ObjectIdentifier(store)) {
                store.window?.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
            }
            _ = manager.delete(profile.id)
        }
        let url = URL(string: "https://recovery.invalid/legacy-post")!
        var space = Space(name: "Legacy", profileID: profile.id)
        let home = URL(string: "https://recovery.invalid/home")!
        let pinnedID = UUID()
        space.tabURLs = []
        space.pinnedTabURLs = [home]
        space.layout = SpaceLayout(tabs: [.init(id: pinnedID, url: url, kind: .pinned, title: "Pinned", home: home)],
                                   pins: Pins(entries: [.init(row: .tab(pinnedID.uuidString))]),
                                   today: Pins(), splits: [], selected: pinnedID)
        XCTAssertTrue(manager.saveSpaces([space], for: profile.id))
        XCTAssertTrue(Suspension.SpaceState.save([home.absoluteString: Parked(title: "Sidecar metadata", page: url)],
                                                space: space.id, profileID: profile.id, in: Store.directory))
        let file = ProfileManager.sessionURL(for: profile.id, in: Store.directory)
        let legacy = try JSONEncoder().encode([[url.absoluteString]])
        if unclean { try legacy.write(to: file) }
        else {
            try legacy.write(to: file.appendingPathExtension("previous"))
            try Data("{broken".utf8).write(to: file)
        }
        XCTAssertTrue(Session.restore(profile: profile))
        let store = try XCTUnwrap(TabStore.all.first { !before.contains(ObjectIdentifier($0)) && $0.profileID == profile.id })
        let tab = try XCTUnwrap(store.tabs.first { $0.id == pinnedID })
        XCTAssertEqual(tab.title, "Sidecar metadata")
        XCTAssertTrue(tab.needsRecovery, "Healthy metadata cannot clear a fallback session's recovery policy")
        XCTAssertNil(tab.existingWeb)
        XCTAssertTrue(store.tabs.allSatisfy { $0.needsRecovery && $0.existingWeb == nil })
    }

    func testSidecarFallbackPauseSurvivesSavingOrRemovingAnotherSpace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = UUID(), first = UUID(), second = UUID()
        let url = "https://recovery.invalid/other-space-post"
        let file = Suspension.SpaceState.url(for: profile, in: dir)
        for remove in [false, true] {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.appendingPathExtension("previous"))
            XCTAssertTrue(Suspension.SpaceState.save([url: Parked(title: "First")], space: first, profileID: profile, in: dir))
            XCTAssertTrue(Suspension.SpaceState.save([url: Parked(title: "Second", state: Data([1, 2, 3]))], space: second, profileID: profile, in: dir))
            try Data(contentsOf: file).write(to: file.appendingPathExtension("previous"))
            try Data("{broken".utf8).write(to: file)
            if remove {
                XCTAssertTrue(Suspension.SpaceState.remove(space: first, profileID: profile, in: dir))
            } else {
                let rows = Suspension.SpaceState.load(space: first, profileID: profile, in: dir)
                XCTAssertTrue(Suspension.SpaceState.save(rows, space: first, profileID: profile, in: dir))
            }
            let recovered = try XCTUnwrap(Suspension.SpaceState.load(space: second, profileID: profile, in: dir)[url])
            XCTAssertEqual(recovered.state, Data([1, 2, 3]))
            XCTAssertTrue(recovered.needsRecovery, "Republishing another Space must retain fallback protection")
        }
    }

    func testAllRegularProfilesRestoreTheirWindows() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let manager = ProfileManager.shared
        let first = manager.create(name: "Recovery A"), second = manager.create(name: "Recovery B")
        let before = Set(TabStore.all.map(ObjectIdentifier.init))
        defer {
            for store in TabStore.all where !before.contains(ObjectIdentifier(store)) {
                store.window?.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
            }
            _ = manager.delete(first.id)
            _ = manager.delete(second.id)
        }
        var expected: [UUID: [(Space, [Session.Entry], Split.Saved)]] = [:]
        for profile in [first, second] {
            let spaces = (0..<2).map { Space(name: "Recovery Space \($0)", profileID: profile.id) }
            XCTAssertTrue(manager.saveSpaces(spaces, for: profile.id))
            let rows = spaces.map { space in
                let url = "https://recovery.invalid/\(space.id)"
                let entries: [Session.Entry] = [
                    .init(id: UUID().uuidString, url: url, title: "Pin", kind: .pinned,
                          home: "https://recovery.invalid/home", customName: "Kept pin", needsRecovery: profile == first ? nil : true),
                    .init(id: UUID().uuidString, url: url, title: "Duplicate URL", kind: .today, needsRecovery: profile == first ? nil : true)]
                let split = Split.Saved(urls: entries.map(\.url), vertical: true, active: 1,
                                        ids: entries.compactMap(\.id), weights: [0.3, 0.7])
                return (space, entries, split)
            }
            expected[profile.id] = rows
            let bytes = try XCTUnwrap(Session.encode(rows.map { $0.1 }, splits: rows.map { [$0.2] },
                                                    spaces: spaces.map { $0.id.uuidString }, selected: rows.map { $0.1[1].id }))
            let file = ProfileManager.sessionURL(for: profile.id, in: Store.directory)
            if profile == first {
                try bytes.write(to: file.appendingPathExtension("previous"))
                try Data("{corrupt".utf8).write(to: file)
                XCTAssertFalse(Session.forget(space: spaces[0].id, in: profile.id), "A stale fallback cannot authorize a destructive Space change")
            } else { try bytes.write(to: file) }
        }
        XCTAssertTrue(Session.restore())
        let restored = TabStore.all.filter { !before.contains(ObjectIdentifier($0)) }
        XCTAssertTrue(restored.contains { $0.profileID == first.id })
        XCTAssertTrue(restored.contains { $0.profileID == second.id })
        for (profile, rows) in expected {
            for (space, entries, _) in rows {
                let store = try XCTUnwrap(restored.first { $0.profileID == profile && $0.currentSpaceID == space.id })
                XCTAssertEqual(store.tabs.map { $0.id.uuidString }, entries.compactMap(\.id))
                XCTAssertEqual(store.current?.uuidString, entries[1].id)
                XCTAssertEqual(store.tabs[0].workspaceName, "Kept pin")
                XCTAssertEqual(store.tabs[0].homeURL?.absoluteString, "https://recovery.invalid/home")
                XCTAssertEqual(store.splits.first?.weights, [0.3, 0.7])
                XCTAssertEqual(store.splits.first?.vertical, true)
                XCTAssertTrue(store.tabs.allSatisfy { $0.needsRecovery && $0.existingWeb == nil })
            }
        }
    }

    func testCorruptPrimaryReadsPreviousSnapshotWithoutReplacingOriginal() throws {
        TestEnvironment.prepare()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = UUID()
        let file = ProfileManager.sessionURL(for: profile, in: dir)
        let good = try XCTUnwrap(Session.encode([[.init(url: "https://recovery.invalid/saved")]]))
        let damaged = Data("{interrupted".utf8)
        try good.write(to: file.appendingPathExtension("previous"))
        try damaged.write(to: file)
        XCTAssertEqual(Session.urls(for: profile, in: dir).map(\.absoluteString), ["https://recovery.invalid/saved"])
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        let damagedRows = Data(#"{"version":4,"windows":[[{}]]}"#.utf8)
        try damagedRows.write(to: file)
        XCTAssertEqual(Session.urls(for: profile, in: dir).map(\.absoluteString), ["https://recovery.invalid/saved"])
    }

    func testTerminationParksActiveAndBackgroundPagesUntilExplicitNavigation() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let oldHTTPS = HTTPSOnly.enabled; HTTPSOnly.enabled = false
        defer { HTTPSOnly.enabled = oldHTTPS }
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        let store = TabStore(isPrivate: true, session: [])
        defer {
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
        }
        let background = store.newBlankTab(), active = store.newBlankTab()
        for (tab, path) in [(background, "/background-crash"), (active, "/active-crash")] {
            let url = try server.url(path)
            tab.navigate(to: url)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Page \(path)" }
            let terminated = tab.web
            tab.webViewWebContentProcessDidTerminate(terminated)
            XCTAssertTrue(tab.suspended, "Termination must leave a recoverable parked page")
            XCTAssertNil(tab.existingWeb, "A dead process must not remain mounted")
            XCTAssertEqual(tab.currentURL, url)
            XCTAssertFalse(tab.loading)
            tab.resume()
            XCTAssertNil(tab.existingWeb, "Selection must not silently reload a crashed page")
            tab.navigate(to: url)
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Page \(path)" }
            XCTAssertFalse(tab.suspended)
            // A late callback from the retired web view cannot stop the new page.
            tab.webViewWebContentProcessDidTerminate(terminated)
            XCTAssertFalse(tab.suspended)
        }
    }
}
