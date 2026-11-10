import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3
import WebKit

/// Chromium macOS v10 AES-CBC. Secrets and decrypted values remain in memory.
enum SafeStorage {
    /// The version tag Chromium writes in front of every value it encrypted on macOS.
    /// `v11` is Linux's libsecret variant and never appears here; a row with neither prefix
    /// is plaintext from before encryption was turned on.
    static let prefix = Data("v10".utf8)

    static let salt = Data("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let keyLength = kCCKeySizeAES128
    /// Sixteen 0x20 bytes — the ASCII space, repeated. Chromium's constant, not a choice.
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// The AES key for one browser's keychain secret.
    ///
    /// The *bytes*, not a String. A keychain generic password is a bag of bytes and nothing
    /// promises it is UTF-8; decoding it first would turn one stray byte into U+FFFD and
    /// derive a key that opens nothing, with no error anywhere — every password and every
    /// session lost to a silently wrong answer. Chromium's own secret is base64 and would
    /// always survive the round trip, but that is a fact about today's Arc and not about the
    /// keychain, and the bytes cost nothing.
    static func key(secret: Data) -> Data {
        var out = Data(count: keyLength)
        let ok = out.withUnsafeMutableBytes { key in
            secret.withUnsafeBytes { secret in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         secret.bindMemory(to: Int8.self).baseAddress,
                                         secret.count,
                                         salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                                         key.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        return ok == kCCSuccess ? out : Data()
    }

    /// The same over text, which is how `check()` pins the derivation to a known answer
    /// without a keychain in the room.
    static func key(secret: String) -> Data { key(secret: Data(secret.utf8)) }

    /// One `encrypted_value` or `password_value`, in the clear.
    ///
    /// `hostKey` is the cookie's `host_key` and is what makes the newer Chromium format
    /// readable: since M127 a cookie's plaintext is SHA-256 of its host key followed by the
    /// value, so that a cookie copied into another domain's row decrypts to nothing useful.
    /// It is checked rather than assumed — a `Login Data` row has no host prefix, and neither
    /// does a cookie written by an older Arc — so the same function reads both formats.
    ///
    /// nil for anything that does not come out as UTF-8: a value encrypted under a different
    /// key, a truncated row, or a profile whose keychain item is not the one we read.
    static func decrypt(_ value: Data, key: Data, hostKey: String? = nil,
                        requiresHostHash: Bool = false) -> String? {
        guard key.count == keyLength, value.count > prefix.count,
              value.prefix(prefix.count) == prefix else { return nil }
        let body = Data(value.dropFirst(prefix.count))
        guard body.count >= kCCBlockSizeAES128, body.count % kCCBlockSizeAES128 == 0 else { return nil }

        var out = Data(count: body.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                iv.withUnsafeBytes { iv in
                    key.withUnsafeBytes { key in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, keyLength, iv.baseAddress,
                                src.baseAddress, src.count,
                                dst.baseAddress, dst.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out = out.prefix(written)

        if let hostKey {
            let hash = Data(SHA256.hash(data: Data(hostKey.utf8)))
            if out.count >= hash.count, out.prefix(hash.count) == hash {
                out = out.dropFirst(hash.count)
            } else if requiresHostHash { return nil }
        }
        return String(data: out, encoding: .utf8)
    }
}


/// Shared read-only Chromium cookie migration, used by Arc and general import.
enum ChromiumCookies {
    struct Identity: Equatable, Sendable {
        let service: String
        let account: String
    }

    static let browsers = ["Chrome", "Chromium", "Edge", "Brave", "Vivaldi", "Opera", "Arc"]

    static func identity(browser: String) -> Identity? {
        let account: String
        switch browser {
        case "Chrome", "Chromium", "Brave", "Vivaldi", "Opera", "Arc": account = browser
        case "Edge": account = "Microsoft Edge"
        default: return nil
        }
        return Identity(service: account + " Safe Storage", account: account)
    }

    /// Read exactly the reviewed browser identity. Never create an item, try other keys,
    /// or silently use another browser's Safe Storage secret.
    static func key(identity: Identity, readSecret: (Identity) -> Data? = readSecret) -> Data? {
        guard let secret = readSecret(identity), !secret.isEmpty else { return nil }
        let key = SafeStorage.key(secret: secret)
        return key.isEmpty ? nil : key
    }

    private static func readSecret(_ identity: Identity) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identity.service,
            kSecAttrAccount as String: identity.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    struct Snapshot: Sendable {
        let version: Int
        let rows: [Row]
    }

    struct Opened: Sendable {
        var cookies: [HTTPCookie] = []
        var skipped = 0
        var failed = 0
        var unsupportedEncryption = 0
    }

    static func file(at profile: URL) -> URL? {
        for relative in ["Network/Cookies", "Cookies"] {
            let file = profile.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// Only known layouts are admitted. Optional partition flags can add a rejection;
    /// a missing security/lifetime column can never silently become a weaker default.
    static func read(at profile: URL) throws -> Snapshot {
        guard let file = file(at: profile) else { throw BrowserImport.Failure("No cookie database was found.") }
        return try BrowserImport.snapshot(file) { db in
            var version: Int?
            try BrowserImport.query(db: db, file: file, sql: "SELECT value FROM meta WHERE key = 'version'") {
                version = Int(text($0, 0))
            }
            guard let version, [23, 24].contains(version) else {
                throw BrowserImport.Failure("Unsupported cookie database schema. Vane supports versions 23 and 24; no cookies were read.")
            }
            var columns = Set<String>()
            try BrowserImport.query(db: db, file: file, sql: "PRAGMA table_info(cookies)") { columns.insert(text($0, 1)) }
            let required: Set<String> = ["host_key", "name", "path", "encrypted_value", "expires_utc", "is_secure",
                                         "is_httponly", "samesite", "top_frame_site_key", "value", "has_expires", "is_persistent"]
            guard required.isSubset(of: columns) else {
                throw BrowserImport.Failure("The cookie database is missing required security or lifetime fields; no cookies were read.")
            }
            let partitioned = columns.contains("is_partitioned") ? "is_partitioned" : "0"
            var rows: [Row] = []
            try BrowserImport.query(db: db, file: file, sql: """
                SELECT host_key, name, path, encrypted_value, expires_utc, is_secure,
                       is_httponly, samesite, top_frame_site_key, value, has_expires, is_persistent, \(partitioned)
                FROM cookies ORDER BY rowid
                """) {
                let row = $0
                let textValid = [0, 1, 2, 8, 9].allSatisfy { validText(row, Int32($0)) }
                let flagsValid = [5, 6, 10, 11, 12].allSatisfy {
                    sqlite3_column_type(row, Int32($0)) == SQLITE_INTEGER
                        && (0...1).contains(sqlite3_column_int64(row, Int32($0)))
                }
                let numbersValid = sqlite3_column_type(row, 4) == SQLITE_INTEGER && sqlite3_column_int64(row, 4) >= 0
                    && sqlite3_column_type(row, 7) == SQLITE_INTEGER && (-1...2).contains(sqlite3_column_int64(row, 7))
                let hasExpiry = sqlite3_column_int64(row, 10) == 1
                let persistent = sqlite3_column_int64(row, 11) == 1
                let expiry = sqlite3_column_int64(row, 4)
                let lifetimeValid = hasExpiry == persistent && (expiry > 0) == persistent
                let malformed = !textValid || !flagsValid || !numbersValid || !lifetimeValid
                    || sqlite3_column_type(row, 3) != SQLITE_BLOB
                rows.append(.init(host: text($0, 0), name: text($0, 1), path: text($0, 2), value: blob($0, 3),
                                  expires: expiry,
                                  secure: sqlite3_column_int($0, 5) != 0, httpOnly: sqlite3_column_int($0, 6) != 0,
                                  sameSite: Int(sqlite3_column_int($0, 7)),
                                  partitioned: !text($0, 8).isEmpty || sqlite3_column_int($0, 12) != 0,
                                  plaintext: text($0, 9), malformed: malformed))
            }
            return Snapshot(version: version, rows: rows)
        }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private static func validText(_ row: OpaquePointer, _ column: Int32) -> Bool {
        guard sqlite3_column_type(row, column) == SQLITE_TEXT, let bytes = sqlite3_column_text(row, column),
              let value = String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8)
        else { return false }
        return !value.utf8.contains(0)
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }

    static func open(_ snapshot: Snapshot, key: Data?) -> Opened {
        var result = Opened()
        for (index, row) in snapshot.rows.enumerated() {
            if Task.isCancelled { result.skipped += snapshot.rows.count - index; break }
            guard [23, 24].contains(snapshot.version), !row.partitioned else { result.skipped += 1; continue }
            // Reject unusable/expired rows before asking decryption to interpret them.
            guard cookie(row, value: "") != nil else { result.skipped += 1; continue }
            let value: String
            if row.value.isEmpty { value = row.plaintext }
            else {
                guard row.value.starts(with: SafeStorage.prefix) else {
                    result.skipped += 1; result.unsupportedEncryption += 1; continue
                }
                guard let key, let decrypted = SafeStorage.decrypt(row.value, key: key,
                    hostKey: snapshot.version == 24 ? row.host : nil, requiresHostHash: snapshot.version == 24)
                else { result.failed += 1; continue }
                value = decrypted
            }
            guard let cookie = cookie(row, value: value) else { result.skipped += 1; continue }
            result.cookies.append(cookie)
        }
        return result
    }

    struct Report: Sendable {
        var imported = 0
        var skipped = 0
        var failed = 0
        var unsupportedEncryption = 0
        var stopped = false
    }

    @MainActor struct Access {
        let fetch: @MainActor () async throws -> [HTTPCookie]
        let set: @MainActor (HTTPCookie) async throws -> Void
        let remove: @MainActor (HTTPCookie) async throws -> Void

        init(fetch: @escaping @MainActor () async throws -> [HTTPCookie],
             set: @escaping @MainActor (HTTPCookie) async throws -> Void,
             remove: @escaping @MainActor (HTTPCookie) async throws -> Void = { _ in }) {
            self.fetch = fetch; self.set = set; self.remove = remove
        }
        init(store: WKHTTPCookieStore) {
            fetch = { await store.allCookies() }
            set = { await store.setCookie($0) }
            remove = { await store.deleteCookie($0) }
        }
    }

    static func destinationAllowed(profileID: UUID, currentProfileID: UUID, isPrivate: Bool, profiles: [UUID]) -> Bool {
        !isPrivate && profileID == currentProfileID && profiles.contains(profileID)
    }

    @MainActor static func publish(_ cookies: [HTTPCookie], validate: @MainActor () -> Bool,
        fetch: @MainActor () async throws -> [HTTPCookie], set: @MainActor (HTTPCookie) async throws -> Void,
        checkCancellation: () -> Bool = { Task.isCancelled },
        remove: @MainActor (HTTPCookie) async throws -> Void = { _ in }) async -> Report {
        await acquirePublisher()
        defer { releasePublisher() }
        var report = Report()
        for (index, cookie) in cookies.enumerated() {
            guard !checkCancellation(), validate() else {
                report.skipped += cookies.count - index; report.stopped = true; break
            }
            guard cookie.expiresDate.map({ $0 > Date() }) ?? true else { report.skipped += 1; continue }
            do {
                let existing = try await fetch()
                guard !checkCancellation(), validate() else {
                    report.skipped += cookies.count - index; report.stopped = true; break
                }
                guard cookie.expiresDate.map({ $0 > Date() }) ?? true,
                      !existing.contains(where: { collision($0, cookie) }) else { report.skipped += 1; continue }
                try await set(cookie)
                // Inspect only the captured original store, even if destination admission
                // changed during the write. This accounts for work which already completed.
                let stored = try await fetch()
                if stored.contains(where: { equivalent($0, cookie) }) { report.imported += 1 }
                else {
                    // Never leave our newly copied token behind with weaker attributes.
                    // Limit cleanup to the imported value; a live site's later replacement
                    // belongs to that site and must not be deleted by this import.
                    for candidate in stored where collision(candidate, cookie) && candidate.value == cookie.value {
                        try await remove(candidate)
                    }
                    report.failed += 1
                }
            } catch { report.failed += 1 }
        }
        return report
    }

    // WebKit has no compare-and-set cookie API. Serialize Vane import publishers and
    // refresh collisions immediately before each write; never hold a stale batch list.
    @MainActor private static var publishing = false
    @MainActor private static var publishers: [CheckedContinuation<Void, Never>] = []

    @MainActor private static func acquirePublisher() async {
        if publishing { await withCheckedContinuation { publishers.append($0) } }
        else { publishing = true }
    }

    @MainActor private static func releasePublisher() {
        if publishers.isEmpty { publishing = false }
        else { publishers.removeFirst().resume() }
    }

    private static func collision(_ first: HTTPCookie, _ second: HTTPCookie) -> Bool {
        func host(_ cookie: HTTPCookie) -> String {
            cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }
        return first.name == second.name && first.path == second.path && host(first) == host(second)
    }

    private static func equivalent(_ first: HTTPCookie, _ second: HTTPCookie) -> Bool {
        first.name == second.name && first.value == second.value && first.domain == second.domain
            && first.path == second.path && first.isSecure == second.isSecure && first.isHTTPOnly == second.isHTTPOnly
            && first.sameSitePolicy == second.sameSitePolicy && first.isSessionOnly == second.isSessionOnly
            && first.expiresDate == second.expiresDate
    }

    struct Row: Sendable {
        let host: String, name: String, path: String, value: Data
        let expires: Int64, secure: Bool
        var httpOnly = false
        var sameSite = -1
        var partitioned = false
        var plaintext = ""
        var malformed = false
    }

    /// Parse a Set-Cookie header to preserve HttpOnly. Verify the result instead of
    /// accepting Foundation's normalization of security, scope or lifetime.
    nonisolated static func cookie(_ row: Row, value: String) -> HTTPCookie? {
        guard !row.partitioned, !row.malformed, row.expires >= 0, !row.host.isEmpty, !row.name.isEmpty,
              row.value.isEmpty || row.plaintext.isEmpty,
              row.path.hasPrefix("/"),
              (-1...2).contains(row.sameSite) else { return nil }
        if row.name.hasPrefix("__Secure-"), !row.secure { return nil }
        if row.name.hasPrefix("__Host-"), !row.secure || row.host.hasPrefix(".") || row.path != "/" { return nil }
        func headerSafe(_ text: String) -> Bool {
            !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == ";" }
        }
        guard headerSafe(row.name), !row.name.contains("="), headerSafe(value),
              headerSafe(row.host), headerSafe(row.path) else { return nil }
        let host = row.host.hasPrefix(".") ? String(row.host.dropFirst()) : row.host
        var origin = URLComponents()
        origin.scheme = row.secure ? "https" : "http"
        origin.host = host
        guard let url = origin.url, url.host == host else { return nil }
        var header = "\(row.name)=\(value); Path=\(row.path.isEmpty ? "/" : row.path)"
        if row.host.hasPrefix(".") { header += "; Domain=\(row.host)" }
        if row.secure { header += "; Secure" }
        if row.httpOnly { header += "; HttpOnly" }
        switch row.sameSite {
        case 0: header += "; SameSite=None"
        case 1: header += "; SameSite=Lax"
        case 2: header += "; SameSite=Strict"
        default: break
        }
        if let expires = (row.expires > 0 ? BrowserImport.chromiumTime(row.expires) : nil) {
            guard expires > Date() else { return nil }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            header += "; Expires=" + format.string(from: expires)
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url).first,
              cookie.name == row.name, cookie.value == value,
              cookie.isHTTPOnly == row.httpOnly, cookie.isSecure == row.secure,
              cookie.domain == row.host,
              cookie.path == (row.path.isEmpty ? "/" : row.path),
              row.sameSite != -1 || cookie.sameSitePolicy == nil,
              row.sameSite != 0 || cookie.sameSitePolicy?.rawValue == "none",
              row.sameSite != 1 || cookie.sameSitePolicy?.rawValue == "lax",
              row.sameSite != 2 || cookie.sameSitePolicy?.rawValue == "strict",
              (row.expires == 0) == cookie.isSessionOnly else { return nil }
        if let expires = (row.expires > 0 ? BrowserImport.chromiumTime(row.expires) : nil) {
            guard let retained = cookie.expiresDate,
                  abs(retained.timeIntervalSince1970 - expires.timeIntervalSince1970) < 1 else { return nil }
        }
        return cookie
    }

}
