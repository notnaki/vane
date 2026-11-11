import XCTest
import Security
import CloudKit
@testable import vane

@MainActor final class ICloudSecretsTests: XCTestCase {
    private let password = ICloudSecrets.Identity.password(profileID: ProfileManager.defaultID, origin: "https://example.com", account: "alice")
    private let key = ICloudSecrets.Identity.aiKey(account: "openAI")

    private func bridge(_ keychain: MemorySecretKeychain, _ local: MemoryLocalSecrets, namespace: String = "test-a") -> ICloudSecrets {
        let bridge = ICloudSecrets(configuration: .init(accessGroup: "TEAM.io.vane", namespace: namespace, localDeviceID: local.deviceID), keychain: keychain, local: local)
        bridge.setAccountNamespace("dedicated-account")
        return bridge
    }

    func testQueriesRequireOptInAccessGroupDataProtectionAndSynchronizableAccessibility() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        local.values[password] = Data("fixture".utf8)
        let bridge = bridge(store, local)
        try await bridge.sync(enabled: [], generationIsCurrent: { true })
        XCTAssertTrue(store.queries.isEmpty)
        try await bridge.sync(enabled: [.passwords], generationIsCurrent: { true })
        let cloud = store.additions.first { $0[kSecAttrSynchronizable as String] as? Bool == true }
        XCTAssertEqual(cloud?[kSecAttrAccessGroup as String] as? String, "TEAM.io.vane")
        XCTAssertEqual(cloud?[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(cloud?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(local.values[password], Data("fixture".utf8))
        XCTAssertFalse(store.queries.contains { $0[kSecReturnPersistentRef as String] != nil })
    }

    func testCloudConflictPreservesBothOriginals() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("first".utf8)
        second.values[password] = Data("second".utf8)
        try await bridge(store, first).sync(enabled: [.passwords], generationIsCurrent: { true })
        let other = bridge(store, second)
        try await other.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(other.conflicts.count, 1)
        XCTAssertEqual(second.values[password], Data("second".utf8))
        XCTAssertEqual(store.cloudCount, 1)
    }

    func testVerifiedMirrorRefreshesRemoteAndTracksSubsequentLocalEditAndDeletion() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("first".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(second.values[password], first.values[password])
        first.values[password] = Data("updated".utf8)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(second.values[password], Data("updated".utf8))
        first.values.removeValue(forKey: password)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertNil(second.values[password])
    }

    func testDisabledCategoriesAndTestNamespacesNeverReadOrWriteEachOther() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("password".utf8)
        first.values[key] = Data("api-key".utf8)
        try await bridge(store, first).sync(enabled: [.aiKeys], generationIsCurrent: { true })
        XCTAssertEqual(store.cloudCount, 1)
        try await bridge(store, second, namespace: "test-b").sync(enabled: [.aiKeys, .passwords], generationIsCurrent: { true })
        XCTAssertTrue(second.values.isEmpty)
        try await bridge(store, second).sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertTrue(second.values.isEmpty)
    }

    func testConcurrentEditsRemainConflictsWithoutRepeatedPublication() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("original".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values[password] = Data("first-edit".utf8)
        second.values[password] = Data("second-edit".utf8)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(b.conflicts.count, 1)
        let count = store.cloudCount
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(store.cloudCount, count)
        XCTAssertEqual(a.conflicts.count, 1)
        XCTAssertEqual(first.values[password], Data("first-edit".utf8))
        XCTAssertEqual(second.values[password], Data("second-edit".utf8))
    }

