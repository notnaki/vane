import AppKit
import XCTest
import WebKit
@testable import vane

@MainActor final class PasswordSavePreferenceTests: XCTestCase {
    private func disabledProfile() -> UUID {
        TestEnvironment.prepare()
        let id = UUID()
        let key = ProfileManager.defaultsKey("offerToSavePasswords", id)
        UserDefaults.vane.set(false, forKey: key)
        addTeardownBlock { UserDefaults.vane.removeObject(forKey: key) }
        return id
    }

    func testPreferenceDefaultsOnAndIsIsolatedPerProfile() {
        TestEnvironment.prepare()
        let first = UUID(), other = UUID()
        defer { UserDefaults.vane.removeObject(forKey: Passwords.offerSavingKey(first)) }
        XCTAssertTrue(Passwords.offersSaving(profileID: first))
        Passwords.setOffersSaving(false, profileID: first)
        XCTAssertFalse(Passwords.offersSaving(profileID: first))
        XCTAssertTrue(Passwords.offersSaving(profileID: other))
        Passwords.setOffersSaving(true, profileID: first)
        XCTAssertTrue(Passwords.offersSaving(profileID: first))
    }

    func testDisablingDuringSnapshotRevokesInsertAndUpdate() {
        TestEnvironment.prepare()
        for update in [false, true] {
            let profile = UUID(), origin = PasswordOrigin(host: "delayed.invalid")
            let key = Passwords.offerSavingKey(profile)
            defer { UserDefaults.vane.removeObject(forKey: key) }
            var operations = Passwords.ReviewOperations()
            operations.snapshot = { _, _, _ in
                UserDefaults.vane.set(false, forKey: key)
                return (update ? "previous" : nil, nil)
            }
            operations.insert = { _, _, _, _ in XCTFail("Revoked insert reached Keychain") }
            operations.update = { _, _, _, _, _ in XCTFail("Revoked update reached Keychain") }
            XCTAssertThrowsError(try Passwords.reviewedSave(
                PendingSave(host: origin.host, account: "ada", password: "fixture", update: update),
                origin: origin, account: "ada", password: "fixture", profileID: profile, operations: operations))
        }
    }

    func testDisabledProfileCannotCommitAnAlreadyStagedOffer() async throws {
        let profile = disabledProfile()
        let tab = Tab(profileID: profile)
        defer { tab.tearDown() }
        var reader = Passwords.Reader()
        reader.commit = { _, _, _, _, _ in
            XCTFail("Disabling offers must revoke staged browser save authorization")
            return .saved
        }
        tab.passwordReader = reader
        tab.pendingSave = PendingSave(host: "preference.invalid", account: "ada", password: "fixture")
        tab.confirmSaveAsync()
        try await Passwords.flushPendingOperations()
        XCTAssertNil(tab.pendingSave)
        XCTAssertFalse(Passwords.hasPendingOperations)
    }

    func testDisabledProfileRejectsReviewedSaveBeforeReadingKeychain() {
        let profile = disabledProfile()
        let origin = PasswordOrigin(host: "preference.invalid")
        var operations = Passwords.ReviewOperations()
        operations.snapshot = { _, _, _ in XCTFail("Disabled offers must not read Keychain"); return (nil, nil) }
        operations.insert = { _, _, _, _ in XCTFail("Disabled offers must not insert credentials") }
        XCTAssertThrowsError(try Passwords.reviewedSave(
            PendingSave(host: origin.host, account: "ada", password: "fixture"),
            origin: origin, account: "ada", password: "fixture", profileID: profile, operations: operations))
    }
    private func withSubmissionDocument(_ body: (Tab, PasswordOrigin) async throws -> Void) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        let profile = UUID(), tab = Tab(profileID: profile)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 500, height: 350),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        var failure: (any Error)?
        do {
            try await LibraryFocusFixture.admitForeground(window)
            let origin = PasswordOrigin(host: "save-preference.invalid")
            tab.web.loadHTMLString("<title>Submission ready</title><p>Local credential fixture</p>",
                                   baseURL: URL(string: "https://save-preference.invalid"))
            try await compatibilityWait { tab.web.title == "Submission ready" && !tab.web.isLoading }
            XCTAssertEqual(tab.web.url.flatMap(PasswordOrigin.init(url:)), origin)
            try await body(tab, origin)
        } catch { failure = error }
        tab.tearDown()
        window.orderOut(nil); window.contentView = nil; window.close()
        UserDefaults.vane.removeObject(forKey: Passwords.offerSavingKey(profile))
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") } }
        if let failure { throw failure }
    }

    func testDisabledSubmissionDoesNotReadCredentialsOrCreateOffer() async throws {
        try await withSubmissionDocument { tab, origin in
            Passwords.setOffersSaving(false, profileID: tab.profileID)
            var reader = Passwords.Reader()
            reader.password = { _, _, _ in XCTFail("Disabled submissions must not query credentials"); return nil }
            tab.passwordReader = reader
            tab.offerSubmittedPassword(origin: origin, account: "ada", password: "fixture", attempt: "disabled")
            await Task.yield()
            try await Passwords.flushPendingOperations()
            XCTAssertNil(tab.pendingSave)
        }
    }

    func testDisablingWhileSubmissionLookupIsBlockedDoesNotPublishOffer() async throws {
        try await withSubmissionDocument { tab, origin in
            let entered = self.expectation(description: "Submission lookup admitted")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            var reader = Passwords.Reader()
            reader.password = { _, _, _ in
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
                return nil
            }
            reader.revision = { _, _, _ in nil }
            tab.passwordReader = reader
            tab.offerSubmittedPassword(origin: origin, account: "ada", password: "fixture", attempt: "delayed")
            await self.fulfillment(of: [entered], timeout: 2)
            Passwords.setOffersSaving(false, profileID: tab.profileID)
            release.signal()
            try await Passwords.flushPendingOperations()
            await Task.yield()
            XCTAssertNil(tab.pendingSave)
        }
    }

}
