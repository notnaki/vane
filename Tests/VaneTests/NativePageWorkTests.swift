import AppKit
import WebKit
import Security
import XCTest
@testable import vane

private final class PasswordReadGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "worker entered")
    let release = DispatchSemaphore(value: 0)
    func wait() { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
}

@MainActor final class NativePageWorkTests: XCTestCase {
    func testBlockedKeychainMetadataLeavesMainActorAvailable() async throws {
        let gate = PasswordReadGate(), profile = UUID()
        let origin = PasswordOrigin(host: "worker.invalid")
        var reader = Passwords.Reader()
        reader.matches = { candidate, candidateProfile in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(candidate, origin)
            XCTAssertEqual(candidateProfile, profile)
            return try Passwords.allChecked(profileID: candidateProfile) { _, result in
                gate.wait()
                var item: [String: Any] = [
                    kSecAttrServer as String: candidate.host,
                    kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
                    kSecAttrAccount as String: "fixture",
                ]
                if let scope = Passwords.namespace(profileID: candidateProfile, dataDir: Store.overrideDirectory) {
                    item[kSecAttrSecurityDomain as String] = scope
                }
                result?.pointee = [item] as CFArray
                return errSecSuccess
            }
        }
        let task = Task { try await reader.logins(origin: origin, profileID: profile) }
        await fulfillment(of: [gate.entered], timeout: 2)
        // Reaching here while the synchronous injected service waits proves actor progress.
        gate.release.signal()
        let logins = try await task.value
        XCTAssertEqual(logins.map(\.account), ["fixture"])
    }

