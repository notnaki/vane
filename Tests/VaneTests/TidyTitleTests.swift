import XCTest
@testable import vane

@MainActor final class TidyTitleTests: XCTestCase {
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

    func testOnDeviceNamingAcceptsShortTitlesButSkipsEmptyTitles() {
        XCTAssertTrue(AppleAI.worthNaming("Vane"))
        XCTAssertTrue(AppleAI.worthNaming("Project Notes"))
        XCTAssertFalse(AppleAI.worthNaming("  \n "))
    }
}
