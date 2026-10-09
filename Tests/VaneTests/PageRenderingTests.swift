import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PageRenderingTests: XCTestCase {
    private func prefers60FPS(_ preferences: WKPreferences) throws -> Bool {
        let features = NSSelectorFromString("_features")
        let getter = NSSelectorFromString("_isEnabledForFeature:")
        guard WKPreferences.responds(to: features), preferences.responds(to: getter),
              let all = WKPreferences.perform(features)?.takeUnretainedValue() as? [NSObject],
              let feature = all.first(where: {
                  $0.responds(to: NSSelectorFromString("key")) &&
                  $0.perform(NSSelectorFromString("key"))?.takeUnretainedValue() as? String ==
                      "PreferPageRenderingUpdatesNear60FPSEnabled"
              }) else { throw XCTSkip("System WebKit no longer exposes the 60 fps preference") }
        typealias Getter = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(preferences.method(for: getter), to: Getter.self)(preferences, getter, feature)
    }

    private func withSaver(_ mode: BatterySaver.Mode, _ body: () throws -> Void) rethrows {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(mode)
        defer { BatterySaver.shared.setMode(previous) }
        try body()
    }

    func testNormalTabAllowsDisplayRefreshRate() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion is enabled")
        try withSaver(.off) {
            let tab = Tab(isPrivate: true)
            defer { tab.tearDown() }
            XCTAssertFalse(try prefers60FPS(tab.web.configuration.preferences))
        }
    }

    func testBatterySaverKeepsDefaultFrameRateForNewTabs() throws {
        try withSaver(.alwaysOn) {
            let tab = Tab(isPrivate: true)
            defer { tab.tearDown() }
            XCTAssertTrue(try prefers60FPS(tab.web.configuration.preferences))
        }
    }

    func testPopupAllowsDisplayRefreshRateWithoutChangingOpenerPreferences() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion is enabled")
        try withSaver(.off) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let original = try prefers60FPS(configuration.preferences)
            let tab = Tab(popup: configuration, isPrivate: true, profileID: Profile.incognito.id)
            defer { tab.tearDown() }
            XCTAssertFalse(try prefers60FPS(tab.web.configuration.preferences))
            XCTAssertEqual(try prefers60FPS(configuration.preferences), original)
        }
    }

    func testBatterySaverCapsPopupEvenWhenOpenerAllowsHighRefresh() throws {
        try withSaver(.off) {
            let opener = Tab(isPrivate: true)
            defer { opener.tearDown() }
            let configuration = opener.web.configuration
            BatterySaver.shared.setMode(.alwaysOn)
            let popup = Tab(popup: configuration, isPrivate: true, profileID: Profile.incognito.id)
            defer { popup.tearDown() }
            XCTAssertTrue(try prefers60FPS(popup.web.configuration.preferences))
            XCTAssertEqual(try prefers60FPS(opener.web.configuration.preferences),
                           NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }
}
