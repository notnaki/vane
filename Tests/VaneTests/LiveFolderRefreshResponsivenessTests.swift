import XCTest
@testable import vane

private final class LiveRefreshReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read() -> Passwords.CredentialRead {
        lock.withLock { count += 1 }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return .unavailable(-25308) }
        return .found(account: "fixture", password: "old-fixture")
    }
    func release() { semaphore.signal() }
}

private actor LiveRefreshReadSequence {
    var reads = 0
    func read() -> Passwords.CredentialRead {
        reads += 1
        switch reads {
        case 1: return .missing
        case 2: return .unavailable(-25308)
        default: return .found(account: "fixture", password: "new-fixture")
        }
    }
}

private actor LiveRefreshEpochGate {
    var reads = 0
    private var first: CheckedContinuation<Passwords.CredentialRead, Never>?
    func read() async -> Passwords.CredentialRead {
        reads += 1
        if reads > 1 { return .missing }
        return await withCheckedContinuation { first = $0 }
    }
    func release() {
        first?.resume(returning: .found(account: "fixture", password: "old-fixture"))
        first = nil
    }
}

@MainActor private final class LiveRefreshResponseGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor final class LiveFolderRefreshResponsivenessTests: XCTestCase {
    private func fixture() -> (TabStore, Folder) {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Credential responsiveness")
        let store = TabStore(profileID: profile.id, session: [])
        store.sharingReady = false
        let folder = Folder(name: "Live", live: .github(GitHubQuery()))
        store.pins = Pins(entries: [.init(row: .folder(folder))])
        addTeardownBlock { @MainActor in
            SharedTabs.release(store.everyTab, excluding: store)
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            Store.forget(profile.id)
            ProfileManager.shared.delete(profile.id)
        }
        return (store, folder)
    }

    func testBlockedCredentialLaneLeavesFocusResponsiveAndCoalescesRefreshes() async throws {
        let (store, folder) = fixture()
        let gate = LiveRefreshReadGate()
        let response = LiveRefreshResponseGate()
        defer { gate.release(); response.release() }
        var fetches = 0
        let live = LiveFolders(profileID: store.profileID,
            readCredential: { XCTFail("Automatic refresh must not use the synchronous reader"); return .missing },
            readCredentialAsync: { (try? await Passwords.perform { gate.read() }) ?? .unavailable(-25308) },
            fetchPullRequests: { _, _ in
                fetches += 1
                if fetches == 1 { await response.wait() }
                return .success([])
            })
        let began = ContinuousClock.now
        live.refreshAll()
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(250))
        try await compatibilityWait { gate.reads == 1 }
        for _ in 0..<4 { live.refreshAll() }
        live.expanded(folder.id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(gate.reads, 1)
        XCTAssertEqual(fetches, 0, "The main actor can run while Keychain is held")
        gate.release()
        try await compatibilityWait { fetches == 1 }
        XCTAssertNil(live.rows[folder.id], "Entering the fetch callback is not refresh completion")
        response.release()
        // Refresh Now bypasses the rate floor, not an in-flight request. Admit
        // the applied response before checking either trigger's idle behavior.
        try await compatibilityWait { live.rows[folder.id] != nil }
        XCTAssertEqual(live.rows[folder.id]?.count, 0)
        XCTAssertEqual(live.signIn?.login, "fixture")
        live.refreshAll()
        XCTAssertEqual(fetches, 1, "Ordinary refresh keeps its rate floor")
        live.refreshNow(folder.id)
        try await compatibilityWait { fetches == 2 }
        XCTAssertEqual(gate.reads, 1, "Force refresh reuses the admitted credential")
    }

