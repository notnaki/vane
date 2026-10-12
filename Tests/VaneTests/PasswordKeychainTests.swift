import Security
import XCTest
@testable import vane

@MainActor final class PasswordKeychainTests: XCTestCase {
    func testEnumerationFailureIsActionableAndDoesNotBecomeEmptyList() {
        TestEnvironment.prepare()
        XCTAssertThrowsError(try Passwords.allChecked(profileID: UUID(), copyMatching: { _, _ in errSecInteractionNotAllowed })) { error in
            XCTAssertTrue(error.localizedDescription.contains("unlock"))
        }
    }

    func testReadFailureIsNotAMissingCredential() {
        TestEnvironment.prepare()
        XCTAssertThrowsError(try Passwords.passwordChecked(origin: .init(host: "fixture.invalid"), account: "fixture", profileID: UUID(), copyMatching: { _, _ in errSecAuthFailed })) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain"))
        }
    }

    func testNewSaveCannotOverwriteAnExistingAccount() throws {
        TestEnvironment.prepare()
        let profile = UUID(), origin = PasswordOrigin(host: "collision-\(UUID()).invalid")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "ada", password: "existing", profileID: profile) else { throw XCTSkip("Isolated Keychain unavailable") }
        XCTAssertThrowsError(try Passwords.saveChecked(origin: origin, account: "ada", password: "replacement", profileID: profile, replacingExisting: false))
        XCTAssertEqual(Passwords.password(origin: origin, account: "ada", profileID: profile), "existing")
    }

    func testEditingUpdatesOwnedItemInPlaceAndRefusesCollision() throws {
        TestEnvironment.prepare()
        let profile = UUID(), origin = PasswordOrigin(host: "identity-\(UUID()).invalid")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "ada", password: "existing", profileID: profile),
              Passwords.save(origin: origin, account: "bob", password: "other", profileID: profile) else { throw XCTSkip("Isolated Keychain unavailable") }
        let login = Passwords.Login(origin: origin, account: "ada")
        let before = try Passwords.referenceChecked(origin: origin, account: "ada", profileID: profile)
        try Passwords.editChecked(login, origin: origin, account: "ada", password: "updated", profileID: profile)
        XCTAssertEqual(try Passwords.referenceChecked(origin: origin, account: "ada", profileID: profile), before)
        XCTAssertThrowsError(try Passwords.editChecked(login, origin: origin, account: "bob", password: "edited", profileID: profile))
        XCTAssertEqual(Passwords.password(origin: origin, account: "bob", profileID: profile), "other")
        try Passwords.editChecked(login, origin: origin, account: "corrected", password: "edited", profileID: profile)
        XCTAssertNotNil(try Passwords.referenceChecked(origin: origin, account: "corrected", profileID: profile))
        XCTAssertNil(Passwords.password(origin: origin, account: "ada", profileID: profile))
        XCTAssertEqual(Passwords.password(origin: origin, account: "corrected", profileID: profile), "edited")
    }
}