    func testAccountNamespaceQuarantinesPriorDeletionBaseline() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        local.values[password] = Data("original".utf8)
        let bridge = bridge(store, local)
        try await bridge.sync(enabled: [.passwords], generationIsCurrent: { true })
        local.values.removeValue(forKey: password)
        bridge.setAccountNamespace("different-approved-account")
        try await bridge.sync(enabled: [.passwords], generationIsCurrent: { true })
        // The prior account's acknowledged deletion must not be sent to the new one.
        XCTAssertEqual(store.cloudCount, 1)
        XCTAssertEqual(local.values[password], Data("original".utf8))
    }

    func testPrivateIdentityAndMissingEntitlementsCannotPublish() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        let unavailable = ICloudSecrets(configuration: nil, keychain: store, local: local)
        unavailable.setAccountNamespace("dedicated-account")
        do { try await unavailable.sync(enabled: [.aiKeys], generationIsCurrent: { true }); XCTFail("unprovisioned") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .unavailable) }
        XCTAssertTrue(store.queries.isEmpty)
        local.values[.password(profileID: Profile.incognito.id, origin: "https://example.com", account: "private")] = Data("private".utf8)
        do { try await bridge(store, local).sync(enabled: [.passwords], generationIsCurrent: { true }); XCTFail("private identity") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .invalidData) }
        XCTAssertEqual(store.cloudCount, 0)
    }

    func testSuccessfulLocalMutationNotificationUpdatesEnabledMirror() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        let bridge = bridge(store, local)
        let controller = try secretController(bridge, transport: SecretRefreshCloud())
        await controller.setMasterEnabled(true)
        XCTAssertNotNil(controller.lastSuccess)
        local.values[key] = Data("later-save".utf8)
        NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil)
        for _ in 0..<100 {
            if store.cloudCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cloudCount, 1)
        await controller.setMasterEnabled(false)
        local.values[key] = Data("local-only".utf8)
        NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil)
        await Task.yield()
        XCTAssertEqual(store.cloudCount, 1)
    }

    func testLocalCredentialChangeRechecksAccountBeforePublishing() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        let transport = SecretRefreshCloud()
        let bridge = bridge(store, local)
        let controller = try secretController(bridge, transport: transport)
        local.values[key] = Data("approved-account-value".utf8)
        await controller.setMasterEnabled(true)
        XCTAssertNotNil(controller.lastSuccess)
        let count = store.cloudCount
        XCTAssertEqual(count, 1)
        transport.identity = "different-account"
        local.values[key] = Data("unapproved-account-value".utf8)
        NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil)
        for _ in 0..<100 {
            if controller.needsAccountConsent || store.cloudCount > count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.needsAccountConsent, "A local secret edit must recheck the account before new Keychain submissions")
        XCTAssertFalse(controller.masterEnabled)
        XCTAssertEqual(store.cloudCount, count, "The changed account must not receive a newly admitted credential")
        XCTAssertEqual(local.values[key], Data("unapproved-account-value".utf8))
        await controller.setMasterEnabled(false)
    }

    func testAccountNotificationRevokesSecretAdmissionBeforeAnotherEdit() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        let bridge = bridge(store, local)
        let controller = try secretController(bridge, transport: SecretRefreshCloud())
        await controller.setMasterEnabled(true)
        XCTAssertNotNil(controller.lastSuccess)
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        XCTAssertFalse(controller.masterEnabled, "Account notifications must revoke admission on delivery")
        XCTAssertTrue(controller.needsAccountConsent)
        local.values[key] = Data("after-account-notification".utf8)
        NotificationCenter.default.post(name: .vaneSecretsChanged, object: nil)
        await controller.syncNow()
        XCTAssertEqual(store.cloudCount, 0)
        XCTAssertEqual(local.values[key], Data("after-account-notification".utf8))
        await controller.setMasterEnabled(false)
    }

    private func secretController(_ secrets: ICloudSecrets, transport: SecretRefreshCloud) throws -> ICloudController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "vane-secret-refresh-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        for category in ICloudCategory.allCases {
            defaults.set(category == .aiKeys, forKey: "icloud.category." + category.rawValue)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return ICloudController(directory: directory, defaults: defaults, transport: transport,
                                adapters: [], secrets: secrets, recovery: {})
    }

    func testObservedResetPausesOldMacUntilDeliberateMergeAndKeepsLocalSecrets() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("original".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await a.removeCloudData(enabled: [.passwords])
        XCTAssertEqual(store.cloudCount, 0)
        XCTAssertEqual(first.values[password], Data("original".utf8))
        second.values[password] = Data("offline-edit".utf8)
        do {
            try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
            XCTFail("reset must pause the category before an offline edit is published")
        } catch let failure as ICloudSecrets.Failure {
            XCTAssertEqual(failure, .resetRequired(.passwords))
        }
        XCTAssertEqual(b.resetObserved, [.passwords])
        XCTAssertEqual(store.cloudCount, 0)
        b.acknowledgeReset(enabled: [.passwords])
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertTrue(b.resetObserved.isEmpty)
        XCTAssertEqual(store.cloudCount, 1)
    }

    func testResetArrivingBetweenSnapshotAndPublicationRevokesPublication() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        local.values[password] = Data("original".utf8)
        store.resetAtControlRead = 2
        let bridge = bridge(store, local)
        do {
            try await bridge.sync(enabled: [.passwords], generationIsCurrent: { true })
            XCTFail("must reread the reset marker before publishing")
        } catch let failure as ICloudSecrets.Failure {
            XCTAssertEqual(failure, .resetRequired(.passwords))
        }
        XCTAssertEqual(store.cloudCount, 0)
        XCTAssertEqual(local.values[password], Data("original".utf8))
    }

    func testLocalSecretReadRechecksAdmissionAfterReferenceLookup() throws {
        var admissions = 0
        var copies = 0
        XCTAssertThrowsError(try Passwords.passwordCheckedForSync(origin: .init(host: "example.com"), account: "alice",
            profileID: ProfileManager.defaultID, admission: {
                admissions += 1
                if admissions == 2 { throw ICloudSecrets.Failure.revoked }
            }, copyMatching: { query, output in
                copies += 1
                var attributes: [String: Any] = [kSecAttrServer as String: "example.com",
                    kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
                    kSecValuePersistentRef as String: Data("fixture-ref".utf8)]
                // The injected item must belong to the process's actual test-instance
                // domain. Earlier suites may have prepared VANE_DATA_DIR already.
                if let scope = (query as NSDictionary)[kSecAttrSecurityDomain as String] as? String {
                    attributes[kSecAttrSecurityDomain as String] = scope
                }
                output?.pointee = [attributes] as CFTypeRef
                return errSecSuccess
            })) { error in
                XCTAssertEqual(error as? ICloudSecrets.Failure, .revoked)
            }
        XCTAssertEqual(copies, 1, "revocation must prevent the second query that decrypts the secret")
        XCTAssertEqual(admissions, 2, "the owned reference must reach the second admission check")
    }

    func testVerifiedReplacementAndDeletionEraseSupersededSecretBytesButKeepCausality() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        let original = Data("original-private-secret-marker".utf8)
        let updated = Data("updated-private-secret-marker".utf8)
        first.values[password] = original
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values[password] = updated
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertFalse(store.containsSecret(original), "verified replacement must erase historical password bytes")
        XCTAssertTrue(store.containsSecret(updated))
        XCTAssertEqual(store.cloudCount, 2, "causal metadata must survive secret payload cleanup")
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(second.values[password], updated)
        first.values.removeValue(forKey: password)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertFalse(store.containsSecret(original))
        XCTAssertFalse(store.containsSecret(updated), "a verified tombstone must erase the deleted secret bytes")
        XCTAssertEqual(store.cloudCount, 3)
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertNil(second.values[password])
    }

    func testConcurrentConflictPayloadsSurviveSupersededPayloadCleanup() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        let original = Data("initial-conflict-secret-marker".utf8)
        let firstEdit = Data("first-conflict-secret-marker".utf8)
        let secondEdit = Data("second-conflict-secret-marker".utf8)
        first.values[password] = original
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values[password] = firstEdit
        second.values[password] = secondEdit
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertFalse(store.containsSecret(original))
        XCTAssertTrue(store.containsSecret(firstEdit))
        XCTAssertTrue(store.containsSecret(secondEdit))
        XCTAssertEqual(a.conflicts.count, 1)
        XCTAssertEqual(b.conflicts.count, 1)
        XCTAssertEqual(store.cloudCount, 3)
    }

    func testMissingUnpropagatedPayloadRetriesWithoutDeletingLocalOriginal() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("original-local-copy".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values[password] = Data("new-remote-copy".utf8)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        // Keychain does not promise cross-item propagation order. Metadata can arrive
        // before its secret payload; a missing dependency must never mean deletion.
        store.rows.removeAll { ($0[kSecAttrService as String] as? String ?? "").hasSuffix(".payloads") }
        do {
            try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
            XCTFail("must retry when the head revision's payload has not arrived")
        } catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .verification) }
        XCTAssertEqual(second.values[password], Data("original-local-copy".utf8))
    }

    func testFirstSyncConflictCanKeepThisMacAndParentsEveryReviewedHead() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("cloud-credential".utf8)
        second.values[password] = Data("this-mac-credential".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(b.conflicts.first)
        XCTAssertEqual(review.category, .passwords)
        XCTAssertEqual(review.identity, password)
        XCTAssertEqual(review.reviewedHeadIDs, Set(review.reviewedHeads.map(\.id)))
        XCTAssertEqual(review.reviewedHeads.count, 1)
        try await b.resolve(review, choosing: .keepThisMac, generationIsCurrent: { true })
        XCTAssertTrue(b.conflicts.isEmpty)
        XCTAssertEqual(store.lastRevisionParents, review.reviewedHeadIDs)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertEqual(first.values[password], Data("this-mac-credential".utf8))
        XCTAssertFalse(store.containsSecret(Data("cloud-credential".utf8)))
    }

    func testLaterMultiHeadConflictCanUseSelectedCloudVersion() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("original".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values[password] = Data("first-edit".utf8)
        second.values[password] = Data("second-edit".utf8)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(a.conflicts.first)
        XCTAssertEqual(review.reviewedHeads.count, 2)
        let selected = try XCTUnwrap(store.payloadID(containing: Data("second-edit".utf8)))
        XCTAssertTrue(review.reviewedHeadIDs.contains(selected))
        try await a.resolve(review, choosing: .useCloudVersion(selected), generationIsCurrent: { true })
        XCTAssertEqual(first.values[password], Data("second-edit".utf8))
        XCTAssertEqual(store.lastRevisionParents, review.reviewedHeadIDs)
        XCTAssertTrue(a.conflicts.isEmpty)
        XCTAssertFalse(store.containsSecret(Data("first-edit".utf8)))
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        XCTAssertTrue(b.conflicts.isEmpty)
    }

    func testResolutionPreservesNewUnreviewedConcurrentHead() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets(), third = MemoryLocalSecrets()
        first.values[password] = Data("original".utf8)
        let a = bridge(store, first), b = bridge(store, second), c = bridge(store, third)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await c.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values[password] = Data("first-edit".utf8)
        second.values[password] = Data("second-edit".utf8)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(a.conflicts.first)
        third.values[password] = Data("unreviewed-edit".utf8)
        try await c.sync(enabled: [.passwords], generationIsCurrent: { true })
        let unreviewed = try XCTUnwrap(store.payloadID(containing: Data("unreviewed-edit".utf8)))
        try await a.resolve(review, choosing: .keepThisMac, generationIsCurrent: { true })
        XCTAssertEqual(store.lastRevisionParents, review.reviewedHeadIDs)
        XCTAssertFalse(store.lastRevisionParents.contains(unreviewed))
        XCTAssertTrue(store.containsSecret(Data("unreviewed-edit".utf8)))
        XCTAssertEqual(a.conflicts.count, 1)
        XCTAssertTrue(a.conflicts[0].reviewedHeadIDs.contains(unreviewed))
        XCTAssertEqual(first.values[password], Data("first-edit".utf8))
    }

    func testStaleLocalReviewMustRefreshBeforeKeepingManualEdit() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("cloud".utf8)
        second.values[password] = Data("local".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(b.conflicts.first)
        second.values[password] = Data("manual-edit".utf8)
        let count = store.cloudCount
        do { try await b.resolve(review, choosing: .keepThisMac, generationIsCurrent: { true }); XCTFail("stale local review") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .staleReview) }
        XCTAssertEqual(store.cloudCount, count)
        XCTAssertEqual(second.values[password], Data("manual-edit".utf8))
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let refreshed = try XCTUnwrap(b.conflicts.first)
        XCTAssertNotEqual(refreshed.id, review.id)
        try await b.resolve(refreshed, choosing: .keepThisMac, generationIsCurrent: { true })
        XCTAssertTrue(b.conflicts.isEmpty)
    }

    func testAccountRevocationDuringResolutionPreventsPublicationAndLocalOverride() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("cloud".utf8)
        second.values[password] = Data("local".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(b.conflicts.first)
        let selected = try XCTUnwrap(review.reviewedHeads.first?.id)
        let current = RevocationFlag()
        store.onRead = { current.revoke() }
        let count = store.cloudCount
        do { try await b.resolve(review, choosing: .useCloudVersion(selected), generationIsCurrent: { current.valid }); XCTFail("revoked resolution") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .revoked) }
        XCTAssertEqual(store.cloudCount, count)
        XCTAssertEqual(second.values[password], Data("local".utf8))
    }

    func testSelectedCloudDeletionResolvesConcurrentLocalEdit() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("original".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        first.values.removeValue(forKey: password)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        second.values[password] = Data("offline-edit".utf8)
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(b.conflicts.first)
        let deletion = try XCTUnwrap(review.reviewedHeads.first { $0.isDeletion })
        try await b.resolve(review, choosing: .useCloudVersion(deletion.id), generationIsCurrent: { true })
        XCTAssertNil(second.values[password])
        XCTAssertTrue(b.conflicts.isEmpty)
        XCTAssertEqual(store.lastRevisionParents, review.reviewedHeadIDs)
        XCTAssertFalse(store.containsSecret(Data("offline-edit".utf8)))
    }

    func testAccountAndCategoryChangesInvalidateConflictReview() async throws {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("cloud".utf8)
        second.values[password] = Data("local".utf8)
        let a = bridge(store, first), b = bridge(store, second)
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(b.conflicts.first)
        b.pause()
        do { try await b.resolve(review, choosing: .keepThisMac, generationIsCurrent: { true }); XCTFail("disabled category") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .revoked) }
        b.setAccountNamespace("different-account")
        do { try await b.resolve(review, choosing: .keepThisMac, generationIsCurrent: { true }); XCTFail("different account") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .staleReview) }
        XCTAssertEqual(second.values[password], Data("local".utf8))
    }

    private func inspectionConflict(authorizer: @escaping @MainActor (String) async -> Bool) async throws -> (MemorySecretKeychain, MemoryLocalSecrets, ICloudSecrets, ICloudSecrets.Conflict, UUID) {
        let store = MemorySecretKeychain(), first = MemoryLocalSecrets(), second = MemoryLocalSecrets()
        first.values[password] = Data("cloud-inspection-value".utf8)
        second.values[password] = Data("this-mac-inspection-value".utf8)
        let a = bridge(store, first)
        let b = ICloudSecrets(configuration: .init(accessGroup: "TEAM.io.vane", namespace: "test-a", localDeviceID: second.deviceID),
                             keychain: store, local: second, authorizer: authorizer)
        b.setAccountNamespace("dedicated-account")
        try await a.sync(enabled: [.passwords], generationIsCurrent: { true })
        try await b.sync(enabled: [.passwords], generationIsCurrent: { true })
        let review = try XCTUnwrap(b.conflicts.first)
        return (store, second, b, review, try XCTUnwrap(review.reviewedHeads.first?.id))
    }

    func testDeniedInspectionDoesNotReadCloudPayload() async throws {
        var authorizations = 0
        let (store, local, bridge, review, selected) = try await inspectionConflict { _ in authorizations += 1; return false }
        let reads = store.payloadReadCount, count = store.cloudCount
        do { _ = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { true }); XCTFail("denied inspection") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .authenticationDenied) }
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(store.payloadReadCount, reads)
        XCTAssertEqual(store.cloudCount, count)
        XCTAssertEqual(local.values[password], Data("this-mac-inspection-value".utf8))
    }

    func testAuthenticatedInspectionReturnsOnlyExactSelectedValueWithoutMutations() async throws {
        let (store, local, bridge, review, selected) = try await inspectionConflict { _ in true }
        let count = store.cloudCount
        let inspected = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { true })
        XCTAssertEqual(inspected, .credential(value: "cloud-inspection-value", matchesThisMac: false))
        XCTAssertEqual(store.cloudCount, count)
        XCTAssertEqual(bridge.conflicts, [review])
        XCTAssertEqual(local.values[password], Data("this-mac-inspection-value".utf8))
    }

    func testInspectionRevokedAfterAuthenticationNeverReadsPayload() async throws {
        let current = RevocationFlag()
        let (store, _, bridge, review, selected) = try await inspectionConflict { _ in current.revoke(); return true }
        let reads = store.payloadReadCount
        do { _ = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { current.valid }); XCTFail("revoked inspection") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .revoked) }
        XCTAssertEqual(store.payloadReadCount, reads)
    }

    func testInspectionRechecksAccountAfterAuthentication() async throws {
        weak var target: ICloudSecrets?
        let (store, _, bridge, review, selected) = try await inspectionConflict { _ in
            target?.setAccountNamespace("different-account")
            return true
        }
        target = bridge
        let reads = store.payloadReadCount
        do { _ = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { true }); XCTFail("stale account") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .staleReview) }
        XCTAssertEqual(store.payloadReadCount, reads)
    }

    func testInspectionRechecksLocalExpectedValueAfterAuthentication() async throws {
        weak var target: MemoryLocalSecrets?
        let identity = password
        let (store, local, bridge, review, selected) = try await inspectionConflict { _ in
            target?.values[identity] = Data("manual-edit-during-authentication".utf8)
            return true
        }
        target = local
        let reads = store.payloadReadCount
        do { _ = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { true }); XCTFail("stale local value") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .staleReview) }
        XCTAssertEqual(store.payloadReadCount, reads)
        XCTAssertEqual(local.values[password], Data("manual-edit-during-authentication".utf8))
    }

    func testInspectionRevokedDuringPayloadReadNeverReturnsSecret() async throws {
        let current = RevocationFlag()
        let (store, local, bridge, review, selected) = try await inspectionConflict { _ in true }
        store.onPayloadRead = { current.revoke() }
        do { _ = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { current.valid }); XCTFail("revoked result must be discarded") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .revoked) }
        XCTAssertEqual(local.values[password], Data("this-mac-inspection-value".utf8))
    }

    func testMissingInspectionPayloadPreservesEveryVersionAndLocalOriginal() async throws {
        let (store, local, bridge, review, selected) = try await inspectionConflict { _ in true }
        store.rows.removeAll { ($0[kSecAttrService as String] as? String ?? "").hasSuffix(".payloads")
            && $0[kSecAttrAccount as String] as? String == selected.uuidString }
        let count = store.cloudCount
        do { _ = try await bridge.inspectReviewedVersion(review, versionID: selected, generationIsCurrent: { true }); XCTFail("missing payload") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .verification) }
        XCTAssertEqual(store.cloudCount, count)
        XCTAssertEqual(bridge.conflicts, [review])
        XCTAssertEqual(local.values[password], Data("this-mac-inspection-value".utf8))
    }

    func testUnavailableOrUnverifiedKeychainPreservesLocalOriginal() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        local.values[password] = Data("original".utf8)
        let bridge = bridge(store, local)
        store.failure = errSecInteractionNotAllowed
        do { try await bridge.sync(enabled: [.passwords], generationIsCurrent: { true }); XCTFail("must report locked Keychain") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .keychain(errSecInteractionNotAllowed)) }
        store.failure = nil
        store.hideAddedRecords = true
        do { try await bridge.sync(enabled: [.passwords], generationIsCurrent: { true }); XCTFail("must verify readback") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .verification) }
        XCTAssertEqual(local.values[password], Data("original".utf8))
    }

    func testAccountRevokedAfterReadCannotPublishAndRemovalIsExplicitAndScoped() async throws {
        let store = MemorySecretKeychain(), local = MemoryLocalSecrets()
        local.values[password] = Data("original".utf8)
        local.values[key] = Data("api-key".utf8)
        let bridge = bridge(store, local)
        let current = RevocationFlag()
        store.onRead = { current.revoke() }
        do { try await bridge.sync(enabled: [.passwords], generationIsCurrent: { current.valid }); XCTFail("stale admission") }
        catch let failure as ICloudSecrets.Failure { XCTAssertEqual(failure, .revoked) }
        XCTAssertEqual(store.cloudCount, 0)
        store.onRead = nil
        try await bridge.sync(enabled: [.passwords, .aiKeys], generationIsCurrent: { true })
        bridge.pause()
        let reads = store.queries.count
        try await bridge.sync(enabled: [], generationIsCurrent: { true })
        XCTAssertEqual(store.queries.count, reads)
        try await bridge.removeCloudData(enabled: [.passwords])
        XCTAssertEqual(store.cloudCount, 1)
        XCTAssertEqual(local.values.count, 2)
    }
}

