#!/usr/bin/env python3
"""Compile actual scoped Keychain routines and exercise a dummy token across processes.

Uses a unique VANE_DATA_DIR namespace, never requests real credentials, and deletes only
its own fixture. A denied/locked Keychain fails the test; no ACL is relaxed. This tests
storage independently of the app's signed/sandboxed integration checks.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
passwords = (ROOT / "Sources/Vane/Passwords.swift").read_text()
store = (ROOT / "Sources/Vane/Store.swift").read_text()


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


selected = ["struct Login", "static func key(", "private static func domain(", "static func namespace(", "private static func query(",
            "static func owns(", "private static func ref(", "static func save(",
            "static func savePreferredCredential(",
            "enum CredentialRead", "enum CredentialCleanup", "private enum CredentialItems",
            "private static func credentialItems(", "static func readCredential(",
            "static func deleteOtherCredentials(", "static func delete(", "static func rank(",
            "private static func usedKey(", "static func lastUsed(", "static func recordUse(",
            "private static func forgetUse("]
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
enum Passwords {
    private static let creator: NSNumber = 0x5661_6E65
    private static func invalidate() {}
''' + "\n".join(declaration(passwords, marker) for marker in selected) + '''
}
let args = CommandLine.arguments
guard args.count >= 3, let profile = UUID(uuidString: args[2]) else { exit(20) }
let host = "api.github.com"
let account = args.count > 3 ? args[3] : ""
let fixture = args.count > 4 ? args[4] : ""
switch args[1] {
case "write":
    guard Passwords.save(host: host, account: account, password: fixture, profileID: profile) else { exit(1) }
    print("PASS dummy GitHub credential persisted")
case "replace":
    guard Passwords.savePreferredCredential(host: host, account: account, password: fixture,
                                            profileID: profile) else { exit(1) }
    print("PASS replacement credential persisted and preferred")
case "read":
    switch Passwords.readCredential(host: host, profileID: profile) {
    case let .found(name, value):
        guard name == account && value == fixture else { exit(2) }
        print("PASS fresh process recovered persisted credential")
    case .missing: print("FAIL persisted credential missing"); exit(3)
    case let .unavailable(status): print("FAIL Keychain read unavailable, status \\(status)"); exit(4)
    }
case "expect-missing":
    guard case .missing = Passwords.readCredential(host: host, profileID: profile) else { exit(7) }
    print("PASS credential namespace stayed isolated")
case "cleanup-others":
    guard case .complete = Passwords.deleteOtherCredentials(host: host, keeping: account,
                                                             profileID: profile) else { exit(8) }
    print("PASS duplicate service credentials cleaned up")
case "expect-account-missing":
    guard !Passwords.delete(host: host, account: account, profileID: profile) else { exit(9) }
    print("PASS old service account was already absent")
case "delete":
    _ = Passwords.delete(host: host, account: account, profileID: profile)
    print("PASS isolated dummy account cleanup attempted")
default: exit(6)
}
'''
with tempfile.TemporaryDirectory(prefix="vane-credential-persistence-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(code)
    binary = path / "check"
    subprocess.run(["xcrun", "swiftc", str(path / "main.swift"), "-o", str(binary)], check=True)
    env_a = dict(os.environ, VANE_DATA_DIR=str(path / "profile-a"))
    env_b = dict(os.environ, VANE_DATA_DIR=str(path / "profile-b"))
    default_profile = "00000000-0000-0000-0000-000056616E65"
    other_profile = "11111111-2222-3333-4444-555555555555"
    old_account, old_token = "aaa-old-fixture", "not-a-token-old"
    new_account, new_token = "zzz-current-fixture", "not-a-token-current"
    try:
        subprocess.run([str(binary), "write", default_profile, old_account, old_token],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "replace", default_profile, new_account, new_token],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "read", default_profile, new_account, new_token],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "expect-missing", other_profile],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "expect-missing", default_profile],
                       env=env_b, check=True, timeout=20)
        subprocess.run([str(binary), "cleanup-others", default_profile, new_account],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "expect-account-missing", default_profile, old_account],
                       env=env_a, check=True, timeout=20)
    finally:
        subprocess.run([str(binary), "delete", default_profile, old_account],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "delete", default_profile, new_account],
                       env=env_a, check=True, timeout=20)
        subprocess.run([str(binary), "expect-missing", default_profile],
                       env=env_a, check=True, timeout=20)
