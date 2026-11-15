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

    func testReviewedOfferCannotRetargetItsCapturedSecret() throws {
        TestEnvironment.prepare()
        let profile = UUID(), original = PasswordOrigin(host: "captured.invalid")
        let offer = PendingSave(host: original.host, account: "ada", password: "captured")
        var operations = Passwords.ReviewOperations()
        operations.snapshot = { _, _, _ in XCTFail("Retargeting reached Keychain"); return (nil, nil) }
        operations.insert = { _, _, _, _ in XCTFail("Retargeted secret was saved") }
        for destination in [PasswordOrigin(host: "other.invalid"), PasswordOrigin(host: original.host, port: 8443)] {
            XCTAssertThrowsError(try Passwords.reviewedSave(offer, origin: destination, account: "ada",
                password: "captured", profileID: profile, operations: operations)) { error in
                XCTAssertTrue(error is Passwords.SaveOriginChanged)
            }
        }
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