@MainActor private final class SecretRefreshCloud: ICloudTransport {
    var identity = "dedicated-account"
    func account() async throws -> String { identity }
    func exchange(pending: [ICloudRecord], enabled: Set<ICloudCategory>, state: Data?, epochs: [ICloudCategory: String],
                  persistState: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudExchange {
        ICloudExchange(received: [], acknowledged: pending, state: nil)
    }
    func remove(_ categories: Set<ICloudCategory>) async throws {}
}

private final class MemorySecretKeychain: ICloudSecretsKeychain, @unchecked Sendable {
    var rows: [[String: Any]] = []
    var queries: [[String: Any]] = []
    var additions: [[String: Any]] = []
    var failure: OSStatus?
    var hideAddedRecords = false
    var onRead: (@Sendable () -> Void)?
    var onPayloadRead: (@Sendable () -> Void)?
    var payloadReadCount: Int { queries.filter { ($0[kSecAttrService as String] as? String ?? "").hasSuffix(".payloads") }.count }
    var resetAtControlRead: Int?
    private var controlReads = 0
    var cloudCount: Int {
        rows.filter { $0[kSecAttrSynchronizable as String] as? Bool == true
            && ($0[kSecAttrService as String] as? String ?? "").hasSuffix(".revisions") }.count
    }
    func containsSecret(_ secret: Data) -> Bool {
        let encoded = Data(secret.base64EncodedString().utf8)
        return rows.contains { row in
            guard row[kSecAttrSynchronizable as String] as? Bool == true,
                  let data = row[kSecValueData as String] as? Data else { return false }
            return data.range(of: secret) != nil || data.range(of: encoded) != nil
        }
    }
    func payloadID(containing value: Data) -> UUID? {
        guard let row = rows.first(where: { ($0[kSecAttrService as String] as? String ?? "").hasSuffix(".payloads")
            && $0[kSecValueData as String] as? Data == value }), let account = row[kSecAttrAccount as String] as? String else { return nil }
        return UUID(uuidString: account)
    }
    var lastRevisionParents: Set<UUID> {
        guard let row = additions.last(where: { ($0[kSecAttrService as String] as? String ?? "").hasSuffix(".revisions") }),
              let data = row[kSecValueData as String] as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parents = object["parents"] as? [String] else { return [] }
        return Set(parents.compactMap(UUID.init(uuidString:)))
    }
    private func matches(_ row: [String: Any], _ query: [String: Any]) -> Bool {
        for key in [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup, kSecAttrSynchronizable, kSecAttrGeneric] {
            guard let wanted = query[key as String] as? NSObject else { continue }
            guard let actual = row[key as String] as? NSObject, actual == wanted else { return false }
        }
        return true
    }
    func read(_ query: [String: Any]) throws -> [Data] {
        queries.append(query)
        if let failure { throw ICloudSecrets.Failure.keychain(failure) }
        onRead?()
        if (query[kSecAttrService as String] as? String ?? "").hasSuffix(".payloads") { onPayloadRead?() }
        if (query[kSecAttrService as String] as? String ?? "").hasSuffix(".reset-control") {
            controlReads += 1
            if resetAtControlRead == controlReads {
                let id = UUID().uuidString
                let marker = try JSONSerialization.data(withJSONObject: ["schema": 1, "id": id])
                rows.append(query.merging([kSecAttrAccount as String: id, kSecValueData as String: marker]) { _, new in new })
            }
        }
        return hideAddedRecords ? [] : rows.filter { matches($0, query) }.compactMap { $0[kSecValueData as String] as? Data }
    }
    func add(_ attributes: [String: Any]) throws {
        additions.append(attributes)
        rows.append(attributes)
    }
    func replace(_ query: [String: Any], data: Data) throws {
        rows.removeAll { matches($0, query) }
        rows.append(query.merging([kSecValueData as String: data]) { _, new in new })
    }
    func remove(_ query: [String: Any]) throws { rows.removeAll { matches($0, query) } }
}

private final class RevocationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var valid: Bool { lock.withLock { value } }
    func revoke() { lock.withLock { value = false } }
}

@MainActor private final class MemoryLocalSecrets: ICloudSecretsLocalStore {
    let deviceID = UUID().uuidString
    var values: [ICloudSecrets.Identity: Data] = [:]
    func snapshot(kind: ICloudSecrets.Kind, admission: @escaping @Sendable () throws -> Void) async throws -> [ICloudSecrets.Identity: Data] {
        try admission()
        return values.filter { $0.key.kind == kind }
    }
    func apply(_ identity: ICloudSecrets.Identity, value: Data?, expected: Data?, admission: @escaping @Sendable () throws -> Void) async throws -> Bool {
        try admission()
        guard values[identity] == expected else { return false }
        values[identity] = value
        return true
    }
}
