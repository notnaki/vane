import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class UIAnimationSettingsTests: XCTestCase {
    // Catch stale cached timings and a reversed speed multiplier in actual consumers.
    func testSpeedChangesAffectAnimationAndCompletionDurationsImmediately() {
        TestEnvironment.prepare()
        let key = "uiAnimationSpeed.surfaces"
        let old = UserDefaults.vane.object(forKey: key)
        defer {
            if let old { UserDefaults.vane.set(old, forKey: key) }
            else { UserDefaults.vane.removeObject(forKey: key) }
        }
        UserDefaults.vane.set(2.0, forKey: key)
        XCTAssertEqual(Look.appearDuration, 0.075, accuracy: 0.0001)
        XCTAssertEqual(Look.appear, .easeOut(duration: 0.075))
        XCTAssertEqual(Look.peekAppear, .spring(duration: 0.14, bounce: 0.12))
        UserDefaults.vane.set(0.5, forKey: key)
        XCTAssertEqual(Look.appearDuration, 0.3, accuracy: 0.0001)
        XCTAssertEqual(Look.appear, .easeOut(duration: 0.3))
        XCTAssertEqual(Look.peekAppear, .spring(duration: 0.56, bounce: 0.12))
        UserDefaults.vane.removeObject(forKey: key)
        XCTAssertEqual(Look.appearDuration, 0.15, accuracy: 0.0001)
    }

    func testInvalidStoredSpeedsFallBackToDefault() throws {
        let name = "vane-animation-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.dropScratchSuite(name) }
        for invalid in [0.0, -1, 0.1, 100, .infinity, .nan] {
            defaults.set(invalid, forKey: UIAnimation.sidebar.key)
            XCTAssertEqual(UIAnimation.sidebar.speed(in: defaults), 1)
        }
        defaults.set("broken", forKey: UIAnimation.sidebar.key)
        XCTAssertEqual(UIAnimation.sidebar.speed(in: defaults), 1)
    }

    func testResetOneAndResetAllPreserveUnrelatedPreferences() throws {
        let name = "vane-animation-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults.dropScratchSuite(name) }
        defaults.set("https://example.com", forKey: "homepage")
        defaults.set(2.0, forKey: UIAnimation.sidebar.key)
        defaults.set(0.5, forKey: UIAnimation.surfaces.key)
        UIAnimation.sidebar.reset(in: defaults)
        XCTAssertEqual(UIAnimation.sidebar.speed(in: defaults), 1)
        XCTAssertEqual(UIAnimation.surfaces.speed(in: defaults), 0.5)
        UIAnimation.resetAll(in: defaults)
        XCTAssertNil(defaults.object(forKey: UIAnimation.surfaces.key))
        XCTAssertEqual(defaults.string(forKey: "homepage"), "https://example.com")
    }

    func testSearchMatchesDescriptionsAndMultipleWords() {
        XCTAssertEqual(UIAnimation.search("  FLOATING sidebar  "), [.sidebar])
        XCTAssertEqual(UIAnimation.search("expand folders"), [.tabList])
        XCTAssertEqual(UIAnimation.search("dismiss search"), [.surfaces])
        XCTAssertTrue(UIAnimation.search("no matching animation").isEmpty)
        XCTAssertEqual(UIAnimation.search(" \n ").count, 6)
    }

    func testListAndSweepTimingsFollowTheirOwnSpeeds() {
        TestEnvironment.prepare()
        let keys = [UIAnimation.tabList.key, UIAnimation.tabClosing.key, UIAnimation.surfaces.key]
        let old = keys.map { UserDefaults.vane.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, old) {
                if let value { UserDefaults.vane.set(value, forKey: key) }
                else { UserDefaults.vane.removeObject(forKey: key) }
            }
        }
        UserDefaults.vane.set(0.25, forKey: UIAnimation.tabList.key)
        UserDefaults.vane.set(2.0, forKey: UIAnimation.tabClosing.key)
        UserDefaults.vane.set(0.5, forKey: UIAnimation.surfaces.key)
        XCTAssertEqual(Look.listSeconds, 1.12, accuracy: 0.0001)
        XCTAssertEqual(Motion.sweepDelay(1), 0.0225, accuracy: 0.0001)
        XCTAssertEqual(Motion.sweepDelay(400), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Motion.sweepDelay(3, reduced: true), 0)
        XCTAssertEqual(Look.peekAppear, .spring(duration: 0.56, bounce: 0.12),
                       "Peek follows floating panels, independently of tab-list speed")
        XCTAssertEqual(Look.statusDelay, 1.5, "Speed must not shorten the hover wait")
    }

    func testDetailPageStaysUnderAdvancedToolbarItem() throws {
        TestEnvironment.prepare()
        let tab = try XCTUnwrap(SettingsTab.all.first { $0.id == "animations" })
        XCTAssertEqual(tab.parent, "advanced")
        XCTAssertEqual(tab.toolbarID, "advanced")
        XCTAssertFalse(SettingsTab.toolbarTabs.contains { $0.id == "animations" })
        // Optional visual QA at the minimum settings width and a taller window.
        if let directory = ProcessInfo.processInfo.environment["VANE_ANIMATION_SETTINGS_SNAPSHOTS"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for dark in [false, true] {
                for height in [350.0, 650.0] {
                    let host = NSHostingView(rootView: UIAnimationsPane()
                        .font(Look.text).controlSize(.small).padding(20)
                        .frame(width: 632, height: height)
                        .background(.windowBackground)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.frame = CGRect(x: 0, y: 0, width: 632, height: height)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("\(dark ? "dark" : "light")-\(Int(height)).png"))
                }
            }
        }
    }
}
