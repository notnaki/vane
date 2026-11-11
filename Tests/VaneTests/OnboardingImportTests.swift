import AppKit
import XCTest
import SQLite3
@testable import vane

@MainActor final class OnboardingImportTests: XCTestCase {
    func testExcludedArcSectionsCannotReachTheImportPayload() throws {
        let root = URL(fileURLWithPath: "/synthetic/Arc")
        let url = URL(string: "https://selection.example.test/")!
        var sidebar = ArcSidebar()
        sidebar.spaces = [.init(id: "space", title: "Work", profileDirectory: "SidebarOnly", themeHex: nil,
                                pinned: [.tab(url: url, title: "Pinned")], today: [])]
        sidebar.favourites = ["SidebarOnly": [url]]
        var vault = ArcImport.Vault(directory: "Default", path: root.appendingPathComponent("User Data/Default"))
        vault.logins = [.init(origin: url.absoluteString, account: "Test", value: Data([1]))]
        vault.cookies = [.init(host: "selection.example.test", name: "session", path: "/", value: Data([2]), expires: 0, secure: true)]
        var scan = ArcImport.Scan(root: root, sidebar: sidebar, profiles: [], directories: ["Default", "SidebarOnly"])
        scan.vaults = ["Default": vault]
        scan.reviewedLibrary = ["Default": .init(visits: [(url, "History", Date(timeIntervalSince1970: 100))],
                                                bookmarks: [.init(url: url, title: "Bookmark", folder: nil)])]
        let candidate = OnboardingImport.Candidate(id: "arc", browser: "Arc", profile: "All profiles",
            spaces: 1, tabs: 2, bookmarks: 1, history: 1, passwords: 1, cookies: 1, payload: .arc(scan))
        for excluded in OnboardingImport.Section.allCases {
            let included = Set(OnboardingImport.Section.allCases).subtracting([excluded])
            guard case .arc(let accepted) = candidate.payload(including: included) else { return XCTFail("Expected Arc payload") }
            XCTAssertEqual(accepted.sidebar.spaces.count, excluded == .workspace ? 0 : 1)
            XCTAssertEqual(accepted.sidebar.favourites.count, excluded == .workspace ? 0 : 1)
            XCTAssertEqual(accepted.reviewedLibrary?["Default"]?.visits.count, excluded == .history ? 0 : 1)
            XCTAssertEqual(accepted.reviewedLibrary?["Default"]?.bookmarks.count, excluded == .bookmarks ? 0 : 1)
            XCTAssertEqual(accepted.vaults["Default"]?.logins.count, excluded == .passwords ? 0 : 1)
            XCTAssertEqual(accepted.vaults["Default"]?.cookies.count, excluded == .cookies ? 0 : 1)
            XCTAssertEqual(accepted.directories.contains("SidebarOnly"), excluded != .workspace)
        }
        guard case .arc(let empty) = candidate.payload(including: []) else { return XCTFail("Expected Arc payload") }
        XCTAssertFalse(empty.requiresKey, "Excluded credentials must not request a Keychain key")
        guard case .arc(let libraryOnly) = candidate.payload(including: [.history, .bookmarks]) else { return XCTFail("Expected Arc payload") }
        XCTAssertFalse(libraryOnly.requiresKey)
        XCTAssertTrue(scan.requiresKey)
        XCTAssertTrue(empty.directories.isEmpty, "Deselecting everything must not create empty imported profiles")
        XCTAssertEqual(scan.sidebar.spaces.count, 1, "Choices must not mutate the reviewed source")
        XCTAssertEqual(scan.vaults["Default"]?.logins.count, 1)
    }

