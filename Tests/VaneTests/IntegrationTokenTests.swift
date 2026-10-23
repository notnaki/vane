import Security
import XCTest
@testable import vane

/// In-memory SecItem operations exercise the production queries, migration and cleanup.
/// No test invokes the user's Keychain or holds a real token.
private final class TokenKeychain {
    var items: [[String: Any]] = []
    var copyStatus: OSStatus?
    var addStatus: OSStatus?
    var deleteStatus: OSStatus?
    var updateStatus: OSStatus?
    var beforeAdd: (() -> Void)?
    var secretReadStatus: OSStatus?
    private var serial = 0

    var operations: IntegrationTokens.Keychain {
        .init(copy: { [self] query, result in
            if let copyStatus { return copyStatus }
            let q = query as NSDictionary as! [String: Any]
            if q[kSecReturnData as String] as? Bool == true, let secretReadStatus { return secretReadStatus }
            let matches = items.filter { self.matches($0, q) }
            guard !matches.isEmpty else { return errSecItemNotFound }
            if q[kSecReturnAttributes as String] as? Bool == true { result?.pointee = matches as CFArray }
            else { result?.pointee = (matches[0][kSecValueData as String] as? Data).map { $0 as CFData } }
            return errSecSuccess
        }, add: { [self] query, _ in
            if let addStatus { return addStatus }
            let before = beforeAdd
            beforeAdd = nil
            before?()
            var item = query as NSDictionary as! [String: Any]
            if items.contains(where: {
                ($0[kSecClass as String] as? String) == (item[kSecClass as String] as? String)
                && ($0[kSecAttrService as String] as? String) == (item[kSecAttrService as String] as? String)
                && ($0[kSecAttrAccount as String] as? String) == (item[kSecAttrAccount as String] as? String)
            }) { return errSecDuplicateItem }
            serial += 1
            item[kSecValuePersistentRef as String] = Data("native-\(serial)".utf8)
            items.append(item)
            return errSecSuccess
        }, update: { [self] query, changes in
            if let updateStatus { return updateStatus }
            let q = query as NSDictionary as! [String: Any]
            guard let index = items.firstIndex(where: { matches($0, q) }) else { return errSecItemNotFound }
            for (key, value) in changes as NSDictionary as! [String: Any] { items[index][key] = value }
            return errSecSuccess
        }, delete: { [self] query in
            if let deleteStatus { return deleteStatus }
            let q = query as NSDictionary as! [String: Any]
            let before = items.count
            items.removeAll { matches($0, q) }
            return before == items.count ? errSecItemNotFound : errSecSuccess
        })
    }

    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        query.allSatisfy { key, value in
            guard [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String,
                   kSecAttrCreator as String, kSecAttrServer as String, kSecAttrProtocol as String,
                   kSecAttrSecurityDomain as String, kSecValuePersistentRef as String].contains(key) else { return true }
            guard let actual = item[key] as? NSObject, let requested = value as? NSObject else { return false }
            return actual == requested
        }
    }

    func legacy(profile: UUID, directory: String?, account: String = "fixture", token: String = "old-fixture", creator: Int = 0x56616E65) {
        var item: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "api.github.com", kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrCreator as String: creator, kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8), kSecValuePersistentRef as String: Data(UUID().uuidString.utf8)]
        if let scope = Passwords.namespace(profileID: profile, dataDir: directory) { item[kSecAttrSecurityDomain as String] = scope }
        items.append(item)
    }
}

final class IntegrationTokenTests: XCTestCase {
    private let profile = UUID()
    private let directory = "/tmp/vane-integration-token-fixture"
    private func store(_ keychain: TokenKeychain, profile: UUID? = nil, directory: String? = "/tmp/vane-integration-token-fixture") -> IntegrationTokens {
        IntegrationTokens(profileID: profile ?? self.profile, dataDir: directory, keychain: keychain.operations, lastUsed: [:])
    }
    private func found(_ read: Passwords.CredentialRead, account: String = "fixture", token: String = "old-fixture", file: StaticString = #filePath, line: UInt = #line) {
        guard case .found(let actualAccount, let actualToken) = read else { XCTFail("Expected stored integration credential", file: file, line: line); return }
        XCTAssertEqual(actualAccount, account, file: file, line: line)
        XCTAssertEqual(actualToken, token, file: file, line: line)
    }

    func testNativeTokenClassAndProfileAndInstanceIsolation() {
        let keychain = TokenKeychain()
        let own = store(keychain)
        XCTAssertTrue(own.save(account: "fixture", password: "old-fixture"))
        found(store(keychain).read())
        XCTAssertEqual(keychain.items.first?[kSecClass as String] as? String, kSecClassGenericPassword as String)
        for other in [store(keychain, profile: UUID()), store(keychain, directory: "/tmp/other-instance"), store(keychain, directory: nil)] {
            guard case .missing = other.read() else { XCTFail("Another profile or instance must not see this token"); continue }
            XCTAssertTrue(other.deleteAll())
        }
        found(own.read())
    }

