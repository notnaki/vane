import XCTest
import Security
@testable import vane

@MainActor final class PasswordExportFidelityTests: XCTestCase {
    func testEnumerationFailureDoesNotBecomeAnEmptyExport() {
        TestEnvironment.prepare()
        XCTAssertThrowsError(try Passwords.exportEntries(profileID: UUID()) { _, _ in errSecInteractionNotAllowed })
    }

    func testReadFailureAfterFirstCredentialRejectsEntireExport() {
        TestEnvironment.prepare()
        let id = UUID(), scope = Passwords.namespace(profileID: id, dataDir: Store.overrideDirectory)!
        let items: [[String: Any]] = (1...2).map { n in
            [kSecAttrServer as String: "fixture.invalid", kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
             kSecAttrAccount as String: "account-\(n)", kSecAttrSecurityDomain as String: scope,
             kSecValuePersistentRef as String: Data([UInt8(n)])]
        }
        XCTAssertThrowsError(try Passwords.exportEntries(profileID: id) { query, result in
            let q = query as NSDictionary
            if q[kSecReturnAttributes as String] as? Bool == true {
                result?.pointee = items as CFArray; return errSecSuccess
            }
            if q[kSecValuePersistentRef as String] as? Data == Data([1]) {
                result?.pointee = Data("synthetic-password".utf8) as CFData; return errSecSuccess
            }
            return errSecInteractionNotAllowed
        }) { error in
            XCTAssertFalse(error.localizedDescription.contains("synthetic-password"))
            XCTAssertFalse(error.localizedDescription.contains("account-"))
        }
    }

    func testExportUsesFreshOwnedReferencesAndPreservesOriginAndEmptySecret() throws {
        TestEnvironment.prepare()
        let id = UUID(), scope = Passwords.namespace(profileID: id, dataDir: Store.overrideDirectory)!
        let items: [[String: Any]] = [
            [kSecAttrServer as String: "fixture.invalid", kSecAttrProtocol as String: kSecAttrProtocolHTTP,
             kSecAttrPort as String: 8080, kSecAttrAccount as String: " 雪 ",
             kSecAttrSecurityDomain as String: scope, kSecValuePersistentRef as String: Data([1])],
            [kSecAttrServer as String: "other.invalid", kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
             kSecAttrSecurityDomain as String: "other-profile", kSecValuePersistentRef as String: Data([2])]]
        let entries = try Passwords.exportEntries(profileID: id) { query, result in
            let q = query as NSDictionary
            if q[kSecReturnAttributes as String] as? Bool == true {
                XCTAssertNotNil(q[kSecAttrCreator as String])
                XCTAssertEqual(q[kSecAttrSecurityDomain as String] as? String, scope)
                result?.pointee = items as CFArray
            } else {
                XCTAssertEqual(q[kSecValuePersistentRef as String] as? Data, Data([1]))
                result?.pointee = Data() as CFData
            }
            return errSecSuccess
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.origin, PasswordOrigin(host: "fixture.invalid", scheme: "http", port: 8080))
        XCTAssertEqual(entries.first?.account, " 雪 ")
        XCTAssertEqual(entries.first?.password, "")
    }

    func testNoOwnedItemsIsAnExplicitEmptyExport() throws {
        TestEnvironment.prepare()
        XCTAssertTrue(try Passwords.exportEntries(profileID: UUID()) { _, _ in errSecItemNotFound }.isEmpty)
    }
}