    func testCancelledSecretReadDoesNotPublishLateSecret() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.password = { _, _, _ in gate.wait(); return "late fixture secret" }
        let task = Task { try await reader.secret(.init(host: "worker.invalid", account: "fixture"), profileID: UUID()) }
        await fulfillment(of: [gate.entered], timeout: 2)
        task.cancel()
        gate.release.signal()
        do { _ = try await task.value; XCTFail("Cancelled read returned a secret") }
        catch is CancellationError { }
    }

    private func loadedTab(reader: Passwords.Reader) async throws -> Tab {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let tab = Tab(profileID: UUID())
        tab.passwordReader = reader
        tab.web.loadSimulatedRequest(URLRequest(url: URL(string: "https://worker.invalid/")!),
            responseHTML: "<form><input autocomplete=username><input type=password></form>")
        let deadline = Date.now.addingTimeInterval(5)
        while tab.web.isLoading || tab.web.url == nil {
            if Date.now > deadline { tab.tearDown(); throw NSError(domain: "WorkerFixtureTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The spy belongs to the isolated autofill world, so a secret handed to WebKit is
        // observable even if the original target became invalid and the script refused it.
        do {
            _ = try await script(tab.web, "window.__workerFills=0; window.__vaneFill=()=>{ window.__workerFills++; return true; }; 0")
            return tab
        } catch { tab.tearDown(); throw error }
    }

    private func script(_ web: WKWebView, _ source: String) async throws -> Int? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source, in: nil, in: Autofill.world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? Int)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func testNavigationDiscardsSecretBeforeItReachesWebKit() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, _, _ in gate.wait(); return "fixture secret" }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.fill(.init(host: "worker.invalid", account: "ada"), target: "fixture")
        await fulfillment(of: [gate.entered], timeout: 2)
        tab.readingDocumentGeneration = UUID()
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        let fills = try await script(tab.web, "window.__workerFills")
        XCTAssertEqual(fills, 0)
    }

    func testExplicitChosenAccountSurvivesChooserBlurWhileReadingSecret() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, _, _ in gate.wait(); return "fixture secret" }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.fillChosen(host: "worker.invalid", account: "ada", target: "fixture")
        await fulfillment(of: [gate.entered], timeout: 2)
        tab.closeChooser(.blur)
        gate.release.signal()
        let deadline = Date.now.addingTimeInterval(2)
        var fills = 0
        while fills == 0, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            fills = try await script(tab.web, "window.__workerFills") ?? 0
        }
        XCTAssertEqual(fills, 1)
    }

    func testChangingInputDiscardsSecretWithinSameDocument() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, _, _ in gate.wait(); return "fixture secret" }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.fill(.init(host: "worker.invalid", account: "ada"), target: "fixture")
        await fulfillment(of: [gate.entered], timeout: 2)
        tab.closeChooser(.input)
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        let fills = try await script(tab.web, "window.__workerFills")
        XCTAssertEqual(fills, 0)
    }

    func testDismissalDiscardsMetadataBeforeItReopensChooser() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        reader.matches = { origin, _ in gate.wait(); return [.init(origin: origin, account: "ada")] }
        tab.passwordReader = reader
        tab.fillPassword(target: "fixture")
        await fulfillment(of: [gate.entered], timeout: 2)
        tab.closeChooser(.escape)
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        let fills = try await script(tab.web, "window.__workerFills")
        XCTAssertEqual(fills, 0)
        XCTAssertNil(tab.passwordChoice)
    }

    func testConfirmationWorkerKeepsDraftAndIgnoresDismissedOffer() async throws {
        TestEnvironment.prepare()
        let gate = PasswordReadGate(), tab = Tab(profileID: UUID())
        defer { tab.tearDown() }
        var reader = Passwords.Reader()
        reader.commit = { _, _, _, _, _ in
            XCTAssertFalse(Thread.isMainThread)
            gate.wait()
            return .saved
        }
        tab.passwordReader = reader
        let offer = PendingSave(host: "worker.invalid", account: "ada", password: "fixture")
        tab.pendingSave = offer
        tab.confirmSaveAsync()
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(tab.pendingSave?.id, offer.id)
        let newer = PendingSave(host: "worker.invalid", account: "bob", password: "new fixture")
        tab.pendingSave = newer
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tab.pendingSave?.id, newer.id)
    }

    func testDelayedSubmittedSaveOfferSurvivesSameOriginRedirect() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, _, _ in gate.wait(); return nil }
        reader.revision = { _, _, _ in nil }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.offerSubmittedPassword(origin: .init(host: "worker.invalid"), account: "ada", password: "submitted fixture", attempt: "one")
        await fulfillment(of: [gate.entered], timeout: 2)
        tab.web.loadSimulatedRequest(URLRequest(url: URL(string: "https://worker.invalid/account")!), responseHTML: "<p>Signed in</p>")
        let deadline = Date.now.addingTimeInterval(3)
        while tab.web.isLoading || tab.web.url?.path != "/account" {
            if Date.now > deadline { return XCTFail("redirect fixture did not load") }
            try await Task.sleep(for: .milliseconds(20))
        }
        gate.release.signal()
        while tab.pendingSave == nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tab.pendingSave?.account, "ada")
        XCTAssertEqual(tab.pendingSave?.password, "submitted fixture")
        XCTAssertEqual(tab.pendingSave?.attempt, "one")
    }

    func testCrossOriginNavigationPermanentlyRevokesDelayedSubmission() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, _, _ in gate.wait(); return nil }
        reader.revision = { _, _, _ in nil }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.offerSubmittedPassword(origin: .init(host: "worker.invalid"), account: "ada", password: "submitted fixture", attempt: "one")
        await fulfillment(of: [gate.entered], timeout: 2)
        // Even returning to the original origin before the service responds must not
        // restore authorization revoked by the intervening main-frame navigation.
        tab.allowCertificateNavigation(to: URL(string: "https://other.invalid/"))
        tab.allowCertificateNavigation(to: URL(string: "https://worker.invalid/account"))
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tab.pendingSave)
    }

    func testRejectedDelayedSubmissionDoesNotBecomeSaveOffer() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, _, _ in gate.wait(); return nil }
        reader.revision = { _, _, _ in nil }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.offerSubmittedPassword(origin: .init(host: "worker.invalid"), account: "ada", password: "submitted fixture", attempt: "rejected")
        await fulfillment(of: [gate.entered], timeout: 2)
        _ = try await script(tab.web, "window.webkit.messageHandlers.vanepw.postMessage({rejectedAttempt:'rejected'}); 0")
        try await Task.sleep(for: .milliseconds(30))
        gate.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(tab.pendingSave)
    }

    func testNewerSubmissionWinsWhileOldReadWaits() async throws {
        let gate = PasswordReadGate()
        var reader = Passwords.Reader()
        reader.matches = { _, _ in [] }
        reader.password = { _, account, _ in if account == "ada" { gate.wait() }; return nil }
        reader.revision = { _, _, _ in nil }
        let tab = try await loadedTab(reader: reader)
        defer { tab.tearDown() }
        tab.offerSubmittedPassword(origin: .init(host: "worker.invalid"), account: "ada", password: "older fixture", attempt: "one")
        await fulfillment(of: [gate.entered], timeout: 2)
        tab.offerSubmittedPassword(origin: .init(host: "worker.invalid"), account: "bob", password: "newer fixture", attempt: "two")
        gate.release.signal()
        let deadline = Date.now.addingTimeInterval(2)
        while tab.pendingSave?.account != "bob", Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tab.pendingSave?.account, "bob")
        XCTAssertEqual(tab.pendingSave?.attempt, "two")
    }

    func testViewSourceEscapesMarkupAndPreservesUnicode() throws {
        let html = try ViewSourcePage.build("<script>é & 👩🏽‍💻</script>")
        XCTAssertTrue(html.contains("&lt;script&gt;é &amp; 👩🏽‍💻&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testViewSourceRejectsOversizedInputBeforeEscaping() {
        XCTAssertThrowsError(try ViewSourcePage.build(String(repeating: "&", count: ViewSourcePage.maximumBytes + 1)))
        // Renderer UTF-16 length can fit while native UTF-8 is too large.
        XCTAssertThrowsError(try ViewSourcePage.build(String(repeating: "界", count: ViewSourcePage.maximumBytes / 3 + 1)))
    }
}
