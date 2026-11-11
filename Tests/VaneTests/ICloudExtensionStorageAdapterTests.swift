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
        func adapter(_ directory: URL) -> ICloudExtensionStorageAdapter {
            ICloudExtensionStorageAdapter(directory: directory, profileIDs: { self.profiles },
                ensureProfile: { try self.ensure($0) }, installed: { self.installations },
                open: { self.active[$0.namespace] })
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

    func testInactivePendingNamespaceSurvivesRestartAndDoesNotBecomeDeletion() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile)
            let incoming = try item(ns, "theme", "remote")
            let first = owner.adapter(root)
            try await first.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            XCTAssertEqual(first.pendingExtensionCount, 1)
            let restarted = owner.adapter(root)
            let retained = try await restarted.capture([.extensionSyncData])
            XCTAssertEqual(retained, [incoming])
            XCTAssertEqual(restarted.pendingExtensionCount, 1)
            XCTAssertTrue(owner.active.isEmpty, "Receiving data must not load an extension")
        }
    }

    func testFirstApprovedActivationAppliesRemoteOverDefaultsAndPreservesUnrelatedKeys() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), adapter = owner.adapter(root)
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
            let first = owner.adapter(root)
            _ = try await first.capture([.extensionSyncData])
            session.values["theme"] = try json("late-local")
            let restarted = owner.adapter(root)
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
            let adapter = owner.adapter(root), incoming = try item(ns, "theme", "remote")
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
            let adapter = owner.adapter(root), incoming = try item(ns, "theme", "remote")
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
            let adapter = owner.adapter(root)
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
            let adapter = owner.adapter(root)
            _ = try await adapter.capture([.extensionSyncData])
            try await adapter.apply([], deleted: [item(first, "remove", "a")], enabled: [.extensionSyncData])
            XCTAssertNil(a.values["remove"])
            XCTAssertEqual(a.values["keep"], try json("untouched"))
            XCTAssertEqual(b.values["remove"], try json("b"))
        }
    }

    func testProfileRetirementPersistsAndNeverRecreatesPendingProfile() async throws {
        try await fixture { root, profile, owner in
            let ns = namespace(profile), incoming = try item(ns, "theme", "remote")
            let adapter = owner.adapter(root)
            try await adapter.apply([incoming], deleted: [], enabled: [.extensionSyncData])
            owner.profiles = []; owner.retired.insert(profile)
            let afterRetirement = try await adapter.capture([.extensionSyncData])
            XCTAssertTrue(afterRetirement.isEmpty)
            let restarted = owner.adapter(root)
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
            let adapter = owner.adapter(root)
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
            let adapter = owner.adapter(root), ns = namespace(profile)
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
