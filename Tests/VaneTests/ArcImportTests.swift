import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import vane

@MainActor final class ArcImportTests: XCTestCase {

    private let key = SafeStorage.key(secret: "fixture-secret")

    private func seal(_ text: String) -> Data {
        seal(Data(text.utf8))
    }

    private func seal(_ plain: Data) -> Data {
        var result = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = result.withUnsafeMutableBytes { output in
            plain.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    SafeStorage.iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), key.baseAddress, key.count,
                                iv.baseAddress, input.baseAddress, input.count,
                                output.baseAddress, output.count, &written)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return SafeStorage.prefix + result.prefix(written)
    }

    func testImportsPasswordWithoutUsernameAndPreservesSecretExactly() {
        TestEnvironment.prepare()
        let secret = "  pa,ss\"word\n🔑  "
        var vault = ArcImport.Vault(directory: "Default", path: URL(fileURLWithPath: "/fixture"))
        vault.logins = [.init(origin: "https://example.com/login", account: "", value: seal(secret))]
        let opened = ArcImport.open(vault, key: key)
        XCTAssertEqual(opened.logins.count, 1)
        XCTAssertEqual(opened.logins.first?.password, secret)
        XCTAssertEqual(opened.logins.first?.account, "")
        XCTAssertEqual(opened.skipped, 0)
    }

    func testDatabaseIterationErrorsAreReported() throws {
        TestEnvironment.prepare()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("History")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE fixture (value TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        // This prepares successfully but raises an integer-overflow error on sqlite3_step.
        XCTAssertThrowsError(try BrowserImport.query(file, "SELECT abs(-9223372036854775808)") { _ in
            XCTFail("The expression must not yield a row")
        })
    }
    func testBlockedFlagDoesNotDependOnUsername() {
        var vault = ArcImport.Vault(directory: "Default", path: URL(fileURLWithPath: "/fixture"))
        vault.logins = [.init(origin: "https://example.com", account: "ada", value: seal("secret"), blocked: true)]
        let opened = ArcImport.open(vault, key: key)
        XCTAssertTrue(opened.logins.isEmpty)
        XCTAssertEqual(opened.skipped, 1)
    }

    func testDuplicatesKeepFirstSuccessfulPasswordWithoutInflatingCount() {
        let origin = PasswordOrigin(host: "example.com")
        let other = PasswordOrigin(host: "example.com", port: 8443)
        var counts = ArcImport.Counts()
        var saved: [String: String] = [:]
        ArcImport.importLogins([(origin, "ada", "newest"), (origin, "ada", "older"),
                                (other, "ada", "other-port")], existing: [], counts: &counts) {
            saved[$0.key(account: $1)] = $2; return true
        }
        XCTAssertEqual(saved[origin.key(account: "ada")], "newest")
        XCTAssertEqual(saved[other.key(account: "ada")], "other-port")
        XCTAssertEqual(counts.passwords, 2)
        XCTAssertEqual(counts.passwordsAlready, 1)
    }

    func testExistingPasswordIsUntouchedAndFailedWriteDoesNotBlockRetry() {
        let origin = PasswordOrigin(host: "example.com")
        var counts = ArcImport.Counts()
        var attempts = 0
        ArcImport.importLogins([(origin, "ada", "first"), (origin, "ada", "second"),
                                (origin, "existing", "replacement")],
                               existing: [origin.key(account: "existing")], counts: &counts) { _, _, _ in
            attempts += 1; return attempts == 2
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(counts.passwords, 1)
        XCTAssertEqual(counts.refused, 1)
        XCTAssertEqual(counts.passwordsAlready, 1)
    }

    func testCookieRetainsHTTPOnlySameSiteDomainPathSecureAndExpiry() throws {
        let expiry = Date(timeIntervalSinceNow: 3600)
        let micros = Int64((expiry.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let row = ArcImport.Vault.Cookie(host: ".example.com", name: "sid", path: "/account",
                                        value: Data(), expires: micros, secure: true,
                                        httpOnly: true, sameSite: 2)
        let cookie = try XCTUnwrap(ArcImport.cookie(row, value: "fixture-token"))
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertTrue(cookie.isSecure)
        XCTAssertEqual(cookie.sameSitePolicy?.rawValue, "strict")
        XCTAssertEqual(cookie.domain, ".example.com")
        XCTAssertEqual(cookie.path, "/account")
        let actualExpiry = try XCTUnwrap(cookie.expiresDate)
        XCTAssertEqual(actualExpiry.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(cookie.isSessionOnly)
    }

    func testSessionCookieAndHostOnlyScopeRemainUnchanged() throws {
        let row = ArcImport.Vault.Cookie(host: "example.com", name: "sid", path: "/",
                                        value: Data(), expires: 0, secure: false,
                                        httpOnly: true, sameSite: 1)
        let cookie = try XCTUnwrap(ArcImport.cookie(row, value: "fixture"))
        XCTAssertTrue(cookie.isSessionOnly)
        XCTAssertNil(cookie.expiresDate)
        XCTAssertEqual(cookie.domain, "example.com")
        XCTAssertEqual(cookie.sameSitePolicy?.rawValue, "lax")
    }

    func testUnsafeOrExpiredCookieIsSkippedInsteadOfWeakeningScope() {
        var row = ArcImport.Vault.Cookie(host: "example.com", name: "sid", path: "/",
                                        value: Data(), expires: 0, secure: true)
        XCTAssertNil(ArcImport.cookie(row, value: "secret; HttpOnly"))
        row.partitioned = true
        XCTAssertNil(ArcImport.cookie(row, value: "secret"))
        row.partitioned = false
        row.sameSite = 99
        XCTAssertNil(ArcImport.cookie(row, value: "secret"))
        let expired = ArcImport.Vault.Cookie(host: "example.com", name: "sid", path: "/",
                                             value: Data(), expires: 11_644_473_600_000_001, secure: true)
        XCTAssertNil(ArcImport.cookie(expired, value: "secret"))
    }

    func testModernCookieRequiresMatchingHostHashAndLegacyDoesNotStripValue() {
        let host = ".example.com"
        let hashed = Data(SHA256.hash(data: Data(host.utf8))) + Data("fixture-token".utf8)
        XCTAssertEqual(SafeStorage.decrypt(seal(hashed), key: key, hostKey: host,
                                          requiresHostHash: true), "fixture-token")
        XCTAssertNil(SafeStorage.decrypt(seal(hashed), key: key, hostKey: ".other.com",
                                        requiresHostHash: true))
        XCTAssertNil(SafeStorage.decrypt(seal(String(repeating: "a", count: 40)), key: key,
                                        hostKey: host, requiresHostHash: true))
        var vault = ArcImport.Vault(directory: "Default", path: URL(fileURLWithPath: "/fixture"))
        vault.cookieVersion = 23
        vault.cookies = [.init(host: host, name: "sid", path: "/", value: seal("legacy-token"),
                               expires: 0, secure: true, httpOnly: true)]
        XCTAssertEqual(ArcImport.open(vault, key: key).cookies.first?.value, "legacy-token")
        vault.cookieVersion = nil
        let unopened = ArcImport.open(vault, key: key)
        XCTAssertTrue(unopened.cookies.isEmpty)
        XCTAssertEqual(unopened.cookiesSkipped, 1)
    }

    func testSnapshotIncludesCommittedWALButNotUncommittedRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Login Data")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE fixture (value INTEGER); INSERT INTO fixture VALUES (1); BEGIN IMMEDIATE; INSERT INTO fixture VALUES (2)", nil, nil, nil), SQLITE_OK)
        var values: [Int] = []
        try BrowserImport.query(file, "SELECT value FROM fixture") { values.append(Int(sqlite3_column_int($0, 0))) }
        XCTAssertEqual(values, [1])
        XCTAssertEqual(sqlite3_exec(db, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_changes(db), 1)
    }

    func testSQLiteReaderKeepsFlagsSessionLifetimeAndNewestOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func database(_ name: String, sql: String) throws {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent(name).path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        }
        let sealed = seal("fixture-secret").map { String(format: "%02x", $0) }.joined()
        try database("Login Data", sql: """
            CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB,
                                 blacklisted_by_user INTEGER, date_created INTEGER);
            INSERT INTO logins VALUES ('https://example.com:8443/login', '', X'\(sealed)', 0, 20);
            INSERT INTO logins VALUES ('https://example.com/login', 'blocked', X'\(sealed)', 1, 10);
            """)
        try database("Cookies", sql: """
            CREATE TABLE meta (key TEXT, value INTEGER);
            INSERT INTO meta VALUES ('version', 23);
            CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, encrypted_value BLOB,
                                  expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER,
                                  samesite INTEGER, top_frame_site_key TEXT, value TEXT,
                                  has_expires INTEGER, is_persistent INTEGER);
            INSERT INTO cookies VALUES ('example.com', 'sid', '/', X'\(sealed)',
                                        14000000000000000, 1, 1, 2, '', '', 1, 0);
            INSERT INTO cookies VALUES ('example.com', 'partitioned', '/', X'\(sealed)',
                                        0, 1, 1, 2, 'https://other.com', '', 0, 0);
            """)
        let vault = ArcImport.read(vault: "Default", at: directory)
        XCTAssertEqual(vault.unreadable, 0)
        XCTAssertEqual(vault.logins.map(\.account), ["", "blocked"])
        XCTAssertTrue(vault.logins[1].blocked)
        XCTAssertEqual(vault.cookies[0].expires, 0)
        let opened = ArcImport.open(vault, key: key)
        XCTAssertEqual(opened.logins.first?.origin.port, 8443)
        XCTAssertEqual(opened.logins.first?.password, "fixture-secret")
        XCTAssertEqual(opened.skipped, 1)
        XCTAssertEqual(opened.cookiesSkipped, 1)
        XCTAssertTrue(opened.cookies.first?.isSessionOnly == true)
        XCTAssertTrue(opened.cookies.first?.isHTTPOnly == true)
    }

    func testNewestPasswordModificationWinsOverCreationTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("Login Data").path, &db), SQLITE_OK)
        let value = seal("fixture").map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB,
                                 blacklisted_by_user INTEGER, date_created INTEGER, date_password_modified INTEGER);
            INSERT INTO logins VALUES ('https://example.com/new-form', 'newer-form', X'\(value)', 0, 20, 20);
            INSERT INTO logins VALUES ('https://example.com/old-form', 'updated-password', X'\(value)', 0, 10, 30);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let vault = ArcImport.read(vault: "Default", at: directory)
        XCTAssertEqual(vault.unreadable, 0)
        XCTAssertEqual(vault.logins.map(\.account), ["updated-password", "newer-form"])
    }

    func testCSVExportAndImportPreserveOriginAndWhitespace() throws {
        let entries = [PasswordImport.Entry(origin: PasswordOrigin(host: "example.com", port: 8443),
                                            account: " ada ", password: "  secret\n🔑  "),
                       PasswordImport.Entry(origin: PasswordOrigin(host: "example.com", scheme: "http"),
                                            account: "", password: "another")]
        let parsed = try PasswordImport.parse(Export.passwordsCSV(entries)).entries
        XCTAssertEqual(parsed.map(\.origin), entries.map(\.origin))
        XCTAssertEqual(parsed.map(\.password), entries.map(\.password))
        XCTAssertEqual(parsed.map(\.account), entries.map(\.account))
    }

    func testKeychainSeparatesOriginsThroughSaveReadUpdateAndDelete() throws {
        TestEnvironment.prepare()
        guard ProcessInfo.processInfo.environment["VANE_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set VANE_TEST_KEYCHAIN=1 for isolated Keychain integration")
        }
        let profileID = UUID()
        let host = "fixture-\(UUID().uuidString.lowercased()).invalid"
        let origins = [PasswordOrigin(host: host), PasswordOrigin(host: host, port: 8443),
                       PasswordOrigin(host: host, scheme: "http")]
        defer {
            Passwords.deleteAll(profileID: profileID)
            XCTAssertEqual(try? Passwords.exportEntries(profileID: profileID).count, 0)
        }
        for (index, origin) in origins.enumerated() {
            XCTAssertTrue(Passwords.save(origin: origin, account: "", password: "fixture-\(index)", profileID: profileID))
        }
        XCTAssertEqual(Set(Passwords.all(profileID: profileID).map(\.origin)), Set(origins))
        for (index, origin) in origins.enumerated() {
            XCTAssertEqual(Passwords.matches(origin: origin, profileID: profileID).count, 1)
            XCTAssertEqual(Passwords.password(origin: origin, account: "", profileID: profileID), "fixture-\(index)")
        }
        XCTAssertTrue(Passwords.save(origin: origins[1], account: "", password: "updated", profileID: profileID))
        XCTAssertEqual(Passwords.password(origin: origins[0], account: "", profileID: profileID), "fixture-0")
        XCTAssertFalse(Passwords.save(origin: origins[0], account: "", password: "replacement",
                                      profileID: profileID, replacingExisting: false))
        XCTAssertEqual(Passwords.password(origin: origins[0], account: "", profileID: profileID), "fixture-0")
        XCTAssertTrue(Passwords.delete(origin: origins[1], account: "", profileID: profileID))
        XCTAssertNil(Passwords.password(origin: origins[1], account: "", profileID: profileID))
        XCTAssertEqual(Passwords.password(origin: origins[2], account: "", profileID: profileID), "fixture-2")
    }

}
