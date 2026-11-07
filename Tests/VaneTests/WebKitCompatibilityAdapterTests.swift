import ExtensionResourceBridge
import Foundation
import WebKit
import XCTest

final class WebKitCompatibilityAdapterTests: XCTestCase {
    private final class BooleanPreference: NSObject {
        @objc var enabled = false
    }

    private final class IntegerPreference: NSObject {
        @objc var enabled = 0
    }

    private final class ReturningPreference: NSObject {
        var called = false
        @objc func setEnabled(_ value: Bool) -> Bool {
            called = true
            return value
        }
    }

    func testBooleanPreferenceSetterAppliesBothValues() {
        let preference = BooleanPreference()
        XCTAssertTrue(VaneSetBooleanPreference(preference, NSSelectorFromString("setEnabled:"), true))
        XCTAssertTrue(preference.enabled)
        XCTAssertTrue(VaneSetBooleanPreference(preference, NSSelectorFromString("setEnabled:"), false))
        XCTAssertFalse(preference.enabled)
    }

    func testMissingPreferenceSetterLeavesTargetUnchanged() {
        let preference = BooleanPreference()
        XCTAssertFalse(VaneSetBooleanPreference(preference, NSSelectorFromString("setMissing:"), true))
        XCTAssertFalse(preference.enabled)
    }

    func testPreferenceSetterRejectsWrongArgumentType() {
        let preference = IntegerPreference()
        XCTAssertFalse(VaneSetBooleanPreference(preference, NSSelectorFromString("setEnabled:"), true))
        XCTAssertEqual(preference.enabled, 0)
    }

    func testPreferenceSetterRejectsWrongReturnTypeWithoutCallingIt() {
        let preference = ReturningPreference()
        XCTAssertFalse(VaneSetBooleanPreference(preference, NSSelectorFromString("setEnabled:"), true))
        XCTAssertFalse(preference.called)
    }

    @MainActor func testWebKitPictureInPicturePreferenceAppliesBothValues() {
        let preference = WKPreferences()
        for enabled in [true, false] {
            XCTAssertTrue(VaneSetBooleanPreference(preference, NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:"), enabled))
            XCTAssertEqual(preference.value(forKey: "allowsPictureInPictureMediaPlayback") as? Bool, enabled)
        }
    }

    @MainActor func testWebKitInspectorPreferenceAppliesBothValues() {
        let preference = WKPreferences()
        for enabled in [true, false] {
            XCTAssertTrue(VaneSetBooleanPreference(preference, NSSelectorFromString("_setDeveloperExtrasEnabled:"), enabled))
            XCTAssertEqual(preference.value(forKey: "developerExtrasEnabled") as? Bool, enabled)
        }
    }

    @MainActor func testPublicCompatibilityOwnersPreserveDistinctIdentitiesAndCopies() {
        let browser = VaneWebProcessPoolOwner()
        let extensions = VaneWebProcessPoolOwner()
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = store
        browser.configure(configuration)
        let copied = configuration.copy() as! WKWebViewConfiguration
        XCTAssertTrue(browser.matches(configuration))
        XCTAssertTrue(browser.matches(copied))
        XCTAssertFalse(extensions.matches(configuration))
        extensions.configure(configuration)
        XCTAssertTrue(configuration.websiteDataStore === store)
        XCTAssertTrue(extensions.matches(configuration))
        XCTAssertTrue(browser.matches(copied))
    }

}