    func testMigrationSelectsPreferredOwnedLegacyAccountAndDeletesOnlyAfterNativeSave() {
        let keychain = TokenKeychain()
        keychain.legacy(profile: profile, directory: directory, account: "old", token: "stale")
        keychain.legacy(profile: profile, directory: directory, account: "preferred")
        keychain.legacy(profile: UUID(), directory: directory)
        keychain.legacy(profile: profile, directory: "/tmp/other-instance")
        keychain.legacy(profile: profile, directory: directory, creator: 123)
        let own = IntegrationTokens(profileID: profile, dataDir: directory, keychain: keychain.operations,
            lastUsed: [PasswordOrigin(host: "api.github.com").key(account: "preferred"): Date()])
        found(own.read(), account: "preferred")
        XCTAssertEqual(keychain.items.count, 4, "One native token and all three foreign items survive")
        found(own.read(), account: "preferred")
    }

    func testLockedReadAndFailedMigrationRetainLegacyAndRetry() {
        let keychain = TokenKeychain()
        keychain.legacy(profile: profile, directory: directory)
        let own = store(keychain)
        keychain.copyStatus = errSecInteractionNotAllowed
        if case .unavailable(let status) = own.read() { XCTAssertEqual(status, errSecInteractionNotAllowed) }
        else { XCTFail("Locked is not missing") }
        keychain.copyStatus = nil
        keychain.addStatus = errSecNotAvailable
        if case .unavailable(let status) = own.read() { XCTAssertEqual(status, errSecNotAvailable) }
        else { XCTFail("Failed migration must not claim durable storage") }
        XCTAssertEqual(keychain.items.count, 1)
        keychain.addStatus = nil
        found(own.read())
        XCTAssertEqual(keychain.items.count, 1)
        XCTAssertEqual(keychain.items.first?[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }

    func testLegacyCleanupFailureKeepsNewTokenAndSignOutCannotResurrectOldToken() {
        let keychain = TokenKeychain()
        keychain.legacy(profile: profile, directory: directory)
        keychain.deleteStatus = errSecInteractionNotAllowed
        let own = store(keychain)
        found(own.read())
        XCTAssertEqual(keychain.items.count, 2)
        XCTAssertFalse(own.deleteAll())
        found(own.read())
        keychain.deleteStatus = nil
        XCTAssertTrue(own.deleteAll())
        guard case .missing = own.read() else { return XCTFail("Sign out removed both native and legacy token") }
    }

    func testReplacementAndFailedUpdateNeverReviveLegacyToken() {
        let keychain = TokenKeychain(), own = store(keychain)
        XCTAssertTrue(own.save(account: "fixture", password: "old-fixture"))
        keychain.updateStatus = errSecAuthFailed
        XCTAssertFalse(own.save(account: "replacement", password: "new-fixture"))
        found(own.read())
        keychain.updateStatus = nil
        XCTAssertTrue(own.save(account: "replacement", password: "new-fixture"))
        found(own.read(), account: "replacement", token: "new-fixture")
        XCTAssertFalse(own.delete(account: "fixture"), "A stale sign out must not delete a replacement account")
        found(own.read(), account: "replacement", token: "new-fixture")
    }

    func testDefaultProfileMigrationSkipsEveryNamespacedNeighbor() {
        let keychain = TokenKeychain(), defaultID = ProfileManager.defaultID
        keychain.legacy(profile: defaultID, directory: nil)
        keychain.legacy(profile: UUID(), directory: nil)
        keychain.legacy(profile: defaultID, directory: directory)
        let own = store(keychain, profile: defaultID, directory: nil)
        found(own.read())
        XCTAssertTrue(own.deleteAll())
        XCTAssertEqual(keychain.items.count, 2)
    }

    func testNativeSecretReadFailureIsUnavailableAndNeverFallsBackToLegacy() {
        let keychain = TokenKeychain(), own = store(keychain)
        XCTAssertTrue(own.save(account: "replacement", password: "new-fixture"))
        keychain.legacy(profile: profile, directory: directory)
        keychain.secretReadStatus = errSecAuthFailed
        if case .unavailable(let status) = own.read() { XCTAssertEqual(status, errSecAuthFailed) }
        else { XCTFail("Failed native read cannot become missing or a legacy fallback") }
        XCTAssertEqual(keychain.items.count, 2)
        keychain.secretReadStatus = nil
        found(own.read(), account: "replacement", token: "new-fixture")
    }

    func testMalformedLegacyAccountIsUnavailableRatherThanMissing() {
        let keychain = TokenKeychain(), own = store(keychain)
        keychain.legacy(profile: profile, directory: directory, account: "")
        if case .unavailable(let status) = own.read() { XCTAssertEqual(status, errSecDecode) }
        else { XCTFail("An owned undecodable legacy token must not appear absent") }
        XCTAssertEqual(keychain.items.count, 1)
    }

    func testCorruptNativeValuePreservesLegacyWithoutExposingOrDeletingIt() {
        let keychain = TokenKeychain(), own = store(keychain)
        XCTAssertTrue(own.save(account: "fixture", password: "old-fixture"))
        keychain.items[0][kSecValueData as String] = Data("invalid-envelope".utf8)
        keychain.legacy(profile: profile, directory: directory)
        if case .unavailable(let status) = own.read() { XCTAssertEqual(status, errSecDecode) }
        else { XCTFail("Malformed native storage is unavailable, never a fallback") }
        XCTAssertEqual(keychain.items.count, 2)
    }

    func testMigrationRacingReplacementReturnsDurableWinner() {
        let keychain = TokenKeychain(), own = store(keychain)
        keychain.legacy(profile: profile, directory: directory)
        keychain.beforeAdd = { XCTAssertTrue(own.save(account: "replacement", password: "new-fixture")) }
        found(own.read(), account: "replacement", token: "new-fixture")
        found(store(keychain).read(), account: "replacement", token: "new-fixture")
        XCTAssertEqual(keychain.items.count, 1)
    }

    func testForeignCreatorCollisionCannotBeUpdatedOrDeleted() {
        let keychain = TokenKeychain(), own = store(keychain)
        XCTAssertTrue(own.save(account: "foreign", password: "foreign-fixture"))
        keychain.items[0][kSecAttrCreator as String] = 123
        keychain.legacy(profile: profile, directory: directory)
        if case .unavailable(let status) = own.read() { XCTAssertEqual(status, errSecDuplicateItem) }
        else { XCTFail("Migration cannot replace another creator's generic-password item") }
        XCTAssertFalse(own.save(account: "fixture", password: "replacement"))
        XCTAssertEqual(keychain.items.count, 2)
        XCTAssertTrue(own.deleteAll())
        XCTAssertEqual(keychain.items.count, 1)
        XCTAssertEqual(keychain.items.first?[kSecAttrCreator as String] as? Int, 123)
    }

    func testDefaultInstanceErasePreservesEveryIsolatedInstance() {
        let keychain = TokenKeychain()
        let own = store(keychain, profile: ProfileManager.defaultID, directory: nil)
        let sibling = store(keychain, profile: UUID(), directory: nil)
        let isolated = store(keychain)
        for token in [own, sibling, isolated] { XCTAssertTrue(token.save(account: "fixture", password: "old-fixture")) }
        keychain.legacy(profile: ProfileManager.defaultID, directory: nil)
        keychain.legacy(profile: UUID(), directory: nil)
        keychain.legacy(profile: profile, directory: directory)
        Passwords.deleteEverything(dataDir: nil, keychain: keychain.operations)
        XCTAssertEqual(keychain.items.count, 2)
        guard case .missing = own.read() else { return XCTFail("Default profile token was erased") }
        guard case .missing = sibling.read() else { return XCTFail("Other real profile token was erased") }
        found(isolated.read())
    }

    func testPasswordEraseDeletesOnlyItsOwnInstanceIncludingNativeTokens() {
        let keychain = TokenKeychain(), own = store(keychain), foreign = store(keychain, directory: "/tmp/other-instance")
        XCTAssertTrue(own.save(account: "fixture", password: "old-fixture"))
        XCTAssertTrue(foreign.save(account: "fixture", password: "old-fixture"))
        keychain.legacy(profile: profile, directory: directory)
        keychain.legacy(profile: profile, directory: "/tmp/other-instance")
        Passwords.deleteEverything(dataDir: directory, keychain: keychain.operations)
        XCTAssertEqual(keychain.items.count, 2, "Foreign native and legacy items survive erasing this instance")
        guard case .missing = own.read() else { return XCTFail("Own token was erased") }
        found(foreign.read())
    }

    func testPasswordProfileDeleteRemovesNativeTokenWithoutDeletingNeighbor() {
        let keychain = TokenKeychain(), own = store(keychain), foreign = store(keychain, profile: UUID())
        XCTAssertTrue(own.save(account: "fixture", password: "old-fixture"))
        XCTAssertTrue(foreign.save(account: "fixture", password: "old-fixture"))
        Passwords.deleteAll(profileID: profile, dataDir: directory, keychain: keychain.operations)
        XCTAssertEqual(keychain.items.count, 1)
        guard case .missing = own.read() else { return XCTFail("Deleted profile token must not survive") }
        found(foreign.read())
    }

    func testErasingOneInstancePreservesOtherInstanceAndNativeCredentials() {
        let keychain = TokenKeychain(), own = store(keychain), sibling = store(keychain, profile: UUID())
        let foreign = store(keychain, directory: "/tmp/other-instance")
        for token in [own, sibling, foreign] { XCTAssertTrue(token.save(account: "fixture", password: "old-fixture")) }
        XCTAssertTrue(IntegrationTokens.deleteEverything(dataDir: directory, keychain: keychain.operations))
        XCTAssertEqual(keychain.items.count, 1)
        found(foreign.read())
    }
}
