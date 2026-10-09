import AppKit
import XCTest
@testable import vane

@MainActor final class BoostsLibraryTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    func testLibraryOffersSavedBoostsOnlyInRegularWindows() throws {
        let section = try XCTUnwrap(LibrarySection(rawValue: "boosts"))
        XCTAssertTrue(section.available(private: false))
        XCTAssertFalse(section.available(private: true))
        XCTAssertTrue(section.searchable)
    }

    func testLibraryRailOffersArchiveWithoutHistoryShortcut() {
        for isPrivate in [false, true] {
            let sections = LibrarySection.railSections(private: isPrivate)
            XCTAssertTrue(sections.contains(.archived))
            XCTAssertFalse(sections.contains(.history))
        }
    }

    func testSavedListIncludesDisabledBoostsAndExcludesOtherProfilesAndPrivateTabs() {
        let profile = UUID(), otherProfile = UUID()
        let tab = Tab(profileID: profile)
        let other = Tab(profileID: otherProfile)
        let privateTab = Tab(isPrivate: true, profileID: profile)
        defer {
            tab.tearDown(); other.tearDown(); privateTab.tearDown()
            SiteBoosts.forget(profile: profile); SiteBoosts.forget(profile: otherProfile)
        }
        var enabled = SiteBoost(); enabled.font = "Georgia"
        var disabled = enabled; disabled.enabled = false
        SiteBoosts.set(enabled, origin: "https://enabled.test", tab: tab)
        SiteBoosts.set(disabled, origin: "https://disabled.test", tab: tab)
        SiteBoosts.set(enabled, origin: "https://other.test", tab: other)
        SiteBoosts.set(enabled, origin: "https://private.test", tab: privateTab)

        XCTAssertEqual(SiteBoosts.records(profile: profile), ["https://enabled.test": enabled, "https://disabled.test": disabled])
        XCTAssertEqual(SiteBoosts.records(profile: otherProfile), ["https://other.test": enabled])
    }

    func testGlobalBoostsKeepSameSiteInDifferentProfilesAndSearchProfileNames() {
        let work = Profile(name: "Work"), home = Profile(name: "Home")
        defer { SiteBoosts.forget(profile: work.id); SiteBoosts.forget(profile: home.id) }
        var boost = SiteBoost(); boost.font = "Georgia"
        SiteBoosts.set(boost, origin: "https://example.test", profile: work.id)
        boost.enabled = false
        SiteBoosts.set(boost, origin: "https://example.test", profile: home.id)

        let rows = BoostsLibrary.entries(profiles: [work, home])
        XCTAssertEqual(rows.map(\.profileName), ["Home", "Work"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.map(\.boost.enabled), [false, true])
        XCTAssertEqual(BoostsLibrary.entries(profiles: [work, home], query: "WORK").map(\.profileID), [work.id])
        XCTAssertEqual(BoostsLibrary.entries(profiles: [work, home], query: "example.test").count, 2)
        XCTAssertTrue(BoostsLibrary.entries(profiles: [work, home], query: "missing").isEmpty)
        XCTAssertEqual(BoostsLibrary.entries(profiles: [home]).map(\.profileID), [home.id])
    }

    func testLibraryCanToggleAndDeleteSavedBoostWithoutAnOpenTab() {
        let profile = UUID(), other = UUID(), origin = "https://example.test"
        defer { SiteBoosts.forget(profile: profile); SiteBoosts.forget(profile: other) }
        var boost = SiteBoost(); boost.font = "Georgia"; boost.css = "a { color: red }"
        SiteBoosts.set(boost, origin: origin, profile: profile)
        SiteBoosts.set(boost, origin: origin, profile: other)
        boost.enabled = false
        SiteBoosts.set(boost, origin: origin, profile: profile)
        XCTAssertEqual(SiteBoosts.records(profile: profile)[origin], boost)
        XCTAssertEqual(SiteBoosts.records(profile: other)[origin]?.enabled, true)

        boost.enabled = true
        SiteBoosts.set(boost, origin: origin, profile: profile)
        XCTAssertEqual(SiteBoosts.records(profile: profile)[origin]?.css, "a { color: red }")
        SiteBoosts.set(SiteBoost(), origin: origin, profile: profile)
        XCTAssertTrue(SiteBoosts.records(profile: profile).isEmpty)
        XCTAssertEqual(SiteBoosts.records(profile: other)[origin], boost)
        SiteBoosts.set(boost, origin: "file:///tmp/invalid", profile: profile)
        XCTAssertTrue(SiteBoosts.records(profile: profile).isEmpty)
    }
}
