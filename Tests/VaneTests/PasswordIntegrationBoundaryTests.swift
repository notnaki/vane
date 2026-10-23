import Security
import XCTest
@testable import vane

@MainActor final class PasswordIntegrationBoundaryTests: XCTestCase {
    func testLegacyTokenOriginIsExcludedFromWebEnumerationAndExport() throws {
        TestEnvironment.prepare()
        let profile = UUID()
        let scope = try XCTUnwrap(Passwords.namespace(profileID: profile, dataDir: Store.overrideDirectory))
        let items: [[String: Any]] = [
            [kSecAttrServer as String: "api.github.com", kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
             kSecAttrAccount as String: "integration", kSecAttrSecurityDomain as String: scope,
             kSecValuePersistentRef as String: Data([1])],
            [kSecAttrServer as String: "github.com", kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
             kSecAttrAccount as String: "web", kSecAttrSecurityDomain as String: scope,
             kSecValuePersistentRef as String: Data([2])]
        ]
        let copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = { query, result in
            let q = query as NSDictionary
            if q[kSecReturnAttributes as String] as? Bool == true { result?.pointee = items as CFArray }
            else {
                XCTAssertEqual(q[kSecValuePersistentRef as String] as? Data, Data([2]), "Never decrypt the integration token for a web export")
                result?.pointee = Data("fixture-web-password".utf8) as CFData
            }
            return errSecSuccess
        }
        let logins = try Passwords.allChecked(profileID: profile, copyMatching: copy)
        XCTAssertEqual(logins.map(\.host), ["github.com"])
        let entries = try Passwords.exportEntries(profileID: profile, copyMatching: copy)
        XCTAssertEqual(entries.map(\.origin.host), ["github.com"])
    }

    func testDirectWebPasswordReadCannotDecryptLegacyIntegrationToken() throws {
        let secret = try Passwords.passwordChecked(origin: .init(host: "api.github.com"), account: "integration", profileID: UUID()) { _, _ in
            XCTFail("Legacy token origins must be refused before any Keychain query")
            return errSecItemNotFound
        }
        XCTAssertNil(secret)
    }
}
