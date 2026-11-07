import XCTest
@testable import vane

@MainActor final class TidyTitleTests: XCTestCase {
    private func withPin(_ body: (vane.Tab, URL) async -> Void) async {
        TestEnvironment.prepare()
        let settings = ["appleAI", "tidyTitles"].map { ($0, UserDefaults.vane.object(forKey: $0)) }
        settings.forEach { UserDefaults.vane.set(true, forKey: $0.0) }
        let profile = UUID(), url = URL(string: "https://example.com/notes")!
        let tab = Tab(profileID: profile)
        tab.restore(url: url, home: nil, parked: Parked(title: "Project Notes - Example"))
        tab.kind = .pinned
        defer {
            tab.tearDown()
            TidyTitles.forget(profile)
            settings.forEach { UserDefaults.vane.set($0.1, forKey: $0.0) }
        }
        await body(tab, url)
    }

    func testRegenerationRequiresEnabledTitleAIAndPinnedWebPage() async {
        await withPin { tab, _ in
            XCTAssertTrue(TidyTitles.canRegenerate(tab))
            tab.workspaceName = "Workspace name"
            XCTAssertFalse(TidyTitles.canRegenerate(tab))
            tab.workspaceName = nil
            UserDefaults.vane.set(false, forKey: "appleAI")
            XCTAssertFalse(TidyTitles.canRegenerate(tab))
            UserDefaults.vane.set(true, forKey: "appleAI")
            TidyTitles.enabled = false
            XCTAssertFalse(TidyTitles.canRegenerate(tab))
            TidyTitles.enabled = true
            for kind in [TabKind.today, .favourite] {
                tab.kind = kind
                XCTAssertFalse(TidyTitles.canRegenerate(tab))
            }
            tab.kind = .pinned
            tab.restore(url: URL(fileURLWithPath: "/tmp/notes.html"), home: nil,
                        parked: Parked(title: "Project Notes"))
            XCTAssertFalse(TidyTitles.canRegenerate(tab))
            let privateTab = Tab(isPrivate: true)
            defer { privateTab.tearDown() }
            privateTab.restore(url: URL(string: "https://example.com/notes")!, home: nil,
                               parked: Parked(title: "Project Notes"))
            privateTab.kind = .pinned
            XCTAssertFalse(TidyTitles.canRegenerate(privateTab))
        }
    }

    func testRegenerationBypassesCacheReplacesRenameAndRevealsFromOldName() async {
        await withPin { tab, url in
            TidyTitles.rename(tab, to: "My notes")
            await TidyTitles.regenerate(tab) { title, page in
                XCTAssertEqual(title, "Project Notes - Example")
                XCTAssertEqual(page, url)
                XCTAssertEqual(TidyTitles.title(for: tab), "My notes")
                return "Notes"
            }
            XCTAssertEqual(TidyTitles.title(for: tab), "Notes")
            XCTAssertEqual(tab.titleReveal.count, 1)
            XCTAssertEqual(tab.titleReveal.from, "My notes")
            await TidyTitles.regenerate(tab) { _, _ in "Project" }
            XCTAssertEqual(TidyTitles.title(for: tab), "Project")
            XCTAssertEqual(tab.titleReveal.count, 2)
            XCTAssertEqual(tab.titleReveal.from, "Notes")
            await TidyTitles.regenerate(tab) { _, _ in nil }
            XCTAssertEqual(TidyTitles.title(for: tab), "Project")
            XCTAssertEqual(tab.titleReveal.count, 2)
        }
    }

    func testFailedRegenerationPreservesNameAndDoesNotAnimate() async {
        await withPin { tab, _ in
            TidyTitles.rename(tab, to: "My notes")
            let answers: [String?] = [nil, "Unrelated"]
            for answer in answers {
                await TidyTitles.regenerate(tab) { _, _ in answer }
                XCTAssertEqual(TidyTitles.title(for: tab), "My notes")
                XCTAssertEqual(tab.titleReveal.count, 0)
            }
        }
    }

    func testWanderedPinRegeneratesItsHomeTitle() async {
        await withPin { tab, home in
            tab.restore(url: URL(string: "https://elsewhere.example/")!, home: home,
                        parked: Parked(title: "Unrelated Page"))
            await TidyTitles.regenerate(tab) { title, url in
                XCTAssertEqual(title, "Project Notes - Example")
                XCTAssertEqual(url, home)
                return "Notes"
            }
            XCTAssertEqual(TidyTitles.title(for: tab), "Notes")
        }
    }

    func testRegenerationDiscardsAnswerAfterRenameOrSettingsChange() async {
        await withPin { tab, _ in
            await TidyTitles.regenerate(tab) { _, _ in
                TidyTitles.rename(tab, to: "Keep this")
                return "Notes"
            }
            XCTAssertEqual(TidyTitles.title(for: tab), "Keep this")
            await TidyTitles.regenerate(tab) { _, _ in
                TidyTitles.enabled = false
                return "Notes"
            }
            TidyTitles.enabled = true
            XCTAssertEqual(TidyTitles.title(for: tab), "Keep this")
            XCTAssertEqual(tab.titleReveal.count, 0)
        }
    }

    func testLatestRegenerationWinsWhenAnswersArriveOutOfOrder() async {
        await withPin { tab, _ in
            await TidyTitles.regenerate(tab) { _, _ in
                await TidyTitles.regenerate(tab) { _, _ in "Notes" }
                return "Project"
            }
            XCTAssertEqual(TidyTitles.title(for: tab), "Notes")
            XCTAssertEqual(tab.titleReveal.count, 1)
        }
    }

