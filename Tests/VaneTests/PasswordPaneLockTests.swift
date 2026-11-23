import AppKit
import LocalAuthentication
import XCTest
@testable import vane

/// Records whether the lock took its prompt down. Never evaluated, so never on screen.
final class SpyContext: LAContext {
    private(set) var invalidated = false
    override func invalidate() { invalidated = true; super.invalidate() }
}

/// A stub that answers authentication requests when the test says so. Never a real prompt.
@MainActor final class StubAuthenticator {
    var reasons: [String] = []
    var pending: [@MainActor (Bool) -> Void] = []
    var contexts: [SpyContext] = []
    var answer: Bool?

    var authenticate: PasswordPaneLock.Authenticate {
        { [unowned self] reason, done in
            reasons.append(reason)
            if let answer { done(answer); return nil }
            pending.append(done)
            let context = SpyContext()
            contexts.append(context)
            return context
        }
    }
}

@MainActor final class PasswordPaneLockTests: XCTestCase {
    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()

    override func setUp() {
        TestEnvironment.prepare()
        UserDefaults.vane.removeObject(forKey: PasswordPaneLock.requiredKey)
        UserDefaults.vane.removeObject(forKey: FolderUnlockMethod.key)
    }
    override func tearDown() {
        UserDefaults.vane.removeObject(forKey: PasswordPaneLock.requiredKey)
        UserDefaults.vane.removeObject(forKey: FolderUnlockMethod.key)
    }

    /// Separate stubs for the inline scan and the macOS sheet, Settings in front and a
    /// Mac with Touch ID unless a test says otherwise. Neither stub ever prompts.
    private func inlineLock(_ sheet: StubAuthenticator, _ scan: StubAuthenticator,
                            biometrics: Bool = true) -> (PasswordPaneLock, () -> [LAContext]) {
        var attached: [LAContext] = []
        let inline = scan.authenticate
        let lock = PasswordPaneLock(observing: true, workspace: workspace, distributed: distributed,
                                    authenticate: sheet.authenticate,
                                    inline: { context, reason, done in attached.append(context); return inline(reason, done) })
        lock.biometricsAvailable = { biometrics }
        lock.mayPrompt = { true }
        return (lock, { attached })
    }

    func testOpeningStartsTheInlineScanOnceAndACancelWaitsForATap() {
        let sheet = StubAuthenticator(), scan = StubAuthenticator()
        let (lock, attached) = inlineLock(sheet, scan)
        let profile = UUID()
        let first = lock.inlineContext
        lock.beginAutomaticUnlock(profile)
        XCTAssertEqual(scan.reasons.count, 1, "The locked pane must start listening for Touch ID on its own")
        XCTAssertTrue(sheet.reasons.isEmpty, "…inline, without the macOS sheet")
        XCTAssertTrue(attached().first === first, "The scan must run on the context the embedded view holds")
        XCTAssertFalse(lock.usingPassword)
        lock.beginAutomaticUnlock(profile)
        XCTAssertEqual(scan.reasons.count, 1, "One attempt at a time")
        scan.pending.removeFirst()(false)
        XCTAssertFalse(lock.inlineContext === first, "A finished attempt's context must be retired")
        XCTAssertNotNil(lock.problem)
        lock.beginAutomaticUnlock(profile)
        XCTAssertEqual(scan.reasons.count, 1, "A cancel or failure must wait for a tap, not start again")
        lock.unlock(profile)
        XCTAssertEqual(scan.reasons.count, 2, "Tapping the control retries")
        scan.pending.removeFirst()(true)
        XCTAssertTrue(lock.isUnlocked(profile))
    }

    func testTheScanWaitsForSettingsToBeInFront() {
        let sheet = StubAuthenticator(), scan = StubAuthenticator()
        let (lock, _) = inlineLock(sheet, scan)
        var front = false
        lock.mayPrompt = { front }
        let profile = UUID()
        lock.beginAutomaticUnlock(profile)
        XCTAssertTrue(scan.reasons.isEmpty && sheet.reasons.isEmpty, "Nothing may start while Settings is not key")
        front = true
        lock.beginAutomaticUnlock(profile)
        XCTAssertEqual(scan.reasons.count, 1)
    }

    func testUsePasswordRetiresTheScanForTheMacOSSheet() {
        let sheet = StubAuthenticator(), scan = StubAuthenticator()
        let (lock, _) = inlineLock(sheet, scan)
        let profile = UUID()
        lock.beginAutomaticUnlock(profile)
        let late = scan.pending.removeFirst()
        lock.unlock(profile, password: true)
        XCTAssertEqual(scan.contexts.map(\.invalidated), [true], "The waiting scan must be taken down")
        XCTAssertEqual(sheet.reasons.count, 1, "Use Password… opens the macOS sheet")
        XCTAssertTrue(lock.usingPassword)
        late(true)
        XCTAssertFalse(lock.isUnlocked(profile), "The retired scan's late answer must not unlock")
        XCTAssertTrue(lock.authenticating)
        sheet.pending.removeFirst()(true)
        XCTAssertTrue(lock.isUnlocked(profile))
    }

