import AppKit
import XCTest
@testable import vane

/// A stub that answers authentication requests when the test says so. Never a real prompt.
@MainActor final class StubAuthenticator {
    var reasons: [String] = []
    var pending: [@MainActor (Bool) -> Void] = []
    var answer: Bool?

    var authenticate: PasswordPaneLock.Authenticate {
        { [unowned self] reason, done in
            reasons.append(reason)
            if let answer { done(answer) } else { pending.append(done) }
        }
    }
}

@MainActor final class PasswordPaneLockTests: XCTestCase {
    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()

    override func setUp() {
        TestEnvironment.prepare()
        UserDefaults.vane.removeObject(forKey: PasswordPaneLock.requiredKey)
    }
    override func tearDown() { UserDefaults.vane.removeObject(forKey: PasswordPaneLock.requiredKey) }

    private func lock(_ stub: StubAuthenticator, idle: Duration = .seconds(300)) -> PasswordPaneLock {
        PasswordPaneLock(idle: idle, observing: true, workspace: workspace,
                         distributed: distributed, authenticate: stub.authenticate)
    }

    func testRequiredByDefaultAndUnlockGrantsOnlyTheAuthenticatedProfile() {
        XCTAssertTrue(PasswordPaneLock.required)
        let stub = StubAuthenticator(); stub.answer = true
        let lock = lock(stub)
        let a = UUID(), b = UUID()
        XCTAssertFalse(lock.isUnlocked(a))
        lock.unlock(a)
        XCTAssertEqual(stub.reasons.count, 1)
        XCTAssertTrue(lock.isUnlocked(a))
        XCTAssertFalse(lock.isUnlocked(b), "Unlocking one profile's passwords must not open another's")
    }

    func testDeniedAuthenticationStaysLockedAndSaysSo() {
        let stub = StubAuthenticator(); stub.answer = false
        let lock = lock(stub)
        let profile = UUID()
        lock.unlock(profile)
        XCTAssertFalse(lock.isUnlocked(profile))
        XCTAssertNotNil(lock.problem)
        XCTAssertFalse(lock.authenticating)
    }

    func testTurningTheRequirementOffNeedsNoAuthentication() {
        UserDefaults.vane.set(false, forKey: PasswordPaneLock.requiredKey)
        let stub = StubAuthenticator()
        let lock = lock(stub)
        XCTAssertTrue(lock.isUnlocked(UUID()))
        lock.unlock(UUID())
        XCTAssertTrue(stub.reasons.isEmpty)
    }

    func testALockWhileThePromptIsUpDiscardsItsLateSuccess() {
        let stub = StubAuthenticator()
        let lock = lock(stub)
        let profile = UUID()
        lock.unlock(profile)
        XCTAssertTrue(lock.authenticating)
        lock.lock()
        stub.pending.forEach { $0(true) }
        XCTAssertFalse(lock.isUnlocked(profile))
    }

    func testScreenLockSleepAndSessionSwitchRelock() {
        let profile = UUID()
        let stub = StubAuthenticator(); stub.answer = true
        let lock = lock(stub)
        let posts: [(NotificationCenter, Notification.Name)] = [
            (distributed, Notification.Name("com.apple.screenIsLocked")),
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
        ]
        for (center, name) in posts {
            lock.unlock(profile)
            XCTAssertTrue(lock.isUnlocked(profile))
            center.post(name: name, object: nil)
            XCTAssertFalse(lock.isUnlocked(profile), "\(name.rawValue) must relock the pane")
        }
    }

    func testIdleRelocksButInteractionKeepsItOpen() async throws {
        let profile = UUID()
        let stub = StubAuthenticator(); stub.answer = true
        let lock = lock(stub, idle: .milliseconds(300))
        lock.unlock(profile)
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(100))
            lock.touch()
        }
        XCTAssertTrue(lock.isUnlocked(profile), "Interaction within the idle window must keep the pane open")
        try await compatibilityWait { !lock.isUnlocked(profile) }
    }

    func testClosingSettingsRelocks() throws {
        SettingsWindow.show(tab: "general")
        let window = try XCTUnwrap(NSApp.windows.first(where: { SettingsWindow.holds($0) }))
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        defer { window.close() }
        let profile = UUID()
        let stub = StubAuthenticator(); stub.answer = true
        let lock = lock(stub)
        lock.watchSettings()
        lock.unlock(profile)
        XCTAssertTrue(lock.isUnlocked(profile))
        window.close()
        XCTAssertFalse(lock.isUnlocked(profile))
    }
}

private struct DeleteFailure: LocalizedError { var errorDescription: String? { "Fixture refusal." } }

