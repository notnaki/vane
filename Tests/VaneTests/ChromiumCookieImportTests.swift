import AppKit
import XCTest
import SQLite3
import CommonCrypto
import CryptoKit
@testable import vane

/// All databases, secrets and cookie stores here are synthetic and memory/temp-only.
@MainActor final class ChromiumCookieImportTests: XCTestCase {
    private let secret = Data("synthetic-safe-storage".utf8)

    private func seal(_ plain: Data) -> Data {
        let key = SafeStorage.key(secret: secret)
        var output = Data(count: plain.count + 16)
        var count = 0
        let status = output.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    SafeStorage.iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                                out.baseAddress, out.count, &count)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return Data("v10".utf8) + output.prefix(count)
    }

    private func fixture(version: Int = 24, rows: String = "", network: Bool = false,
                         columns: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-cookie-fixture-\(UUID())")
        let folder = network ? directory.appendingPathComponent("Network") : directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("Cookies").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE meta (key TEXT, value INTEGER);
        INSERT INTO meta VALUES ('version', \(version));
        CREATE TABLE cookies (host_key TEXT, name TEXT, path TEXT, encrypted_value BLOB,
          expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER,
          top_frame_site_key TEXT, value TEXT, has_expires INTEGER, is_persistent INTEGER\(columns));
        \(rows)
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        return directory
    }

    private func cookie(_ name: String = "sid", value: String = "new") throws -> HTTPCookie {
        try XCTUnwrap(ArcImport.cookie(.init(host: "example.invalid", name: name, path: "/",
            value: Data(), expires: 0, secure: true, httpOnly: true, sameSite: 2), value: value))
    }

    func testBrowserIdentitySelectsExactServiceAndAccountAndNeverFallsBack() throws {
        for (browser, service, account) in [
            ("Chrome", "Chrome Safe Storage", "Chrome"), ("Chromium", "Chromium Safe Storage", "Chromium"),
            ("Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
            ("Brave", "Brave Safe Storage", "Brave"), ("Vivaldi", "Vivaldi Safe Storage", "Vivaldi"),
            ("Opera", "Opera Safe Storage", "Opera"), ("Arc", "Arc Safe Storage", "Arc")
        ] {
            let identity = try XCTUnwrap(ChromiumCookies.identity(browser: browser))
            var requests: [ChromiumCookies.Identity] = []
            let key = ChromiumCookies.key(identity: identity) { request in
                requests.append(request)
                return self.secret
            }
            XCTAssertEqual(requests.map(\.service), [service])
            XCTAssertEqual(requests.map(\.account), [account])
            XCTAssertEqual(key, SafeStorage.key(secret: secret))
            XCTAssertNil(ChromiumCookies.key(identity: identity) { _ in nil })
        }
        for browser in ["Firefox", "Safari", "Unknown", "Chrome Beta"] {
            XCTAssertNil(ChromiumCookies.identity(browser: browser))
        }
    }

    func testKnownAESVectorAndMixedSchemaRowsKeepAttributesAndCountRejections() throws {
        // Existing independent PBKDF2/AES vectors are also exercised by ArcImport.check().
        XCTAssertTrue(ArcImport.check().allSatisfy(\.1))
        let host = ".example.invalid"
        let encrypted = seal(Data(SHA256.hash(data: Data(host.utf8))) + Data("fixture-session".utf8))
        let hex = encrypted.map { String(format: "%02x", $0) }.joined()
        let expires = Int64(Date().timeIntervalSince1970) + 3600
        let chromiumExpiry = (expires + 11_644_473_600) * 1_000_000
        let folder = try fixture(rows: """
        INSERT INTO cookies VALUES ('\(host)', 'sid', '/account', X'\(hex)', \(chromiumExpiry), 1, 1, 2, '', '', 1, 1);
        INSERT INTO cookies VALUES ('example.invalid', 'session', '/', X'', 0, 0, 1, 1, '', 'plain', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid', 'expired', '/', X'', 11644473600000001, 1, 0, -1, '', 'old', 1, 1);
        INSERT INTO cookies VALUES ('example.invalid', 'partitioned', '/', X'', 0, 1, 0, -1, 'https://other.invalid', 'partition', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid', 'modern', '/', X'763230aabbcc', 0, 1, 0, -1, '', 'no-fallback', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid', 'damaged', '/', X'763130aabbcc', 0, 1, 0, -1, '', '', 0, 0);
        """, network: true)
        let snapshot = try ChromiumCookies.read(at: folder)
        let opened = ChromiumCookies.open(snapshot, key: SafeStorage.key(secret: secret))
        XCTAssertEqual(snapshot.version, 24)
        XCTAssertEqual(opened.cookies.count, 2)
        XCTAssertEqual(opened.skipped, 3)
        XCTAssertEqual(opened.failed, 1)
        XCTAssertEqual(opened.unsupportedEncryption, 1)
        let persistent = try XCTUnwrap(opened.cookies.first)
        XCTAssertEqual(persistent.value, "fixture-session")
        XCTAssertEqual(persistent.domain, host)
        XCTAssertEqual(persistent.path, "/account")
        XCTAssertTrue(persistent.isSecure)
        XCTAssertTrue(persistent.isHTTPOnly)
        XCTAssertEqual(persistent.sameSitePolicy?.rawValue, "strict")
        XCTAssertFalse(persistent.isSessionOnly)
        XCTAssertEqual(persistent.expiresDate?.timeIntervalSince1970, TimeInterval(expires))
        XCTAssertTrue(opened.cookies[1].isSessionOnly)
        XCTAssertEqual(opened.cookies[1].sameSitePolicy?.rawValue, "lax")
        XCTAssertEqual(opened.cookies[1].domain, "example.invalid")
    }

    func testLegacySchemaWrongKeyAndHostBinding() throws {
        let row = ChromiumCookies.Row(host: "example.invalid", name: "sid", path: "/", value: seal(Data("legacy".utf8)),
                                       expires: 0, secure: true)
        let legacy = ChromiumCookies.Snapshot(version: 23, rows: [row])
        XCTAssertEqual(ChromiumCookies.open(legacy, key: SafeStorage.key(secret: secret)).cookies.first?.value, "legacy")
        XCTAssertEqual(ChromiumCookies.open(legacy, key: SafeStorage.key(secret: "wrong")).failed, 1)
        XCTAssertEqual(ChromiumCookies.open(.init(version: 24, rows: [row]), key: SafeStorage.key(secret: secret)).failed, 1)
        XCTAssertEqual(ChromiumCookies.open(.init(version: 25, rows: [row]), key: SafeStorage.key(secret: secret)).skipped, 1)
        let future = try fixture(version: 25)
        XCTAssertThrowsError(try ChromiumCookies.read(at: future))
        let old = try fixture(version: 22)
        XCTAssertThrowsError(try ChromiumCookies.read(at: old))
    }

    func testMissingSecurityColumnFailsClosedAndArcUsesSharedSnapshot() throws {
        let folder = try fixture(version: 23, rows: """
        INSERT INTO cookies VALUES ('example.invalid', 'sid', '/', X'', 0, 1, 1, 2, '', 'fixture', 0, 0);
        """, network: true)
        let vault = ArcImport.read(vault: "Default", at: folder)
        XCTAssertEqual(vault.cookies.count, 1)
        XCTAssertEqual(ArcImport.open(vault, key: Data()).cookies.first?.value, "fixture")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("Network/Cookies").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE cookies DROP COLUMN is_httponly", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try ChromiumCookies.read(at: folder))
        XCTAssertEqual(ArcImport.read(vault: "Default", at: folder).unreadable, 1)
    }

    func testPublicationKeepsExistingCookiesAndReportsFailedVerification() async throws {
        let existing = try cookie(value: "existing")
        let fresh = try cookie("fresh")
        let missing = try cookie("refused")
        var stored = [existing]
        let result = await ChromiumCookies.publish([try cookie(), fresh, missing], validate: { true },
            fetch: { stored }, set: { cookie in if cookie.name != "refused" { stored.append(cookie) } })
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(stored.first?.value, "existing")
        XCTAssertEqual(stored.map(\.name), ["sid", "fresh"])
    }

    func testDestinationAndCancellationAreRevalidatedAfterEveryAwait() async throws {
        var allowed = true
        var stored: [HTTPCookie] = []
        let rows = [try cookie(), try cookie("second")]
        let result = await ChromiumCookies.publish(rows, validate: { allowed }, fetch: { stored }, set: {
            stored.append($0); allowed = false
        })
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.stopped)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ChromiumCookies.publish(rows, validate: { true }, fetch: { [] }, set: { _ in XCTFail() })
        }
        let cancelledResult = await cancelled.value
        XCTAssertEqual(cancelledResult.imported, 0)
        XCTAssertEqual(cancelledResult.skipped, 2)
        XCTAssertTrue(cancelledResult.stopped)
        allowed = true
        let refused = await ChromiumCookies.publish(rows, validate: { true }, fetch: {
            allowed = false; return []
        }, set: { _ in XCTFail("Destination changed while fetching") }, checkCancellation: { !allowed })
        XCTAssertEqual(refused.imported, 0)
        XCTAssertEqual(refused.skipped, 2)
    }

    func testGeneralImportOptInExecutesCookiesAndDefaultNeverReadsSecrets() async throws {
        TestEnvironment.prepare()
        let folder = try fixture(version: 23, rows: """
        INSERT INTO cookies VALUES ('example.invalid', 'sid', '/', X'', 0, 1, 1, 2, '', 'fixture-session', 0, 0);
        """)
        try Data("{\"roots\":{\"bookmark_bar\":{\"type\":\"folder\",\"children\":[{\"type\":\"url\",\"url\":\"https://book.invalid/\",\"name\":\"Fixture\"}]}}}".utf8)
            .write(to: folder.appendingPathComponent("Bookmarks"))
        let source = BrowserProfile(browser: "Chrome", profile: "Synthetic", path: folder, hasHistory: false, hasBookmarks: true)
        let id = UUID()
        addTeardownBlock { await MainActor.run { Store.forget(id) } }
        let without = try await BrowserImport.importReviewed(from: source, profileID: id, validateDestination: { true },
            readKey: { _ in XCTFail("Sessions default to off"); return nil },
            cookieAccess: { XCTFail("Sessions default to off"); return .init(fetch: { [] }, set: { _ in }) })
        XCTAssertEqual(without.bookmarks, 1)
        XCTAssertNil(without.sessions)
        var stored: [HTTPCookie] = []
        let with = try await BrowserImport.importReviewed(from: source, profileID: id, includeSessions: true,
            validateDestination: { true }, readKey: { _ in XCTFail("Plaintext rows need no key"); return nil },
            cookieAccess: { .init(fetch: { stored }, set: { stored.append($0) }) })
        XCTAssertEqual(with.sessions?.imported, 1)
        XCTAssertEqual(with.bookmarks, 0)
        XCTAssertEqual(stored.first?.value, "fixture-session")
        XCTAssertEqual(Store.store(for: id).bookmarks().count, 1)
        let again = try await BrowserImport.importReviewed(from: source, profileID: id, includeSessions: true,
            validateDestination: { true }, readKey: { _ in nil },
            cookieAccess: { .init(fetch: { stored }, set: { stored.append($0) }) })
        XCTAssertEqual(again.sessions?.skipped, 1)
        XCTAssertEqual(stored.count, 1)
        do {
            _ = try await BrowserImport.importReviewed(from: source, profileID: id, includeSessions: true,
                validateDestination: { false }, readKey: { _ in XCTFail(); return nil },
                cookieAccess: { XCTFail(); return .init(fetch: { [] }, set: { _ in XCTFail() }) })
            XCTFail("Revoked destination must reject before any source/Keychain/store work")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPersistenceErrorsAndAttributeLossAreNeverCountedAsImported() async throws {
        enum Refused: Error { case storage }
        let rows = [try cookie(), try cookie("second")]
        let unreadable = await ChromiumCookies.publish(rows, validate: { true }, fetch: { throw Refused.storage },
            set: { _ in XCTFail("An unreadable destination must not be mutated") })
        XCTAssertEqual(unreadable.failed, 2)
        XCTAssertEqual(unreadable.imported, 0)
        let unwritable = await ChromiumCookies.publish(rows, validate: { true }, fetch: { [] }, set: { _ in throw Refused.storage })
        XCTAssertEqual(unwritable.failed, 2)
        var stored: [HTTPCookie] = []
        let weakened = await ChromiumCookies.publish([try cookie()], validate: { true }, fetch: { stored }, set: { cookie in
            stored = [HTTPCookie(properties: [.domain: cookie.domain, .path: cookie.path, .name: cookie.name,
                                              .value: cookie.value, .secure: "TRUE"])!]
        })
        XCTAssertEqual(weakened.imported, 0)
        XCTAssertEqual(weakened.failed, 1)
    }

    func testHostOnlyAndDomainCollisionKeepsExistingAndOtherPathsRemainDistinct() async throws {
        let existing = try XCTUnwrap(ArcImport.cookie(.init(host: ".example.invalid", name: "sid", path: "/",
            value: Data(), expires: 0, secure: true), value: "existing"))
        let otherPath = try XCTUnwrap(ArcImport.cookie(.init(host: "example.invalid", name: "sid", path: "/other",
            value: Data(), expires: 0, secure: true), value: "different-path"))
        var stored = [existing]
        let result = await ChromiumCookies.publish([try cookie(), otherPath], validate: { true }, fetch: { stored }, set: { stored.append($0) })
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(stored.map(\.value), ["existing", "different-path"])
    }

    func testGeneralEncryptedImportUsesOnlyChosenIdentityAndReportsMissingKey() async throws {
        TestEnvironment.prepare()
        let encrypted = seal(Data("encrypted-session".utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = try fixture(version: 23, rows: """
        INSERT INTO cookies VALUES ('example.invalid', 'sid', '/', X'\(encrypted)', 0, 1, 1, 2, '', '', 0, 0);
        """)
        let source = BrowserProfile(browser: "Edge", profile: "Synthetic", path: folder, hasHistory: false, hasBookmarks: false)
        let id = UUID(), key = SafeStorage.key(secret: secret)
        addTeardownBlock { await MainActor.run { Store.forget(id) } }
        var stored: [HTTPCookie] = []
        let imported = try await BrowserImport.importReviewed(from: source, profileID: id, includeSessions: true,
            validateDestination: { true }, readKey: { identity in
                XCTAssertEqual(identity.service, "Microsoft Edge Safe Storage")
                XCTAssertEqual(identity.account, "Microsoft Edge")
                return key
            }, cookieAccess: { .init(fetch: { stored }, set: { stored.append($0) }) })
        XCTAssertEqual(imported.sessions?.imported, 1)
        XCTAssertEqual(stored.first?.value, "encrypted-session")
        let locked = try await BrowserImport.importReviewed(from: source, profileID: id, includeSessions: true,
            validateDestination: { true }, readKey: { _ in nil },
            cookieAccess: { .init(fetch: { [] }, set: { _ in XCTFail() }) })
        XCTAssertEqual(locked.sessions?.failed, 1)
        XCTAssertNotNil(locked.sessionsIssue)
    }

    func testUnsupportedSchemaReportsCategoryIssueWhileKeepingAtomicLibraryImport() async throws {
        TestEnvironment.prepare()
        let folder = try fixture(version: 25)
        let id = UUID()
        addTeardownBlock { await MainActor.run { Store.forget(id) } }
        let result = try await BrowserImport.importReviewed(from: .init(browser: "Chrome", profile: "Fixture", path: folder,
            hasHistory: false, hasBookmarks: false), profileID: id, includeSessions: true, validateDestination: { true },
            readKey: { _ in XCTFail(); return nil }, cookieAccess: { XCTFail(); return .init(fetch: { [] }, set: { _ in }) })
        XCTAssertNil(result.sessions)
        XCTAssertTrue(result.sessionsIssue?.contains("23 and 24") == true)
    }

    func testMalformedSQLiteFlagsAndEmbeddedNULCannotWeakenCookieAttributes() throws {
        let folder = try fixture(version: 23, rows: """
        INSERT INTO cookies VALUES ('example.invalid', 'null-secure', '/', X'', 0, NULL, 1, 2, '', 'fixture', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid', 'invalid-lifetime', '/', X'', 11644473600000001, 1, 1, 2, '', 'fixture', 'not-a-flag', 1);
        INSERT INTO cookies VALUES ('example.invalid', 'null-partition', '/', X'', 0, 1, 1, 2, NULL, 'fixture', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid' || char(0) || '.other.invalid', 'nul-domain', '/', X'', 0, 1, 1, 2, '', 'fixture', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid', 'overflow-secure', '/', X'', 0, 4294967296, 1, 2, '', 'fixture', 0, 0);
        INSERT INTO cookies VALUES ('example.invalid', 'overflow-samesite', '/', X'', 0, 1, 1, 4294967297, '', 'fixture', 0, 0);
        """)
        let result = ChromiumCookies.open(try ChromiumCookies.read(at: folder), key: nil)
        XCTAssertTrue(result.cookies.isEmpty)
        XCTAssertEqual(result.skipped, 6)
        XCTAssertEqual(result.failed, 0)
    }

    func testCookieRejectsUnrepresentableLifetimeAndInvalidSecurityPrefixes() {
        var row = ChromiumCookies.Row(host: ".example.invalid", name: "__Host-sid", path: "/", value: Data(), expires: 0, secure: true)
        XCTAssertNil(ChromiumCookies.cookie(row, value: "fixture"))
        row = .init(host: "example.invalid", name: "__Secure-sid", path: "/", value: Data(), expires: 0, secure: false)
        XCTAssertNil(ChromiumCookies.cookie(row, value: "fixture"))
        row = .init(host: "example.invalid", name: "sid", path: "/", value: Data(), expires: -1, secure: true)
        XCTAssertNil(ChromiumCookies.cookie(row, value: "fixture"))
        row = .init(host: "example.invalid", name: "sid", path: "/", value: Data(), expires: 14_000_000_000_000_000, secure: true)
        let distant = ChromiumCookies.cookie(row, value: "fixture")
        XCTAssertTrue(distant == nil || distant?.expiresDate?.timeIntervalSince1970 == 2_355_526_400,
                      "Foundation's shortened lifetime must not silently replace the source expiry")
    }

    func testOperaRootWithNetworkCookiesKeepsHistoryAndIsNotMisidentifiedAsNetworkProfile() throws {
        let folder = try fixture(version: 23, network: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("History"))
        let profiles = BrowserImport.chromiumProfiles(browser: "Opera", root: folder)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.path, folder)
        XCTAssertTrue(profiles.first?.hasHistory == true)
        XCTAssertEqual(profiles.first?.profile, "Default")
    }

    func testWeakenedReadbackRemovesOnlyTheNewImportedValue() async throws {
        let candidate = try cookie()
        let unrelated = try cookie("unrelated", value: "keep")
        var stored = [unrelated]
        let result = await ChromiumCookies.publish([candidate], validate: { true }, fetch: { stored }, set: { cookie in
            stored.append(HTTPCookie(properties: [.domain: cookie.domain, .path: cookie.path, .name: cookie.name,
                                                .value: cookie.value, .secure: "TRUE"])!)
        }, remove: { cookie in stored.removeAll { $0.name == cookie.name && $0.value == cookie.value } })
        XCTAssertEqual(result.imported, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(stored.map(\.name), ["unrelated"])
        XCTAssertEqual(stored.first?.value, "keep")
    }

    func testConcurrentPublishersRecheckCollisionsAfterEarlierImportFinishes() async throws {
        let row = try cookie()
        var stored: [HTTPCookie] = []
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            await ChromiumCookies.publish([row], validate: { true }, fetch: { stored }, set: { cookie in
                await withCheckedContinuation { release = $0 }
                stored.append(cookie)
            })
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while release == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(release)
        let second = Task {
            await ChromiumCookies.publish([row], validate: { true }, fetch: { stored }, set: { stored.append($0) })
        }
        release?.resume()
        let one = await first.value, two = await second.value
        XCTAssertEqual(one.imported + two.imported, 1)
        XCTAssertEqual(one.skipped + two.skipped, 1)
        XCTAssertEqual(stored.count, 1)
    }

    func testCancellingDuringSecretWorkerDrainsAdmissionAndNeverAllocatesCookieStore() async throws {
        TestEnvironment.prepare()
        let encrypted = seal(Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = try fixture(version: 23, rows: """
        INSERT INTO cookies VALUES ('example.invalid', 'sid', '/', X'\(encrypted)', 0, 1, 1, 2, '', '', 0, 0);
        """)
        let id = UUID(), gate = CookieSecretGate(), key = SafeStorage.key(secret: secret)
        addTeardownBlock { await MainActor.run { Store.forget(id) } }
        let task = Task {
            try await BrowserImport.importReviewed(from: .init(browser: "Chrome", profile: "Fixture", path: folder,
                hasHistory: false, hasBookmarks: false), profileID: id, includeSessions: true,
                validateDestination: { true }, readKey: { _ in gate.block(); return key },
                cookieAccess: { XCTFail("Cancellation must prevent store allocation"); return .init(fetch: { [] }, set: { _ in XCTFail() }) })
        }
        defer { gate.release(); task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.entered, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(gate.entered)
        XCTAssertTrue(ImportOperations.hasPendingOperations)
        task.cancel()
        gate.release()
        let result = try await task.value
        XCTAssertTrue(result.sessions?.stopped == true)
        XCTAssertEqual(result.sessions?.imported, 0)
        XCTAssertEqual(result.sessions?.skipped, 1)
        XCTAssertFalse(ImportOperations.hasPendingOperations)
    }

    func testReviewOffersSessionsOnlyForSupportedSourcesAndRequiresOptIn() throws {
        _ = NSApplication.shared
        let folder = try fixture(version: 23)
        for browser in ["Chrome", "Edge", "Brave", "Vivaldi", "Opera", "Arc", "Chromium"] {
            let review = BrowserImport.SessionReview(source: .init(browser: browser, profile: "Fixture", path: folder,
                hasHistory: false, hasBookmarks: false))
            XCTAssertTrue(review.option.isEnabled)
            XCTAssertFalse(review.includeSessions)
            review.option.state = .on
            XCTAssertTrue(review.includeSessions)
        }
        for browser in ["Firefox", "Safari", "Unidentified Chromium"] {
            let review = BrowserImport.SessionReview(source: .init(browser: browser, profile: "Fixture", path: folder,
                hasHistory: false, hasBookmarks: false))
            XCTAssertFalse(review.option.isEnabled)
            review.option.state = .on
            XCTAssertFalse(review.includeSessions)
        }
    }

    func testPrivateAndWrongProfileAdmissionNeverOpensAStore() {
        let id = UUID()
        XCTAssertTrue(ChromiumCookies.destinationAllowed(profileID: id, currentProfileID: id, isPrivate: false, profiles: [id]))
        XCTAssertFalse(ChromiumCookies.destinationAllowed(profileID: id, currentProfileID: UUID(), isPrivate: false, profiles: [id]))
        XCTAssertFalse(ChromiumCookies.destinationAllowed(profileID: id, currentProfileID: id, isPrivate: true, profiles: [id]))
        XCTAssertFalse(ChromiumCookies.destinationAllowed(profileID: id, currentProfileID: id, isPrivate: false, profiles: []))
    }
}

private final class CookieSecretGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    var entered: Bool { lock.withLock { started } }
    func block() {
        lock.withLock { started = true }
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}