    func testBrowserHistoryAndBookmarksCanBeSelectedIndependently() throws {
        let url = URL(string: "https://selection.example.test/")!
        let source = BrowserImport.Source(visits: [(url, "History", Date(timeIntervalSince1970: 100))],
                                          bookmarks: [.init(url: url, title: "Bookmark", folder: nil)])
        let candidate = OnboardingImport.Candidate(id: "chrome", browser: "Chrome", profile: "Default",
            spaces: 0, tabs: 0, bookmarks: 1, history: 1, passwords: 0, cookies: 0, payload: .browser(source))
        for (sections, history, bookmarks): (Set<OnboardingImport.Section>, Int, Int) in [
            ([.history], 1, 0), ([.bookmarks], 0, 1), ([], 0, 0)] {
            guard case .browser(let accepted) = candidate.payload(including: sections) else { return XCTFail("Expected browser payload") }
            XCTAssertEqual(accepted.visits.count, history)
            XCTAssertEqual(accepted.bookmarks.count, bookmarks)
        }
        XCTAssertEqual(source.visits.count, 1)
        XCTAssertEqual(source.bookmarks.count, 1)
    }

    func testConfirmationWritesOnlyTheIncludedBrowserSectionAndRemembersExclusions() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared // Model imports refresh menus, never open or activate windows.
        for excluded in [OnboardingImport.Section.history, .bookmarks] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("selected-import-\(UUID())")
            defer { try? FileManager.default.removeItem(at: home) }
            for name in ["Default", "Profile 1"] {
                let root = home.appendingPathComponent("Library/Application Support/Google/Chrome/" + name)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(#"{"roots":{}}"#.utf8).write(to: root.appendingPathComponent("Bookmarks"))
            }
            let url = URL(string: "https://\(UUID().uuidString.lowercased()).example.test/")!
            let source = BrowserImport.Source(visits: [(url, "Excluded history", Date(timeIntervalSince1970: 100))],
                bookmarks: [.init(url: url, title: "Selected bookmark", folder: nil)])
            let store = TabStore(space: Spaces.resolve(nil, for: ProfileManager.shared.active), session: [])
            defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
            let flow = OnboardingImport(store: store, home: home, readSource: { _ in source })
            await flow.scan()
            let first = try XCTUnwrap(flow.selected)
            let other = try XCTUnwrap(flow.candidates.first { $0.id != first.id })
            flow.setIncluded(false, section: excluded, in: first)
            flow.selectedID = other.id
            XCTAssertTrue(flow.isIncluded(excluded, in: other), "Each source owns its choices")
            flow.selectedID = first.id
            XCTAssertFalse(flow.isIncluded(excluded, in: first))
            await flow.scan()
            let rescanned = try XCTUnwrap(flow.selected)
            XCTAssertEqual(rescanned.id, first.id)
            XCTAssertFalse(flow.isIncluded(excluded, in: rescanned), "Checking again must not re-enable excluded data")
            XCTAssertTrue(flow.canConfirm)
            await flow.confirm()
            XCTAssertEqual(flow.phase, .complete, flow.status)
            let destination = Store.store(for: store.profileID)
            XCTAssertEqual(destination.history(limit: 500).contains { $0.url == url.absoluteString }, excluded != .history)
            XCTAssertEqual(destination.managedBookmarks().contains { $0.url == url.absoluteString }, excluded != .bookmarks)
        }
    }

    func testUnreadableArcCredentialsRemainDisclosedWhenNoCredentialRowsWereFound() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("unreadable-vault-import-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/Arc")
        let path = root.appendingPathComponent("User Data/Default")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"sidebar":{"containers":[{"spaces":[],"items":[]}]}}"#.utf8).write(to: root.appendingPathComponent("StorableSidebar.json"))
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#.utf8).write(to: root.appendingPathComponent("User Data/Local State"))
        try Data("Invalid database".utf8).write(to: path.appendingPathComponent("Login Data"))
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).example.test/")!
        let source = BrowserImport.Source(visits: [], bookmarks: [.init(url: url, title: "Bookmark", folder: nil)])
        let store = TabStore(space: Spaces.resolve(nil, for: ProfileManager.shared.active), session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let flow = OnboardingImport(store: store, home: home, readSource: { _ in source })
        await flow.scan()
        XCTAssertEqual(flow.selected?.passwords, 0)
        XCTAssertFalse(flow.selected?.sections.contains(.passwords) ?? true)
        await flow.confirm()
        XCTAssertEqual(flow.phase, .complete, flow.status)
        XCTAssertTrue(flow.result.contains("1 Arc data file"), flow.result)
        XCTAssertTrue(Store.store(for: store.profileID).managedBookmarks().contains { $0.url == url.absoluteString })
    }

    func testDeselectingEverySectionCannotCommitAnything() async throws {
        TestEnvironment.prepare()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("empty-selected-import-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"roots":{}}"#.utf8).write(to: root.appendingPathComponent("Bookmarks"))
        let url = URL(string: "https://\(UUID().uuidString.lowercased()).example.test/")!
        let source = BrowserImport.Source(visits: [(url, "History", Date(timeIntervalSince1970: 100))],
            bookmarks: [.init(url: url, title: "Bookmark", folder: nil)])
        let store = TabStore(space: Spaces.resolve(nil, for: ProfileManager.shared.active), session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let flow = OnboardingImport(store: store, home: home, readSource: { _ in source })
        await flow.scan()
        let candidate = try XCTUnwrap(flow.selected)
        for section in candidate.sections { flow.setIncluded(false, section: section, in: candidate) }
        XCTAssertFalse(flow.canConfirm)
        await flow.confirm()
        XCTAssertEqual(flow.phase, .review)
        let destination = Store.store(for: store.profileID)
        XCTAssertFalse(destination.history(limit: 500).contains { $0.url == url.absoluteString })
        XCTAssertFalse(destination.managedBookmarks().contains { $0.url == url.absoluteString })
        flow.setIncluded(true, section: .bookmarks, in: candidate)
        XCTAssertTrue(flow.canConfirm)
    }

    func testArcSidebarFailuresAreDisclosedWithoutDiscardingReadableLibrary() async throws {
        TestEnvironment.prepare()
        for condition in ["missing", "malformed", "denied"] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("arc-sidebar-failure-\(UUID())")
            let root = home.appendingPathComponent("Library/Application Support/Arc")
            let profile = root.appendingPathComponent("User Data/Default")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let sidebar = root.appendingPathComponent("StorableSidebar.json")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidebar.path)
                try? FileManager.default.removeItem(at: home)
            }
            try Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks","children":[{"type":"url","name":"Readable bookmark","url":"https://sidebar-fallback.example.test/"}]}}}"#.utf8)
                .write(to: profile.appendingPathComponent("Bookmarks"))
            if condition != "missing" {
                try Data("Invalid sidebar".utf8).write(to: sidebar)
                if condition == "denied" {
                    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidebar.path)
                }
            }
            let store = TabStore(isPrivate: true, session: [])
            defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
            let flow = OnboardingImport(store: store, home: home)
            await flow.scan()
            XCTAssertEqual(flow.phase, .review)
            XCTAssertEqual(flow.selected?.browser, "Arc")
            XCTAssertEqual(flow.selected?.bookmarks, 1, "Readable library data must remain available")
            XCTAssertEqual(flow.issues.count, condition == "missing" ? 0 : 1, condition)
            if condition != "missing" {
                XCTAssertEqual(flow.issues.first?.kind, condition == "denied" ? .accessDenied : .unavailable)
                XCTAssertTrue(flow.issues.first?.details.first?.message.contains("StorableSidebar.json") ?? false)
            }
            XCTAssertEqual(flow.accessBrowsers, condition == "denied" ? ["Arc"] : [])
        }
    }

    func testBlockedSupportFoldersDoNotClaimUninstalledBrowsersWereFound() throws {
        TestEnvironment.prepare()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("phantom-browser-\(UUID())")
        let roots = ["Microsoft Edge", "BraveSoftware/Brave-Browser"].map {
            home.appendingPathComponent("Library/Application Support/" + $0)
        }
        defer {
            for root in roots { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            try? FileManager.default.removeItem(at: home)
        }
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        }
        let discovery = BrowserImport.discover(home: home)
        XCTAssertTrue(discovery.profiles.isEmpty)
        XCTAssertTrue(discovery.unavailable.isEmpty, "A blocked support path does not prove that a browser is installed or has importable data")
    }

    func testReadableBrowserLibraryCanBeRecoveredWithoutTheApplicationInstalled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("removed-browser-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"roots":{}}"#.utf8).write(to: root.appendingPathComponent("Bookmarks"))
        XCTAssertEqual(BrowserImport.detect(home: home).map(\.browser), ["Brave"])
    }
    func testOrionReviewReadsEveryVisitAndBookmarkFolderWithoutWriting() async throws {
        TestEnvironment.prepare()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("orion-review-\(UUID())")
        let directory = home.appendingPathComponent("Library/Application Support/Orion/Defaults")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE history_items(ID INTEGER PRIMARY KEY, URL TEXT, TITLE TEXT);
            CREATE TABLE visits(ID INTEGER PRIMARY KEY, HISTORY_ITEM_ID INTEGER, VISIT_TIME TEXT);
            INSERT INTO history_items VALUES(1, 'https://orion.example.test/', 'An Orion page');
            INSERT INTO visits VALUES(1, 1, '2026-11-10 10:20:00'), (2, 1, '2026-11-09 10:20:00');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let bookmarks: [String: [String: Any]] = [
            "0": ["id": "0", "title": "Root", "type": "folder"],
            "1": ["id": "1", "parentId": "0", "index": 1, "title": "Reading", "type": "folder"],
            "5": ["id": "5", "parentId": "0", "index": 0, "title": "First folder", "type": "folder"],
            "2": ["id": "2", "parentId": "1", "title": "Saved page", "type": "bookmark", "url": "https://saved.example.test/"],
            "9": ["id": "9", "parentId": "5", "title": "Ordered first", "type": "bookmark", "url": "https://saved.example.test/"]]
        try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .binary, options: 0)
            .write(to: directory.appendingPathComponent("favourites.plist"))
        let store = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let flow = OnboardingImport(store: store, home: home)
        await flow.scan()
        let selected = try XCTUnwrap(flow.selected)
        XCTAssertEqual(selected.browser, "Orion")
        XCTAssertEqual(selected.history, 2)
        XCTAssertEqual(selected.bookmarks, 2)
        XCTAssertEqual(selected.items(.history).map(\.title), ["An Orion page", "An Orion page"])
        XCTAssertEqual(selected.items(.bookmarks).map(\.title), ["Ordered first", "Saved page"])
        XCTAssertEqual(selected.items(.bookmarks).first?.detail, "https://saved.example.test/")
        guard case .browser(let snapshot) = selected.payload else { return XCTFail("Expected reviewed library") }
        XCTAssertEqual(snapshot.bookmarks.first?.folder, "First folder", "Duplicate URLs must retain source order before destination deduplication")
        XCTAssertEqual(snapshot.visits.first?.at.timeIntervalSince1970, 1794306000)
        XCTAssertEqual(flow.phase, .review)
        XCTAssertTrue(store.tabs.isEmpty)
    }
    func testDiscoveryIncludesZenAndOrionAtTheirKnownLocations() throws {
        TestEnvironment.prepare()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("other-browsers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        for (directory, file) in [("zen/Profiles/test.default", "places.sqlite"), ("Orion/Defaults", "history")] {
            let profile = home.appendingPathComponent("Library/Application Support/" + directory)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data().write(to: profile.appendingPathComponent(file))
        }
        XCTAssertEqual(Set(BrowserImport.detect(home: home).map(\.browser)), ["Zen", "Orion"])
    }

    func testDiscoveryReportsAnUninspectableBrowserInsteadOfSilentlyHidingIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-browser-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/Google")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let browser = root.appendingPathComponent("Chrome")
        try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browser.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: browser.path)
        let discovery = BrowserImport.discover(home: home, installedBrowsers: ["Chrome"])
        XCTAssertTrue(discovery.profiles.isEmpty)
        XCTAssertEqual(discovery.unavailable, ["Chrome"])
    }

    func testReadOnlyAndMissingJournalErrorsAreNotCalledBusyOrPrivacyDenials() {
        let file = URL(fileURLWithPath: "/synthetic/History")
        for code in [SQLITE_READONLY, SQLITE_CANTOPEN] {
            let failure = BrowserImport.snapshotFailure(file, code: code)
            XCTAssertEqual(failure.kind, .unavailable)
            XCTAssertFalse(BrowserImport.accessDenied(failure))
            XCTAssertTrue(failure.localizedDescription.contains("SQLite \(code)"))
        }
    }

    func testBusyHistoryIsNotDescribedAsMissingPrivacyPermission() throws {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("busy-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "CREATE TABLE test(value); BEGIN EXCLUSIVE; INSERT INTO test VALUES(1)", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try BrowserImport.snapshot(file) { _ in true }) { error in
            XCTAssertEqual((error as? BrowserImport.Failure)?.kind, .busy)
            XCTAssertFalse(BrowserImport.accessDenied(error))
        }
    }

    func testLibraryWarningsAreGroupedAndOnlyDeniedReadsOfferPrivacySettings() async throws {
        TestEnvironment.prepare()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("group-import-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/Arc")
        for directory in ["Default", "Profile 1"] {
            let path = root.appendingPathComponent("User Data/" + directory)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data().write(to: path.appendingPathComponent("History"))
        }
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"sidebar":{"containers":[{"spaces":[],"items":[]}]}}"#.utf8).write(to: root.appendingPathComponent("StorableSidebar.json"))
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#.utf8)
            .write(to: root.appendingPathComponent("User Data/Local State"))
        let store = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        for kind in [BrowserImport.Failure.Kind.busy, .accessDenied, .unavailable] {
            let flow = OnboardingImport(store: store, home: home, readSource: { profile in
                throw BrowserImport.Failure("Source failure for " + profile.profile, kind: kind)
            })
            await flow.scan()
            XCTAssertEqual(flow.issues.count, 1)
            XCTAssertEqual(flow.issues.first?.profiles.count, 2)
            let details = try XCTUnwrap(flow.issues.first?.details)
            XCTAssertEqual(Set(details.map(\.message)), Set(details.map { "Source failure for " + $0.profile }))
            XCTAssertEqual(flow.accessBrowsers, kind == .accessDenied ? ["Arc"] : [])
            XCTAssertEqual(flow.candidates.count, 1, "Read failures must not discard the other reviewed Arc data")
        }
    }
    func testDiscoveryUsesKnownLocationsAndReviewsAnImmutableSnapshotBeforeWriting() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared // Menu refresh needs AppKit, without activating or opening a window.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-import-\(UUID())")
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = profile.appendingPathComponent("Bookmarks")
        try Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks","children":[{"type":"url","name":"Example","url":"https://example.test/"}]}}}"#.utf8).write(to: file)
        let destination = TabStore(space: Spaces.resolve(nil, for: ProfileManager.shared.active), session: [])
        defer { TabStore.all.removeAll { $0 === destination }; SharedTabs.release(destination.tabs) }
        let flow = OnboardingImport(store: destination, home: home)
        await flow.scan()
        XCTAssertEqual(flow.candidates.count, 1)
        XCTAssertEqual(flow.selected?.browser, "Chrome")
        XCTAssertEqual(flow.selected?.bookmarks, 1)
        XCTAssertEqual(flow.selected?.history, 0)
        XCTAssertEqual(flow.selected?.items(.bookmarks).first?.title, "Example")
        XCTAssertEqual(flow.selected?.items(.bookmarks).first?.detail, "https://example.test/")
        XCTAssertEqual(flow.phase, .review)
        // The user confirmed the reviewed snapshot, not a later changed source file.
        try Data("malformed replacement".utf8).write(to: file)
        await flow.confirm()
        XCTAssertEqual(flow.phase, .complete)
        XCTAssertTrue(flow.result.contains("1 bookmark"), flow.result)
    }

    func testArcDiscoveryCountsAndRetainsItsReviewedLibrary() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared // Menu refresh needs AppKit, without activating or opening a window.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("arc-onboarding-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/Arc")
        let profile = root.appendingPathComponent("User Data/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"sidebar":{"containers":[{"spaces":[],"items":[]}]}}"#.utf8)
            .write(to: root.appendingPathComponent("StorableSidebar.json"))
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#.utf8)
            .write(to: root.appendingPathComponent("User Data/Local State"))
        let file = profile.appendingPathComponent("Bookmarks")
        try Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks","children":[{"type":"url","name":"Arc example","url":"https://arc.example.test/"}]}}}"#.utf8).write(to: file)
        let store = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let flow = OnboardingImport(store: store, home: home)
        await flow.scan()
        let candidate = try XCTUnwrap(flow.selected)
        XCTAssertEqual(flow.candidates.count, 1, "Arc must not also appear as a duplicate Chromium source")
        XCTAssertEqual(candidate.browser, "Arc")
        XCTAssertEqual(candidate.bookmarks, 1)
        XCTAssertTrue(candidate.summary.contains("1 bookmark"))
        guard case .arc(let snapshot) = candidate.payload else { return XCTFail("Expected full Arc snapshot") }
        try Data("changed after review".utf8).write(to: file)
        XCTAssertEqual(snapshot.reviewedLibrary?["Default"]?.bookmarks.count, 1)
        // An unavailable destination preserves review data and supplies a visible error.
        await flow.confirm()
        XCTAssertEqual(flow.phase, .failed)
        XCTAssertFalse(flow.status.isEmpty)
        XCTAssertTrue(flow.status.contains("regular Vane profile"))
        XCTAssertEqual(flow.candidates.count, 1)
    }

    func testCanceledArcReadCannotPublishIntoTheFollowingReview() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared // Menu refresh needs AppKit, without activating or opening a window.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("arc-cancel-\(UUID())")
        let root = home.appendingPathComponent("Library/Application Support/Arc")
        let profile = root.appendingPathComponent("User Data/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"sidebar":{"containers":[{"spaces":[],"items":[]}]}}"#.utf8)
            .write(to: root.appendingPathComponent("StorableSidebar.json"))
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#.utf8)
            .write(to: root.appendingPathComponent("User Data/Local State"))
        try Data(#"{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks","children":[{"type":"url","name":"Example","url":"https://cancel.example.test/"}]}}}"#.utf8)
            .write(to: profile.appendingPathComponent("Bookmarks"))
        let store = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let gate = OnboardingReadGate()
        defer { gate.release.signal() }
        let flow = OnboardingImport(store: store, home: home, readSource: { profile in
            let source = try BrowserImport.readSource(from: profile)
            if gate.holdFirst() { _ = gate.release.wait(timeout: .now() + 5) }
            return source
        })
        let first = Task { await flow.scan() }
        defer { first.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !gate.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(gate.started, "The exact Arc library read must be blocked before canceling")
        flow.cancelScan(); first.cancel()
        await flow.scan()
        XCTAssertEqual(flow.phase, .review)
        XCTAssertEqual(flow.candidates.count, 1)
        gate.release.signal()
        await first.value
        XCTAssertEqual(flow.phase, .review)
        XCTAssertEqual(flow.candidates.count, 1, "The canceled scan must not append duplicate Arc IDs to the new review")
        XCTAssertTrue(flow.issues.isEmpty)
    }

    func testNoSourcesHasAnExplicitEmptyStateAndNoFolderFallback() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared // Menu refresh needs AppKit, without activating or opening a window.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("empty-browser-scan-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let destination = TabStore(isPrivate: true, session: [])
        defer { TabStore.all.removeAll { $0 === destination }; SharedTabs.release(destination.tabs) }
        let flow = OnboardingImport(store: destination, home: home)
        await flow.scan()
        XCTAssertEqual(flow.phase, .review)
        XCTAssertTrue(flow.candidates.isEmpty)
        XCTAssertNil(flow.selected)
        await flow.confirm()
        XCTAssertEqual(flow.phase, .review)
    }
}

private final class OnboardingReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    let release = DispatchSemaphore(value: 0)
    var started: Bool { lock.withLock { held } }
    func holdFirst() -> Bool {
        lock.withLock {
            guard !held else { return false }
            held = true; return true
        }
    }
}