    func testSystemMethodAndMacsWithoutTouchIDUseTheMacOSSheet() {
        for (method, biometrics) in [(FolderUnlockMethod.system, true), (.touchID, false)] {
            Prefs.folderUnlockMethod = method
            let sheet = StubAuthenticator(), scan = StubAuthenticator()
            let (lock, _) = inlineLock(sheet, scan, biometrics: biometrics)
            XCTAssertFalse(lock.usesInline)
            lock.beginAutomaticUnlock(UUID())
            XCTAssertTrue(scan.reasons.isEmpty, "\(method) with Touch ID \(biometrics) must not scan inline")
            XCTAssertEqual(sheet.reasons.count, 1)
            XCTAssertTrue(lock.usingPassword)
        }
    }

    func testLeavingThePaneTakesTheScanDownAndPresentingAgainStartsIt() {
        let sheet = StubAuthenticator(), scan = StubAuthenticator()
        let (lock, _) = inlineLock(sheet, scan)
        let profile = UUID()
        lock.beginAutomaticUnlock(profile)
        let used = lock.inlineContext
        lock.cancel()
        XCTAssertEqual(scan.contexts.map(\.invalidated), [true])
        XCTAssertFalse(lock.authenticating)
        XCTAssertFalse(lock.inlineContext === used)
        lock.beginAutomaticUnlock(profile)
        XCTAssertEqual(scan.reasons.count, 1, "Not presented again yet")
        lock.rearm()
        lock.beginAutomaticUnlock(profile)
        XCTAssertEqual(scan.reasons.count, 2, "A new presentation starts listening again")
        let scanning = lock.inlineContext
        lock.lock()
        XCTAssertFalse(lock.inlineContext === scanning, "Locking retires the embedded context too")
    }

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
        XCTAssertEqual(stub.contexts.map(\.invalidated), [true], "Locking must take the Touch ID sheet down")
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
        let before = ContinuousClock.now
        deletion.schedule(login, profileID: profile)
        XCTAssertTrue(deleted.isEmpty, "Nothing is deleted while Undo is still offered")
        XCTAssertTrue(Passwords.hasPendingOperations, "Quitting must wait for an accepted delete")
        try await compatibilityWait { deleted == [self.login.id] && !Passwords.hasPendingOperations }
        XCTAssertNil(deletion.pending)
        XCTAssertTrue(deletion.hides(login, profileID: profile), "The row stays gone until the list reloads")
        deletion.prune([login], profileID: profile, fetchedAt: before)
        XCTAssertTrue(deletion.hides(login, profileID: profile), "A list fetched before the delete finished has not settled")
        deletion.prune([login], profileID: profile, fetchedAt: .now)
        XCTAssertFalse(deletion.hides(login, profileID: profile),
                       "The first list fetched after the delete is settled, even holding the login again")
    }

    func testAListFetchedBeforeTheDeleteWithoutTheLoginAlsoSettles() async throws {
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in }
        let before = ContinuousClock.now
        deletion.schedule(login, profileID: profile)
        deletion.commit()
        try await compatibilityWait { !deletion.gone.isEmpty }
        deletion.prune([], profileID: UUID(), fetchedAt: .now)
        XCTAssertTrue(deletion.hides(login, profileID: profile), "Another profile's list settles nothing here")
        deletion.prune([], profileID: profile, fetchedAt: before)
        XCTAssertFalse(deletion.hides(login, profileID: profile))
    }

    func testFocusOnTheToastHoldsTheDelete() async throws {
        var deletes = 0
        let deletion = PasswordPendingDeletion(grace: .milliseconds(60)) { _, _ in deletes += 1 }
        deletion.schedule(login, profileID: profile)
        deletion.hold(true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(deletes, 0, "A toast with VoiceOver or keyboard focus must not expire")
        XCTAssertNotNil(deletion.pending)
        deletion.hold(false)
        try await compatibilityWait { deletes == 1 }
    }

    func testAKeychainItemAlreadyGoneCountsAsDeleted() async throws {
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in
            throw Passwords.Failure(status: errSecItemNotFound)
        }
        deletion.schedule(login, profileID: profile)
        deletion.commit()
        try await compatibilityWait { !deletion.gone.isEmpty }
        XCTAssertNil(deletion.failure)
        XCTAssertEqual(deletion.failures, 0)
        XCTAssertTrue(deletion.hides(login, profileID: profile))
    }

    /// The quit path reads the count when quitting starts, so a delete that failed during
    /// an earlier quit step (Settings closing, say) still stops the quit.
    func testQuitStopsForADeleteThatFailedEarlierInTheQuit() async throws {
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in throw DeleteFailure() }
        let atStart = deletion.failures
        deletion.schedule(login, profileID: profile)
        deletion.commit()
        try await compatibilityWait { deletion.failures == atStart + 1 }
        let finished = await deletion.finishForQuit(failuresAtStart: atStart)
        XCTAssertFalse(finished)
        let clean = await deletion.finishForQuit(failuresAtStart: deletion.failures)
        XCTAssertTrue(clean)
    }

    func testQuitRunsThePendingDelete() async throws {
        var deletes = 0
        let deletion = PasswordPendingDeletion(grace: .seconds(60)) { _, _ in deletes += 1 }
        deletion.schedule(login, profileID: profile)
        let finished = await deletion.finishForQuit(failuresAtStart: deletion.failures)
        XCTAssertTrue(finished)
        XCTAssertEqual(deletes, 1)
        XCTAssertFalse(Passwords.hasPendingOperations)
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
