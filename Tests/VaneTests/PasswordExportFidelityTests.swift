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

    func testIsolatedKeychainCSVRoundTripAndRepeatPreserveExistingCredentials() throws {
        TestEnvironment.prepare()
        guard ProcessInfo.processInfo.environment["VANE_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set VANE_TEST_KEYCHAIN=1 for isolated Keychain round trips")
        }
        let source = UUID(), target = UUID(), host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vane-password-roundtrip-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            Passwords.deleteAll(profileID: source); Passwords.deleteAll(profileID: target)
            XCTAssertEqual(try? Passwords.exportEntries(profileID: source).count, 0)
            XCTAssertEqual(try? Passwords.exportEntries(profileID: target).count, 0)
            try? FileManager.default.removeItem(at: dir)
        }
        let entries = [PasswordImport.Entry(origin: PasswordOrigin(host: host), account: " 雪,\"ada\" ", password: "fixture\n🔑"),
                       PasswordImport.Entry(origin: PasswordOrigin(host: host, port: 8443), account: "", password: "second"),
                       PasswordImport.Entry(origin: PasswordOrigin(host: host, scheme: "http"), account: "ada", password: "third")]
        for entry in entries { XCTAssertTrue(Passwords.save(origin: entry.origin, account: entry.account, password: entry.password, profileID: source)) }
        let exported = try Export.savedPasswords(profileID: source)
        XCTAssertEqual(exported.count, 3)
        let file = dir.appendingPathComponent("passwords.csv")
        try Export.write(Export.passwordsCSV(exported), to: file, secret: true)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        for attempt in 0...1 {
            let result = try PasswordImport.importFile(file, existing: Set(Passwords.all(profileID: target).map(\.id))) { entry in
                Passwords.save(origin: entry.origin, account: entry.account, password: entry.password,
                               profileID: target, replacingExisting: false)
            }
            XCTAssertEqual(result.imported, attempt == 0 ? 3 : 0)
            XCTAssertEqual(result.skipped, attempt == 0 ? 0 : 3)
            XCTAssertEqual(result.failed, 0)
        }
        for entry in entries {
            XCTAssertEqual(Passwords.password(origin: entry.origin, account: entry.account, profileID: target), entry.password)
        }
        XCTAssertTrue(Passwords.save(origin: entries[0].origin, account: entries[0].account, password: "existing-newer", profileID: target))
        let refused = try PasswordImport.importFile(file) { entry in
            Passwords.save(origin: entry.origin, account: entry.account, password: entry.password,
                           profileID: target, replacingExisting: false)
        }
        XCTAssertEqual(refused.failed, 3)
        XCTAssertEqual(Passwords.password(origin: entries[0].origin, account: entries[0].account, profileID: target), "existing-newer")
    }

}
