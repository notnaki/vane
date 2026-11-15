import AppKit
import XCTest
@testable import vane

@MainActor final class PasswordManagerLifetimeTests: XCTestCase {
    override func setUp() { TestEnvironment.prepare() }

    func testExpiredAuthorizationRejectsSaveAndClearsDraft() {
        let secrets = PasswordManagerSecrets()
        secrets.beginEditing("fixture", account: "ada", password: "secret")
        XCTAssertTrue(secrets.authorizesEdit("fixture"))
        let context = secrets.secretContext
        XCTAssertFalse(secrets.authorizesEdit("fixture", now: .now + .seconds(61)))
        XCTAssertNil(secrets.editing)
        XCTAssertTrue(secrets.draftPassword.isEmpty)
        XCTAssertNotEqual(context, secrets.secretContext)
    }

    func testExpiryClearsDraftWithoutAnotherInteraction() async throws {
        let secrets = PasswordManagerSecrets()
        secrets.beginEditing("fixture", account: "ada", password: "secret", lifetime: .milliseconds(30))
        try await compatibilityWait { secrets.editing == nil }
        XCTAssertTrue(secrets.draftPassword.isEmpty)
    }

    func testSleepAndSessionLockClearDrafts() {
        let secrets = PasswordManagerSecrets()
        secrets.watchSettingsClose()
        defer { secrets.stopWatching() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            secrets.beginEditing("fixture", account: "ada", password: "secret")
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            XCTAssertFalse(secrets.authorizesEdit("fixture"))
            XCTAssertTrue(secrets.draftPassword.isEmpty)
        }
    }

    func testDeactivationClearsDraftsAndInvalidatesPendingAuthentication() {
        let secrets = PasswordManagerSecrets()
        secrets.watchSettingsClose()
        defer { secrets.stopWatching() }
        for name in [NSApplication.didResignActiveNotification] {
            secrets.editing = "fixture"
            secrets.draftPassword = "secret"
            secrets.revealed["fixture"] = "secret"
            let context = secrets.secretContext
            NotificationCenter.default.post(name: name, object: NSApp)
            XCTAssertNil(secrets.editing)
            XCTAssertTrue(secrets.draftPassword.isEmpty)
            XCTAssertTrue(secrets.revealed.isEmpty)
            XCTAssertNotEqual(secrets.secretContext, context)
        }
    }
}
