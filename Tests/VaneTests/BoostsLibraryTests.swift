import AppKit
import XCTest
@testable import vane

@MainActor final class BoostsLibraryTests: XCTestCase {
    override func setUp() async throws {
        WebKitPretargetDiagnostics.emit("boosts.setup.prepare.begin")
        TestEnvironment.prepare()
        WebKitPretargetDiagnostics.emit("boosts.setup.prepare.end app.begin")
        _ = NSApplication.shared
        WebKitPretargetDiagnostics.emit("boosts.setup.app.end")
    }

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
        WebKitPretargetDiagnostics.emit("boosts.method.begin profiles.begin")
        let work = Profile(name: "Work"), home = Profile(name: "Home")
        WebKitPretargetDiagnostics.emit("boosts.profiles.end")
        defer {
            WebKitPretargetDiagnostics.emit("boosts.forget-work.begin")
            SiteBoosts.forget(profile: work.id)
            WebKitPretargetDiagnostics.emit("boosts.forget-work.end forget-home.begin")
            SiteBoosts.forget(profile: home.id)
            WebKitPretargetDiagnostics.emit("boosts.forget-home.end method.end")
        }
        var boost = SiteBoost(); boost.font = "Georgia"
        WebKitPretargetDiagnostics.emit("boosts.set-work.begin")
        SiteBoosts.set(boost, origin: "https://example.test", profile: work.id)
        WebKitPretargetDiagnostics.emit("boosts.set-work.end")
        boost.enabled = false
        WebKitPretargetDiagnostics.emit("boosts.set-home.begin")
        SiteBoosts.set(boost, origin: "https://example.test", profile: home.id)
        WebKitPretargetDiagnostics.emit("boosts.set-home.end")

        WebKitPretargetDiagnostics.emit("boosts.entries-all.begin")
        let rows = BoostsLibrary.entries(profiles: [work, home])
        WebKitPretargetDiagnostics.emit("boosts.entries-all.end")
        XCTAssertEqual(rows.map(\.profileName), ["Home", "Work"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.map(\.boost.enabled), [false, true])
        WebKitPretargetDiagnostics.emit("boosts.entries-work.begin")
        XCTAssertEqual(BoostsLibrary.entries(profiles: [work, home], query: "WORK").map(\.profileID), [work.id])
        WebKitPretargetDiagnostics.emit("boosts.entries-work.end")
        WebKitPretargetDiagnostics.emit("boosts.entries-site.begin")
        XCTAssertEqual(BoostsLibrary.entries(profiles: [work, home], query: "example.test").count, 2)
        WebKitPretargetDiagnostics.emit("boosts.entries-site.end")
        WebKitPretargetDiagnostics.emit("boosts.entries-missing.begin")
        XCTAssertTrue(BoostsLibrary.entries(profiles: [work, home], query: "missing").isEmpty)
        WebKitPretargetDiagnostics.emit("boosts.entries-missing.end")
        WebKitPretargetDiagnostics.emit("boosts.entries-home.begin")
        XCTAssertEqual(BoostsLibrary.entries(profiles: [home]).map(\.profileID), [home.id])
        WebKitPretargetDiagnostics.emit("boosts.entries-home.end")
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
