#!/usr/bin/env python3
"""Compile native token storage and exercise dummy credentials across fresh processes.

Uses unique VANE_DATA_DIR namespaces, never requests real credentials, and deletes only
its own fixtures. A denied/locked Keychain fails the test; no ACL is relaxed. This tests
storage independently of the app's signed/sandboxed integration checks.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
passwords = (ROOT / "Sources/Vane/Passwords.swift").read_text()
store = (ROOT / "Sources/Vane/Store.swift").read_text()
credential = (ROOT / "Sources/Vane/GitHubCredential.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# Compile the complete native store. Extract only its actual shared password helpers,
# keeping this probe independent of WebKit/AppKit and the app's build directory.
selected = ["struct Login", "struct Failure", "static func namespace(", "static func owns(",
            "enum CredentialRead", "static func rank(", "private static func usedKey(",
            "static func lastUsed(", "private final class ServiceLane", "private final class Cancellation",
            "static func serialized<", "static func checkServiceCancellation("]
# Include the actual shared instance as well as its type: IntegrationTokens performs
# complete migration/read/write turns through this lane, including cancellation checks.
lane = next(line for line in passwords.splitlines()
            if line.strip() == "private static let serviceLane = ServiceLane()")
code = '''import Foundation
import Security
enum Store { static let overrideDirectory = ProcessInfo.processInfo.environment["VANE_DATA_DIR"] }
enum ProfileManager {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000056616E65")!
    static let activeProfileID = defaultID
    static func defaultsKey(_ base: String, _ profile: UUID) -> String { base + "." + profile.uuidString }
}
extension UserDefaults {
''' + declaration(store, "nonisolated static func suiteName(") + '''
    static var vane: UserDefaults { UserDefaults(suiteName: suiteName(forDataDir: Store.overrideDirectory!))! }
}
''' + (ROOT / "Sources/Vane/PasswordOrigin.swift").read_text() + declaration(credential, "struct GitHubCredential") + '''
enum Passwords {
''' + "\n".join(declaration(passwords, marker) for marker in selected) + "\n" + lane + '''
}
''' + (ROOT / "Sources/Vane/IntegrationTokens.swift").read_text() + '''
let args = CommandLine.arguments
guard args.count >= 3, let profile = UUID(uuidString: args[2]),
      let directory = Store.overrideDirectory, !directory.isEmpty,
      let scope = Passwords.namespace(profileID: profile, dataDir: directory) else { exit(20) }
let tokens = IntegrationTokens(profileID: profile, lastUsed: [:])
let account = args.count > 3 ? args[3] : ""
let fixture = args.count > 4 ? args[4] : ""
// The legacy fixture is restricted to this unique temporary data-directory namespace.
let legacyQuery: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
    kSecAttrServer as String: "api.github.com", kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
    kSecAttrCreator as String: NSNumber(value: 0x5661_6E65), kSecAttrSecurityDomain as String: scope]
switch args[1] {
case "seed-legacy":
    var query = legacyQuery
    query[kSecAttrAccount as String] = account
    query[kSecValueData as String] = Data(fixture.utf8)
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { exit(1) }
    print("PASS isolated legacy fixture stored")
case "write", "replace":
    guard tokens.save(account: account, password: fixture) else { exit(1) }
    print("PASS native integration credential persisted")
case "read":
    switch tokens.read() {
    case let .found(name, value):
        guard name == account && value == fixture else { exit(2) }
        print("PASS fresh process recovered native credential")
    case .missing: print("FAIL persisted credential missing"); exit(3)
    case let .unavailable(status): print("FAIL Keychain read unavailable, status \\(status)"); exit(4)
    }
case "expect-legacy-missing":
    guard SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecItemNotFound else { exit(12) }
    print("PASS migrated legacy fixture removed after native storage")
case "write-oauth":
    let grant = GitHubCredential(accessToken: fixture, refreshToken: "nonsecret-refresh-fixture",
                                 expiresAt: Date(timeIntervalSince1970: 1000000),
                                 refreshExpiresAt: Date(timeIntervalSince1970: 2000000))
    guard tokens.save(account: account, password: grant.stored) else { exit(10) }
    print("PASS complete dummy OAuth pair persisted")
case "read-oauth":
    guard case let .found(name, value) = tokens.read(),
          name == account, let grant = GitHubCredential.restore(value),
          grant.accessToken == fixture, grant.refreshToken == "nonsecret-refresh-fixture",
          grant.expiresAt == Date(timeIntervalSince1970: 1000000),
          grant.refreshExpiresAt == Date(timeIntervalSince1970: 2000000) else { exit(11) }
    print("PASS fresh process recovered complete OAuth pair and expiry")
case "expect-missing":
    guard case .missing = tokens.read() else { exit(7) }
    print("PASS credential namespace stayed isolated")
case "expect-account-missing":
    guard !tokens.delete(account: account) else { exit(9) }
    print("PASS replaced account cannot remove current native credential")
case "delete":
    guard tokens.deleteAll() else { print("FAIL fixture cleanup unavailable"); exit(13) }
    guard case .missing = tokens.read() else { exit(14) }
    print("PASS isolated dummy credentials removed")
default: exit(6)
}
'''
with tempfile.TemporaryDirectory(prefix="vane-credential-persistence-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(code)
    binary = path / "check"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", str(path / "main.swift"), "-o", str(binary)], check=True)
    env_a = dict(os.environ, VANE_DATA_DIR=str(path / "profile-a"))
    env_b = dict(os.environ, VANE_DATA_DIR=str(path / "profile-b"))
    default_profile = "00000000-0000-0000-0000-000056616E65"
    other_profile = "11111111-2222-3333-4444-555555555555"
    old_account, old_token = "aaa-old-fixture", "not-a-token-old"
    new_account, new_token = "zzz-current-fixture", "not-a-token-current"

    def run(command, profile=default_profile, account="", value="", env=env_a):
        subprocess.run([str(binary), command, profile, account, value], env=env, check=True, timeout=20)

    try:
        run("seed-legacy", account=old_account, value=old_token)
        run("read", account=old_account, value=old_token)
        run("expect-legacy-missing")
        run("replace", account=new_account, value=new_token)
        run("read", account=new_account, value=new_token)
        run("expect-missing", profile=other_profile)
        run("expect-missing", env=env_b)
        run("write-oauth", account=new_account, value=new_token)
        run("read-oauth", account=new_account, value=new_token)
        run("expect-account-missing", account=old_account)
        run("read-oauth", account=new_account, value=new_token)
    finally:
        run("delete")
        run("expect-missing")
