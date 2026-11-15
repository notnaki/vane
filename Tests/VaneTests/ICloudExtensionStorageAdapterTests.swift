import Foundation
import XCTest
@testable import vane

@MainActor final class ICloudExtensionStorageAdapterTests: XCTestCase {
    @MainActor private final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !entered {
                guard ContinuousClock.now < deadline else { throw ICloudFailure.unavailable("Held storage read did not start") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    /// A deterministic native namespace owner; it stores actual JSON values and
    /// checks expected values at mutation admission, independently of cache logic.
    private final class Session: ICloudExtensionStorageSession {
        var values: [String: Data] = [:]
        var valid = true
        var beforeRead: (@MainActor () async throws -> Void)?
        var failRead = false
        var mutationCount = 0
        var closed = false
        func check() throws {
            try ICloudApplyContext.check()
            guard valid else { throw CancellationError() }
        }
        func read() async throws -> [String: Data] {
            try check()
            if let beforeRead { try await beforeRead() }
            try check()
            if failRead { throw ICloudFailure.unavailable("Synthetic bounded read timeout") }
            return values
        }
        func apply(_ mutations: [ICloudExtensionStorageMutation]) async throws -> [String: Data] {
            try check()
            for mutation in mutations {
                try check()
                if let desired = mutation.value {
                    switch mutation.expected {
                    case .unknown: break
                    case .absent: if values[mutation.key] != nil && values[mutation.key] != desired { continue }
                    case .value(let expected): if values[mutation.key] != expected && values[mutation.key] != desired { continue }
                    }
                    values[mutation.key] = desired
                } else { values.removeValue(forKey: mutation.key) }
                mutationCount += 1
            }
            return values
        }
        func close() { closed = true }
    }

    @MainActor private final class Owner {
        var profiles: [UUID]
        var installations: [ICloudExtensionInstallation] = []
        var active: [ICloudExtensionNamespace: Session] = [:]
        var ensureCalls: [UUID] = []
        var retired = Set<UUID>()
        init(_ profile: UUID) { profiles = [profile] }
        func ensure(_ profile: UUID) throws {
            guard profile != Profile.incognito.id, !retired.contains(profile) else { throw CancellationError() }
            ensureCalls.append(profile)
            if !profiles.contains(profile) { profiles.append(profile) }
        }
        func adapter(_ directory: URL) async throws -> ICloudExtensionStorageAdapter {
            let adapter = ICloudExtensionStorageAdapter(directory: directory, profileIDs: { self.profiles },
                ensureProfile: { try self.ensure($0) }, installed: { self.installations },
                open: { self.active[$0.namespace] })
            try await adapter.bindAccount("test-account")
            return adapter
        }
        func install(_ namespace: ICloudExtensionNamespace, active: Session? = nil) {
            installations.append(ICloudExtensionInstallation(namespace: namespace, installationID: UUID().uuidString.lowercased()))
            if let active { self.active[namespace] = active }
        }
    }

    private func fixture(_ body: @MainActor (URL, UUID, Owner) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-extension-storage-\(UUID())")
        let profile = UUID(), owner = Owner(UUID())
        owner.profiles = [profile]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root, profile, owner)
    }
    private func json(_ value: String) throws -> Data { try JSONEncoder().encode(value) }
    private func namespace(_ profile: UUID) -> ICloudExtensionNamespace {
        ICloudExtensionNamespace(profileID: profile, extensionID: UUID().uuidString.lowercased())
    }
    private func item(_ namespace: ICloudExtensionNamespace, _ key: String, _ value: String) throws -> ICloudItem {
        try ICloudExtensionStorageAdapter.item(namespace: namespace, key: key, value: json(value))
    }

    func testRebindQuarantinesPendingValuesAndCapturesOnlyCurrentNativeStorage() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), adapter = try await owner.adapter(root)
            try await adapter.apply([item(ns, "old-cloud-only", "secret")], deleted: [], enabled: [.extensionSyncData])
            let cacheFile = root.appendingPathComponent("icloud-extension-storage.json")
            let oldCache = try Data(contentsOf: cacheFile)
            let session = Session()
            session.values = ["native": try json("current")]
            owner.install(ns, active: session)
            try await adapter.bindAccount("new-account")
            let captured = try await adapter.capture([.extensionSyncData])
            XCTAssertEqual(captured, [try item(ns, "native", "current")])
            XCTAssertEqual(adapter.pendingExtensionCount, 0)
            XCTAssertEqual(session.mutationCount, 0)
            let archives = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("icloud-extension-storage-account-") }
            XCTAssertEqual(archives.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), oldCache)
        }
    }

    func testLegacyUnboundCacheIsQuarantinedBeforeCapture() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), adapter = try await owner.adapter(root)
            try await adapter.apply([item(ns, "old-cloud-only", "secret")], deleted: [], enabled: [.extensionSyncData])
            let file = root.appendingPathComponent("icloud-extension-storage.json")
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            legacy.removeValue(forKey: "accountID")
            try JSONSerialization.data(withJSONObject: legacy).write(to: file)
            let restarted = try await owner.adapter(root)
            let captured = try await restarted.capture([.extensionSyncData])
            XCTAssertTrue(captured.isEmpty)
            XCTAssertEqual(restarted.pendingExtensionCount, 0)
        }
    }

    func testUnboundAdapterCannotCaptureOrApplyStorage() async throws {
        try await fixture { root, profile, _ in
            let adapter = ICloudExtensionStorageAdapter(directory: root, profileIDs: { [profile] },
                installed: { [] }, open: { _ in nil })
            do { _ = try await adapter.capture([.extensionSyncData]); XCTFail("Unbound capture accepted") }
            catch ICloudFailure.accountChanged { }
            do { try await adapter.apply([], deleted: [], enabled: [.extensionSyncData]); XCTFail("Unbound apply accepted") }
            catch ICloudFailure.accountChanged { }
        }
    }

    func testInactivePendingNamespaceSurvivesRestartAndDoesNotBecomeDeletion() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile)
            let incoming = try item(ns, "theme", "remote")
            let first = try await owner.adapter(root)
            try await first.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            XCTAssertEqual(first.pendingExtensionCount, 1)
            let restarted = try await owner.adapter(root)
            let retained = try await restarted.capture([.extensionSyncData])
            XCTAssertEqual(retained, [incoming])
            XCTAssertEqual(restarted.pendingExtensionCount, 1)
            XCTAssertTrue(owner.active.isEmpty, "Receiving data must not load an extension")
        }
    }

    func testFirstApprovedActivationAppliesRemoteOverDefaultsAndPreservesUnrelatedKeys() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), adapter = try await owner.adapter(root)
            let incoming = try item(ns, "theme", "remote")
            try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            let session = Session()
            session.values = ["theme": try json("vendor-default"), "localOnlySetting": try json("retain")]
            owner.install(ns, active: session)
            // Capture must not turn first-activation defaults into edits before the
            // durably staged cloud snapshot has had its first admitted apply.
            let beforeActivation = try await adapter.capture([.extensionSyncData])
            XCTAssertEqual(beforeActivation, [incoming])
            try await adapter.apply([], deleted: [], enabled: [.extensionSyncData])
            XCTAssertEqual(session.values["theme"], try json("remote"))
            XCTAssertEqual(session.values["localOnlySetting"], try json("retain"))
            XCTAssertEqual(adapter.pendingExtensionCount, 0)
        }
    }

    func testPriorNativeBaselinePreservesLocalEditsAcrossRestart() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), session = Session()
            session.values = ["theme": try json("baseline")]
            owner.install(ns, active: session)
            let first = try await owner.adapter(root)
            _ = try await first.capture([.extensionSyncData])
            session.values["theme"] = try json("late-local")
            let restarted = try await owner.adapter(root)
            try await restarted.apply([item(ns, "theme", "remote")], deleted: [], enabled: [.extensionSyncData])
            XCTAssertEqual(session.values["theme"], try json("late-local"))
            let exported = try await restarted.capture([.extensionSyncData])
            XCTAssertEqual(exported, [try item(ns, "theme", "late-local")])
        }
    }

    func testAdmissionRevocationDuringHeldReadRetainsPendingWithoutMutation() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), session = Session(), gate = Gate(), admission = ICloudAdmission()
            owner.install(ns, active: session)
            session.beforeRead = { await gate.hold() }
            let adapter = try await owner.adapter(root), incoming = try item(ns, "theme", "remote")
            let task = Task { @MainActor in
                try await ICloudApplyContext.$admission.withValue(admission) {
                    try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData])
                }
            }
            defer { gate.open() }
            try await gate.wait()
            admission.revoke(); gate.open()
            do { try await task.value; XCTFail("A revoked callback cannot enqueue storage mutation") } catch { }
            XCTAssertTrue(session.values.isEmpty)
            XCTAssertEqual(session.mutationCount, 0)
            owner.active = [:]
            let retained = try await owner.adapter(root).capture([.extensionSyncData])
            XCTAssertEqual(retained, [incoming])
        }
    }

    func testExtensionRevisionRevocationDuringHeldReadPreventsCommit() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), session = Session(), gate = Gate()
            owner.install(ns, active: session)
            session.beforeRead = { await gate.hold() }
            let adapter = try await owner.adapter(root), incoming = try item(ns, "theme", "remote")
            let task = Task { @MainActor in try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData]) }
            defer { gate.open() }
            try await gate.wait(); session.valid = false; gate.open()
            do { try await task.value; XCTFail("A replaced runtime cannot receive stale sync data") } catch { }
            XCTAssertEqual(session.mutationCount, 0)
            XCTAssertTrue(session.values.isEmpty)
        }
    }

    func testObservedUninstallRetiresCacheButUnknownInactiveNamespaceRemainsPending() async throws {
        try await fixture { root, profile, owner in
            let removed = namespace(profile), unknown = namespace(profile), session = Session()
            session.values = ["theme": try json("old")]
            owner.install(removed, active: session)
            let adapter = try await owner.adapter(root)
            _ = try await adapter.capture([.extensionSyncData])
            let staged = try item(unknown, "theme", "other-mac")
            try await adapter.apply([staged], deleted: [], enabled: [.extensionSyncData])
            owner.installations = []; owner.active = [:]
            let afterRemoval = try await adapter.capture([.extensionSyncData])
            XCTAssertEqual(afterRemoval, [staged])
            try await adapter.apply([item(removed, "theme", "stale")], deleted: [], enabled: [.extensionSyncData])
            let afterStale = try await adapter.capture([.extensionSyncData])
            XCTAssertEqual(afterStale, [staged], "An old incoming record must not resurrect an observed uninstall")
        }
    }

    func testSameExtensionKeyIsIsolatedAcrossProfilesAndTombstoneRemovesOnlyItsKey() async throws {
        try await fixture { root, profile, owner in
            let other = UUID(), ext = UUID().uuidString.lowercased()
            owner.profiles.append(other)
            let first = ICloudExtensionNamespace(profileID: profile, extensionID: ext)
            let second = ICloudExtensionNamespace(profileID: other, extensionID: ext)
            let a = Session(), b = Session()
            a.values = ["remove": try json("a"), "keep": try json("untouched")]
            b.values = ["remove": try json("b")]
            owner.install(first, active: a); owner.install(second, active: b)
            let adapter = try await owner.adapter(root)
            _ = try await adapter.capture([.extensionSyncData])
            try await adapter.apply([], deleted: [item(first, "remove", "a")], enabled: [.extensionSyncData])
            XCTAssertNil(a.values["remove"])
            XCTAssertEqual(a.values["keep"], try json("untouched"))
            XCTAssertEqual(b.values["remove"], try json("b"))
        }
    }

    func testTombstoneForUnknownProfileDoesNotCreateParentOrPendingNamespace() async throws {
        try await fixture { root, profile, owner in
            let missing = namespace(UUID()), adapter = try await owner.adapter(root)
            try await adapter.apply([], deleted: [item(missing, "theme", "deleted")], enabled: [.extensionSyncData])
            XCTAssertEqual(owner.profiles, [profile], "A deletion received on a new Mac must not recreate its deleted parent")
            XCTAssertTrue(owner.ensureCalls.isEmpty)
            XCTAssertEqual(adapter.pendingExtensionCount, 0)
            let retained = try await owner.adapter(root).capture([.extensionSyncData])
            XCTAssertTrue(retained.isEmpty)
        }
    }

    func testLiveIncomingDataStillCreatesOpaqueParentBeforeStaging() async throws {
        try await fixture { root, profile, owner in
            let missing = namespace(UUID()), adapter = try await owner.adapter(root)
            let incoming = try item(missing, "theme", "remote")
            try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            XCTAssertEqual(Set(owner.profiles), [profile, missing.profileID])
            XCTAssertEqual(owner.ensureCalls, [missing.profileID])
            XCTAssertEqual(adapter.pendingExtensionCount, 1)
            let retained = try await owner.adapter(root).capture([.extensionSyncData])
            XCTAssertEqual(retained, [incoming])
        }
    }

    func testProfileRetirementPersistsAndNeverRecreatesPendingProfile() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), incoming = try item(ns, "theme", "remote")
            let adapter = try await owner.adapter(root)
            try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            owner.profiles = []; owner.retired.insert(profile)
            let afterRetirement = try await adapter.capture([.extensionSyncData])
            XCTAssertTrue(afterRetirement.isEmpty)
            let restarted = try await owner.adapter(root)
            try await restarted.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            let afterRestart = try await restarted.capture([.extensionSyncData])
            XCTAssertTrue(afterRestart.isEmpty)
            XCTAssertTrue(owner.profiles.isEmpty)
            XCTAssertTrue(owner.ensureCalls.isEmpty)
        }
    }

    func testFailedNativeReadKeepsPendingAndReportsError() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), session = Session()
            let incoming = try item(ns, "theme", "pending")
            let adapter = try await owner.adapter(root)
            try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            owner.install(ns, active: session)
            session.failRead = true
            do { try await adapter.apply([], deleted: [], enabled: [.extensionSyncData]); XCTFail("A failed pending namespace cannot report a successful apply") } catch { }
            owner.active = [:]
            let retained = try await owner.adapter(root).capture([.extensionSyncData])
            XCTAssertEqual(retained, [incoming])
        }
    }

    func testUnreadablePriorNativeCacheIsNotReplacedByUnknownBaseline() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), session = Session()
            session.values = ["theme": try json("native")]
            owner.install(ns, active: session)
            _ = try await owner.adapter(root).capture([.extensionSyncData])
            try Data("damaged prior baseline".utf8).write(to: root.appendingPathComponent("icloud-extension-storage.json"))
            do {
                try await owner.adapter(root).apply([item(ns, "theme", "remote")], deleted: [], enabled: [.extensionSyncData])
                XCTFail("An unreadable known baseline must remain an error")
            } catch { }
            XCTAssertEqual(session.values["theme"], try json("native"))
            XCTAssertEqual(session.mutationCount, 0)
        }
    }

    func testOversizeOrPrivateInputNeverCreatesParentsOrWritesStorage() async throws {
        try await fixture { root, profile, owner in
            owner.profiles = []
            let adapter = try await owner.adapter(root), ns = namespace(profile)
            do { _ = try ICloudExtensionStorageAdapter.item(namespace: ns, key: "large", value: json(String(repeating: "x", count: 8193))); XCTFail("Per-key JSON limit must be enforced") } catch { }
            let privateNS = ICloudExtensionNamespace(profileID: Profile.incognito.id, extensionID: ns.extensionID)
            do {
                let value = try item(privateNS, "theme", "private")
                try await adapter.apply([value], deleted: [], enabled: [.extensionSyncData])
            } catch { }
            XCTAssertTrue(owner.ensureCalls.isEmpty)
            XCTAssertTrue(owner.installations.isEmpty)
        }
    }
}
