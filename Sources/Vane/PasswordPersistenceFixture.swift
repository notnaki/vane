import Foundation

/// The signed browser smoke runs in an explicitly isolated directory and re-enters the
/// exact same app for cleanup. Only disposable credentials in that namespace are touched.
@MainActor enum PasswordPersistenceFixture {
    private static let profile = UUID(uuidString: "B81D9738-1A45-401E-B364-8EC5B47A8185")!
    private static let origin = PasswordOrigin(host: "password-persistence.invalid")
    private static var marker: URL { Store.directory.appendingPathComponent("password-persistence-ready") }
    private static var enabled: Bool { Store.overrideDirectory != nil }

    static func stage() throws {
        guard enabled else { return }
        do {
            try Passwords.saveChecked(origin: origin, account: "fixture-a", password: "disposable-original", profileID: profile, replacingExisting: false)
            try Passwords.saveChecked(origin: origin, account: "fixture-b", password: "disposable-second", profileID: profile, replacingExisting: false)
            try Passwords.saveChecked(origin: .init(host: origin.host, port: 8443), account: "", password: "disposable-port", profileID: profile, replacingExisting: false)
            try Passwords.editChecked(.init(origin: origin, account: "fixture-a"), origin: origin, account: "fixture-a", password: "disposable-updated", profileID: profile)
            try Data().write(to: marker)
            print("PASS signed Keychain write/update: staged three isolated credentials for next-process reads")
        } catch { Passwords.deleteAll(profileID: profile); throw error }
    }

    static func verifyAndClean() throws {
        guard enabled, FileManager.default.fileExists(atPath: marker.path) else { return }
        defer { Passwords.deleteAll(profileID: profile); try? FileManager.default.removeItem(at: marker) }
        let expected: [(PasswordOrigin, String, String)] = [(origin, "fixture-a", "disposable-updated"),
            (origin, "fixture-b", "disposable-second"), (.init(host: origin.host, port: 8443), "", "disposable-port")]
        guard try Passwords.allChecked(profileID: profile).count == 3 else { throw Failure() }
        for (site, account, password) in expected {
            guard try Passwords.passwordChecked(origin: site, account: account, profileID: profile) == password else { throw Failure() }
        }
        guard try Passwords.passwordChecked(origin: origin, account: "fixture-a", profileID: UUID()) == nil else { throw Failure() }
        for (site, account, _) in expected { try Passwords.deleteChecked(origin: site, account: account, profileID: profile) }
        guard try Passwords.allChecked(profileID: profile).isEmpty else { throw Failure() }
        print("PASS signed Keychain persistence: fresh process read both accounts, updated secret and separate port; isolated profile and deletion verified")
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Disposable Keychain persistence assertion failed." }
    }
}