@MainActor final class PasswordPendingDeletionTests: XCTestCase {
    override func setUp() { TestEnvironment.prepare() }

    private let login = Passwords.Login(host: "mail.example", account: "ada@example.com")
    private let profile = UUID()

    func testUndoRestoresTheRowWithoutAnyKeychainWrite() async throws {
        var deletes = 0
        let deletion = PasswordPendingDeletion(grace: .milliseconds(80)) { _, _ in deletes += 1 }
        XCTAssertTrue(deletion.schedule(login, profileID: profile))
        XCTAssertTrue(deletion.hides(login, profileID: profile))
        XCTAssertFalse(deletion.hides(login, profileID: UUID()), "Hiding is per profile")
        deletion.undo()
        XCTAssertFalse(deletion.hides(login, profileID: profile))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(deletes, 0, "Undo must leave the Keychain untouched")
        XCTAssertFalse(Passwords.hasPendingOperations)
    }

    func testTheDeleteRunsWhenTheToastExpires() async throws {
        var deleted: [String] = []
        let deletion = PasswordPendingDeletion(grace: .milliseconds(60)) { login, _ in deleted.append(login.id) }
        deletion.schedule(login, profileID: profile)
        XCTAssertTrue(deleted.isEmpty, "Nothing is deleted while Undo is still offered")
        XCTAssertTrue(Passwords.hasPendingOperations, "Quitting must wait for an accepted delete")
        try await compatibilityWait { deleted == [self.login.id] && !Passwords.hasPendingOperations }
        XCTAssertNil(deletion.pending)
        XCTAssertTrue(deletion.hides(login, profileID: profile), "The row stays gone until the list reloads")
        deletion.prune([login], profileID: profile)
        XCTAssertTrue(deletion.hides(login, profileID: profile), "A list still holding it has not settled")
        deletion.prune([], profileID: profile)
        XCTAssertFalse(deletion.hides(login, profileID: profile))
    }

    func testCommitRunsTheDeleteImmediately() async throws {
        var deletes = 0
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in deletes += 1 }
        deletion.schedule(login, profileID: profile)
        deletion.commit()
        XCTAssertNil(deletion.pending)
        try await compatibilityWait { deletes == 1 }
    }

    func testASecondDeleteFlushesTheFirst() async throws {
        var deleted: [String] = []
        let other = Passwords.Login(host: "bank.example", account: "ada")
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { login, _ in deleted.append(login.id) }
        deletion.schedule(login, profileID: profile)
        deletion.schedule(other, profileID: profile)
        try await compatibilityWait { deleted == [self.login.id] }
        XCTAssertEqual(deletion.pending?.login, other)
        deletion.undo()
    }

    func testAFailedDeleteBringsTheRowBackAndReportsIt() async throws {
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in throw DeleteFailure() }
        deletion.schedule(login, profileID: profile)
        deletion.commit()
        try await compatibilityWait { deletion.failure != nil }
        XCTAssertFalse(deletion.hides(login, profileID: profile), "A login that is still saved must be listed")
        XCTAssertEqual(deletion.failures, 1)
        XCTAssertTrue(deletion.failure?.contains("ada@example.com") == true)
        XCTAssertTrue(deletion.failure?.contains("still saved") == true)
    }

    func testClosingSettingsRunsThePendingDelete() async throws {
        SettingsWindow.show(tab: "general")
        let window = try XCTUnwrap(NSApp.windows.first(where: { SettingsWindow.holds($0) }))
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        defer { window.close() }
        var deletes = 0
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in deletes += 1 }
        deletion.watchSettingsClose()
        deletion.schedule(login, profileID: profile)
        window.close()
        try await compatibilityWait { deletes == 1 }
    }

    func testRevealedPasswordsTintDigitsAndSymbolsApartFromLetters() {
        XCTAssertEqual(["l", "I", "O"].map { PasswordValue.kind(Character($0)) }, [.letter, .letter, .letter])
        XCTAssertEqual(["1", "0"].map { PasswordValue.kind(Character($0)) }, [.digit, .digit])
        XCTAssertEqual(["!", "-", "_"].map { PasswordValue.kind(Character($0)) }, [.symbol, .symbol, .symbol])
        let styled = PasswordValue.styled("l1O0!")
        XCTAssertEqual(String(styled.characters), "l1O0!", "Styling must not change the value")
        let colors = styled.runs.map(\.foregroundColor)
        XCTAssertEqual(colors.count, 5)
        XCTAssertNotEqual(colors[0], colors[1])
        XCTAssertNotEqual(colors[2], colors[3])
        XCTAssertNotEqual(colors[1], colors[4])
        XCTAssertEqual(PasswordsPane.spoken("l1O0!"), "l1O0!")
    }
}
