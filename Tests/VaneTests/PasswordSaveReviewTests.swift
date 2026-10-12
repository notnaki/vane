import AppKit
import XCTest
@testable import vane

@MainActor final class PasswordSaveReviewTests: XCTestCase {
    func testReviewedNewAccountCannotOverwriteAnExistingAccount() throws {
        TestEnvironment.prepare()
        let profile = UUID(), origin = PasswordOrigin(host: "review-\(UUID()).invalid")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "existing", password: "keep", profileID: profile) else { throw XCTSkip("Isolated Keychain unavailable") }
        let tab = Tab(profileID: profile)
        defer { tab.tearDown() }
        tab.pendingSave = PendingSave(host: origin.host, account: "new", password: "proposed")
        tab.confirmSave(origin: origin, account: "existing", password: "proposed")
        XCTAssertEqual(Passwords.password(origin: origin, account: "existing", profileID: profile), "keep")
        XCTAssertEqual(tab.pendingSave?.update, true)
        XCTAssertNotNil(tab.passwordSaveProblem)
        tab.confirmSave()
        XCTAssertEqual(Passwords.password(origin: origin, account: "existing", profileID: profile), "proposed")
        XCTAssertNil(tab.pendingSave)
    }

    func testReviewedWebsiteAndUsernameAreSavedExactly() throws {
        TestEnvironment.prepare()
        let profile = UUID(), original = PasswordOrigin(host: "before-\(UUID()).invalid")
        let corrected = PasswordOrigin(host: "after-\(UUID()).invalid", port: 8443)
        defer { Passwords.deleteAll(profileID: profile) }
        let tab = Tab(profileID: profile)
        defer { tab.tearDown() }
        tab.pendingSave = PendingSave(host: original.host, account: "", password: "typed")
        tab.confirmSave(origin: corrected, account: " corrected ", password: "reviewed")
        XCTAssertNil(tab.passwordSaveProblem)
        XCTAssertEqual(Passwords.password(origin: corrected, account: " corrected ", profileID: profile), "reviewed")
        XCTAssertNil(Passwords.password(origin: original, account: "", profileID: profile))
    }

    func testPrivateWindowCannotPersistEvenAStagedOffer() {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true, profileID: UUID())
        defer { tab.tearDown() }
        let p = PendingSave(host: "private.invalid", account: "fixture", password: "secret")
        tab.pendingSave = p
        tab.confirmSave()
        XCTAssertNil(Passwords.password(origin: p.origin, account: p.account, profileID: tab.profileID))
    }
}