    func testRegenerationDoesNotAnimateAnUnchangedName() async {
        await withPin { tab, _ in
            TidyTitles.rename(tab, to: "Notes")
            await TidyTitles.regenerate(tab) { _, _ in "Notes" }
            XCTAssertNil(TabActions.rename(tab))
            XCTAssertEqual(TidyTitles.title(for: tab), "Notes")
            XCTAssertEqual(tab.titleReveal.count, 0)
        }
    }

    func testRegenerationDiscardsAnswerAfterUnpinOrProviderChange() async {
        await withPin { tab, _ in
            await TidyTitles.regenerate(tab) { _, _ in
                tab.kind = .today
                return "Notes"
            }
            XCTAssertEqual(tab.titleReveal.count, 0)
            tab.kind = .pinned
            await TidyTitles.regenerate(tab) { _, _ in
                BrowserAI.settingsChanged()
                return "Notes"
            }
            XCTAssertEqual(TidyTitles.title(for: tab), "Project Notes")
            XCTAssertEqual(tab.titleReveal.count, 0)
        }
    }

    func testShortTitlesCanReceiveGeneratedNames() async {
        let url = URL(string: "https://example.com/notes")!
        let result = await TidyTitles.tidy(title: "Project Notes", url: url) { title, page in
            XCTAssertEqual(title, "Project Notes")
            XCTAssertEqual(page, url)
            return "Notes"
        }
        XCTAssertEqual(result, .init(text: "Notes", fromModel: true))
    }

    func testCleanedShortTitlesCanStillReceiveGeneratedNames() async {
        let result = await TidyTitles.tidy(title: "Project Notes - Example",
            url: URL(string: "https://example.com/notes")!) { _, _ in "Notes" }
        XCTAssertEqual(result, .init(text: "Notes", fromModel: true))
    }

    func testUnavailableModelKeepsCleanedTitle() async {
        let result = await TidyTitles.tidy(title: "Project Notes - Example",
            url: URL(string: "https://example.com/notes")!) { _, _ in nil }
        XCTAssertEqual(result, .init(text: "Project Notes", fromModel: false))
    }

    func testUngroundedModelNameKeepsCleanedTitle() async {
        let result = await TidyTitles.tidy(title: "Project Notes - Example",
            url: URL(string: "https://example.com/notes")!) { _, _ in "Unrelated" }
        XCTAssertEqual(result, .init(text: "Project Notes", fromModel: false))
    }

    func testGeneratedNameAppliesToFavoritesAndPinsWhileManualNamesWin() {
        TestEnvironment.prepare()
        let profile = UUID(), url = URL(string: "https://example.com/notes")!
        let wasEnabled = TidyTitles.enabled
        TidyTitles.enabled = true
        UserDefaults.vane.set([url.absoluteString: "Notes"],
            forKey: ProfileManager.defaultsKey("tidyTitleCacheV2", profile))
        let tab = Tab(profileID: profile)
        defer {
            tab.tearDown()
            TidyTitles.forget(profile)
            TidyTitles.enabled = wasEnabled
        }
        tab.restore(url: url, home: nil, parked: Parked(title: "Project Notes"))
        XCTAssertEqual(TidyTitles.title(for: tab), "Project Notes")
        for kind in [TabKind.favourite, .pinned] {
            tab.kind = kind
            XCTAssertEqual(TidyTitles.title(for: tab), "Notes")
        }
        TidyTitles.rename(tab, to: "My notes")
        XCTAssertEqual(TidyTitles.title(for: tab), "My notes")
        TidyTitles.enabled = false
        XCTAssertEqual(TidyTitles.title(for: tab), "My notes")
        TidyTitles.rename(tab, to: nil)
        XCTAssertEqual(TidyTitles.title(for: tab), "Project Notes")
    }

    func testExistingSavedTabsRefreshNamesWhenHomeTitleArrives() async {
        TestEnvironment.prepare()
        let wasEnabled = TidyTitles.enabled
        let wasAIEnabled = UserDefaults.vane.object(forKey: "appleAI")
        TidyTitles.enabled = true
        UserDefaults.vane.set(false, forKey: "appleAI")
        defer {
            TidyTitles.enabled = wasEnabled
            UserDefaults.vane.set(wasAIEnabled, forKey: "appleAI")
        }
        for kind in [TabKind.favourite, .pinned] {
            let profile = UUID(), url = URL(string: "https://example.com/notes")!
            let tab = Tab(profileID: profile)
            defer { tab.tearDown(); TidyTitles.forget(profile) }
            tab.restore(url: url, home: nil, parked: Parked(title: "Project Notes - Example"))
            tab.kind = kind
            XCTAssertNotNil(TidyTitles.pinnedName(for: url, in: profile))
            TidyTitles.note(tab)
            let cacheKey = ProfileManager.defaultsKey("tidyTitleCacheV2", profile)
            for _ in 0..<50 {
                if UserDefaults.vane.dictionary(forKey: cacheKey) != nil { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(UserDefaults.vane.dictionary(forKey: cacheKey)?[url.absoluteString] as? String,
                           "Project Notes", "Saved rows must fill the new cache on their next home title")
        }
    }

    func testOnDeviceNamingAcceptsShortTitlesButSkipsEmptyTitles() {
        XCTAssertTrue(AppleAI.worthNaming("Vane"))
        XCTAssertTrue(AppleAI.worthNaming("Project Notes"))
        XCTAssertFalse(AppleAI.worthNaming("  \n "))
    }
}