    func testMissingAndUnavailableReadsRetryButSuccessfulReadIsCached() async throws {
        let (store, _) = fixture()
        let sequence = LiveRefreshReadSequence()
        let live = LiveFolders(profileID: store.profileID,
            readCredentialAsync: { await sequence.read() })
        let missing = try await live.signInAsync()
        let unavailable = try await live.signInAsync()
        let recovered = try await live.signInAsync()
        let cached = try await live.signInAsync()
        XCTAssertNil(missing)
        XCTAssertNil(unavailable)
        XCTAssertEqual(recovered?.token, "new-fixture")
        XCTAssertEqual(cached?.token, "new-fixture")
        let reads = await sequence.reads
        XCTAssertEqual(reads, 3)
    }

    func testSignOutWhileColdReadWaitsCannotRestoreTheOldCredential() async throws {
        let (store, _) = fixture()
        let gate = LiveRefreshReadGate()
        defer { gate.release() }
        var signedOut = false
        let live = LiveFolders(profileID: store.profileID,
            readCredential: { signedOut ? .missing : .found(account: "fixture", password: "old-fixture") },
            readCredentialAsync: { (try? await Passwords.perform { gate.read() }) ?? .unavailable(-25308) },
            deleteCredential: { _ in signedOut = true; return true })
        let pending = Task { try await live.signInAsync() }
        try await compatibilityWait { gate.reads == 1 }
        live.signOut()
        gate.release()
        do { _ = try await pending.value; XCTFail("A signed-out epoch must discard its cold read") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(signedOut)
        XCTAssertNil(live.signIn)
    }

    func testReplacementWhileColdReadWaitsKeepsTheNewCredential() async throws {
        let (store, _) = fixture()
        let gate = LiveRefreshReadGate()
        defer { gate.release() }
        let live = LiveFolders(profileID: store.profileID,
            readCredential: { .missing },
            readCredentialAsync: { (try? await Passwords.perform { gate.read() }) ?? .unavailable(-25308) },
            storeCredential: { _, _ in true })
        let pending = Task { try await live.signInAsync() }
        try await compatibilityWait { gate.reads == 1 }
        XCTAssertTrue(live.save(login: "replacement", token: "new-fixture"))
        gate.release()
        do { _ = try await pending.value; XCTFail("A replaced epoch must discard its cold read") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(live.signIn?.login, "replacement")
        XCTAssertEqual(live.signIn?.token, "new-fixture")
    }

    func testRemovedFolderCannotStartARequestAfterCredentialAdmission() async throws {
        let (store, _) = fixture()
        let gate = LiveRefreshReadGate()
        defer { gate.release() }
        var fetches = 0
        let live = LiveFolders(profileID: store.profileID,
            readCredential: { .missing },
            readCredentialAsync: { (try? await Passwords.perform { gate.read() }) ?? .unavailable(-25308) },
            fetchPullRequests: { _, _ in fetches += 1; return .success([]) })
        live.refreshAll()
        try await compatibilityWait { gate.reads == 1 }
        let joined = Task { try await live.signInAsync() }
        store.pins = Pins()
        gate.release()
        _ = try await joined.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fetches, 0)
    }

    func testPostSignOutWaiterCannotAdoptAnEarlierEpochRead() async throws {
        let (store, _) = fixture()
        let gate = LiveRefreshEpochGate()
        var signedOut = false
        let live = LiveFolders(profileID: store.profileID,
            readCredential: { signedOut ? .missing : .found(account: "fixture", password: "old-fixture") },
            readCredentialAsync: { await gate.read() },
            deleteCredential: { _ in signedOut = true; return true })
        func waitForReads(_ wanted: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await gate.reads < wanted, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let actual = await gate.reads
            XCTAssertEqual(actual, wanted, "A new credential epoch must start its own read")
            if actual != wanted { throw CancellationError() }
        }
        let old = Task { try await live.signInAsync() }
        defer { Task { await gate.release() } }
        try await waitForReads(1)
        live.signOut()
        XCTAssertTrue(signedOut)
        let newer = Task { try await live.signInAsync() }
        try await waitForReads(2)
        let current = try await newer.value
        XCTAssertNil(current)
        await gate.release()
        do { _ = try await old.value; XCTFail("Old epoch must be rejected") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertNil(live.signIn)
    }
}
