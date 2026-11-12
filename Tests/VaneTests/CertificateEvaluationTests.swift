import AppKit
import Security
import WebKit
import XCTest
@testable import vane

@MainActor final class CertificateEvaluationTests: XCTestCase {
    private var appLoop: NativeFixtureApplicationLoop?
    private var previousPolicy: NSApplication.ActivationPolicy?
    private var ownedPresentations: [(tab: Tab, window: NSWindow)] = []
    private var ownedSheets: [NSWindow] = []
    private var fixtureNavigations: [UUID: WKNavigation] = [:]

    /// XCTest's invocation cannot finish while an async setup-owned NSApp.run
    /// remains active. Keep acquisition, assertions and joined retirement inside
    /// the test body, including every failure path.
    private func withPresentationLoop(_ body: @MainActor () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        previousPolicy = policy
        var failure: (any Error)?
        do {
            appLoop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: policy == .prohibited ? .accessory : policy)
            try await body()
        } catch { failure = error }
        do { try await retirePresentations() }
        catch { if failure == nil { failure = error } else { XCTFail("Native presentation cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func retirePresentations() async throws {
        guard let previousPolicy else { return }
        var failure: (any Error)?
        do {
            for presentation in ownedPresentations {
                if let sheet = presentation.window.attachedSheet {
                    presentation.window.endSheet(sheet, returnCode: .abort)
                }
            }
            try await waitForPresentation("certificate sheets detached before retirement") {
                self.ownedPresentations.allSatisfy { $0.window.attachedSheet == nil }
                    && self.ownedSheets.allSatisfy { !$0.isVisible }
            }
        } catch { failure = error }
        for presentation in ownedPresentations.reversed() {
            CertificateTrust.forget(profile: presentation.tab.profileID)
            presentation.tab.tearDown()
            presentation.window.contentView = nil
            NSApp.removeWindowsItem(presentation.window)
            presentation.window.close()
        }
        do {
            try await waitForPresentation("certificate windows retired before loop join") {
                self.ownedPresentations.allSatisfy { !$0.window.isVisible && $0.window.contentView == nil }
            }
        } catch { if failure == nil { failure = error } }
        ownedSheets.removeAll()
        ownedPresentations.removeAll()
        fixtureNavigations.removeAll()
        if let appLoop {
            do { try await appLoop.close() }
            catch { if failure == nil { failure = error } }
        }
        self.appLoop = nil
        self.previousPolicy = nil
        if NSApp.activationPolicy() != previousPolicy { NSApp.setActivationPolicy(previousPolicy) }
        do { try await waitForPresentation("certificate original policy restored") { NSApp.activationPolicy() == previousPolicy } }
        catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private func waitForPresentation(_ reason: String, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + reason) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func admitPresentation(_ tab: Tab, in window: NSWindow) async throws {
        try XCTUnwrap(appLoop).verifyRunning()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitForPresentation("certificate foreground and exact presentation owner") {
            NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching
                && NSApp.isActive && window.isKeyWindow && window.isVisible
                && window.contentView === tab.web && tab.web.window === window
                && !tab.web.isHiddenOrHasHiddenAncestor && !tab.web.isLoading
        }
        let text = try await tab.web.evaluateJavaScript("document.body.textContent") as? String
        guard text == "exception fixture" else { throw ExtensionHost.Failure("The certificate warning's exact fixture document is not ready") }
        NativeFixtureDiagnostics.emit("certificate presentation admitted: running=\(NSApp.isRunning), finished=\(NSRunningApplication.current.isFinishedLaunching), policy=\(NSApp.activationPolicy().rawValue), exactOwner=\(tab.web.window === window), excludedFromWindowsMenu=\(window.isExcludedFromWindowsMenu)")
    }

    func testSameLeafAtDifferentVerifyDateDoesNotReuseSuccessfulOutcome() async throws {
        let certificate = try certificate()
        let host = "date-\(UUID()).invalid"
        let current = try trust(certificate, anchored: true, date: .now.addingTimeInterval(60))
        let expired = try trust(certificate, anchored: true, date: .now.addingTimeInterval(3 * 86400))
        let first = await CertificateTrust.evaluate(current, host: host, port: 443)
        let second = await CertificateTrust.evaluate(expired, host: host, port: 443)
        XCTAssertTrue(first.ok)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertFalse(second.ok, "The supplied trust has expired even though its leaf has not changed")
    }

    func testSameLeafWithDifferentAnchorsDoesNotReuseEitherOutcome() async throws {
        let certificate = try certificate()
        let host = "chain-\(UUID()).invalid"
        let unanchored = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
        let anchored = try trust(certificate, anchored: true, date: .now.addingTimeInterval(60))
        let first = await CertificateTrust.evaluate(unanchored, host: host, port: 443)
        let second = await CertificateTrust.evaluate(anchored, host: host, port: 443)
        let third = await CertificateTrust.evaluate(try trust(certificate, anchored: false,
            date: .now.addingTimeInterval(60)), host: host, port: 443)
        XCTAssertFalse(first.ok)
        XCTAssertTrue(second.ok, "A previous failure cannot replace evaluation of the new chain")
        XCTAssertFalse(third.ok, "A previous success cannot approve a different chain")
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
        let trust: SecTrust
        override var serverTrust: SecTrust? { trust }
        override func copy(with zone: NSZone? = nil) -> Any { self }
        init(host: String, trust: SecTrust) {
            self.trust = trust
            super.init(host: host, port: 443, protocol: "https", realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }
        required init?(coder: NSCoder) { fatalError("Not used by this fixture") }
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func fixture(isPrivate: Bool = true, profileID: UUID = UUID(), documentURL: URL? = nil) async throws -> (Tab, NSWindow) {
        TestEnvironment.prepare()
        try XCTUnwrap(appLoop).verifyRunning()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(popup: configuration, isPrivate: isPrivate, profileID: profileID)
        tab.web.navigationDelegate = nil
        let navigation = try XCTUnwrap(tab.web.loadHTMLString("exception fixture", baseURL: documentURL))
        fixtureNavigations[tab.id] = navigation
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = tab.web
        ownedPresentations.append((tab, window))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitForPresentation("certificate fixture document completed") { !tab.web.isLoading && tab.web.url != nil }
        try await admitPresentation(tab, in: window)
        tab.allowCertificateNavigation(to: URL(string: "https://trust-fixture.invalid"))
        tab.webView(tab.web, didStartProvisionalNavigation: navigation)
        return (tab, window)
    }

    private func answer(_ trust: SecTrust, in tab: Tab, window: NSWindow, approve: Bool)
        async throws -> (URLSession.AuthChallengeDisposition, Int) {
        try await admitPresentation(tab, in: window)
        let request = URLAuthenticationChallenge(
            protectionSpace: TrustSpace(host: "trust-fixture.invalid", trust: trust),
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil,
            error: nil, sender: Sender())
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        var handled = Set<ObjectIdentifier>()
        let task = Task { result = await tab.webView(tab.web, respondTo: request) }
        let deadline = Date.now.addingTimeInterval(10)
        while result == nil && Date.now < deadline {
            if let sheet = window.attachedSheet, handled.insert(ObjectIdentifier(sheet)).inserted {
                sheet.isExcludedFromWindowsMenu = true
                ownedSheets.append(sheet)
                XCTAssertTrue(sheet.sheetParent === window)
                window.endSheet(sheet, returnCode: approve ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if result == nil { task.cancel(); CertificateTrust.navigationStarted(in: tab) }
        await task.value
        try await waitForPresentation("certificate challenge sheet fully dismissed") { window.attachedSheet == nil }
        let response = try XCTUnwrap(result, "Every challenge must receive a bounded answer")
        XCTAssertEqual(response.1 != nil, response.0 == .useCredential)
        return (response.0, handled.count)
    }

    func testApprovedExceptionDoesNotCoverNewExpiryOfSameLeaf() async throws {
        try await withPresentationLoop {
            let certificate = try certificate()
            let (tab, window) = try await fixture()
            let initial = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                           in: tab, window: window, approve: true)
            XCTAssertEqual(initial.0, .useCredential)
            XCTAssertEqual(initial.1, 2, "An exception requires both explicit warning approvals")
            let unchanged = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                             in: tab, window: window, approve: false)
            XCTAssertEqual(unchanged.0, .useCredential)
            XCTAssertEqual(unchanged.1, 0, "The same approved errors remain usable")
            let expired = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(3 * 86400)),
                                           in: tab, window: window, approve: false)
            XCTAssertEqual(expired.0, .cancelAuthenticationChallenge, "The old approval cannot cover newly expired trust")
            XCTAssertEqual(expired.1, 1, "The new failure must ask again rather than silently returning a credential")
        }
    }

    func testApprovedExceptionDoesNotCoverNewHostnameFailureOfSameLeaf() async throws {
        try await withPresentationLoop {
            let certificate = try certificate()
            let (tab, window) = try await fixture()
            let original = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
            XCTAssertEqual(SecTrustSetPolicies(original, SecPolicyCreateSSL(true, "trust-fixture.invalid" as CFString)), errSecSuccess)
            let approved = try await answer(original, in: tab, window: window, approve: true)
            XCTAssertEqual(approved.0, .useCredential)
            XCTAssertEqual(approved.1, 2)
            let changed = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
            XCTAssertEqual(SecTrustSetPolicies(changed, SecPolicyCreateSSL(true, "changed-policy.invalid" as CFString)), errSecSuccess)
            let rejected = try await answer(changed, in: tab, window: window, approve: false)
            XCTAssertEqual(rejected.0, .cancelAuthenticationChallenge)
            XCTAssertEqual(rejected.1, 1, "Same leaf and server scope cannot rebind approval to a new hostname failure")
        }
    }

    func testLegacyBooleanExceptionCannotBypassWarning() async throws {
        try await withPresentationLoop {
            let certificate = try certificate()
            let (tab, window) = try await fixture(isPrivate: false)
            let scope = try XCTUnwrap(CertificateTrust.Scope(profileID: tab.profileID, host: "trust-fixture.invalid", port: 443))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let key = "certException.v2." + (try encoder.encode(scope)).base64EncodedString()
                + "|" + CertificateTrust.fingerprint(certificate)
            UserDefaults.vane.set(true, forKey: key)
            defer {
                UserDefaults.vane.removeObject(forKey: key)
                CertificateTrust.forget(profile: tab.profileID)
            }
            let rejected = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                            in: tab, window: window, approve: false)
            XCTAssertEqual(rejected.0, .cancelAuthenticationChallenge)
            XCTAssertEqual(rejected.1, 1, "A legacy boolean cannot prove which trust failures were approved")
        }
    }

    func testApprovedExceptionWithSameErrorsSurvivesNewTabInSameProfile() async throws {
        try await withPresentationLoop {
            let certificate = try certificate(), profile = UUID()
            let (first, firstWindow) = try await fixture(isPrivate: false, profileID: profile)
            defer { CertificateTrust.forget(profile: profile) }
            let approved = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                           in: first, window: firstWindow, approve: true)
            XCTAssertEqual(approved.0, .useCredential)
            XCTAssertEqual(approved.1, 2)
            let (second, secondWindow) = try await fixture(isPrivate: false, profileID: profile)
            let reused = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                         in: second, window: secondWindow, approve: false)
            XCTAssertEqual(reused.0, .useCredential)
            XCTAssertEqual(reused.1, 0, "A persisted exception remains usable for its approved errors and scope")
        }
    }

    func testCorruptOrBooleanVersion3RecordCannotBypassWarning() async throws {
        try await withPresentationLoop {
            let certificate = try certificate()
            let (tab, window) = try await fixture(isPrivate: false)
            let scope = try XCTUnwrap(CertificateTrust.Scope(profileID: tab.profileID, host: "trust-fixture.invalid", port: 443))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let key = "certException.v3." + (try encoder.encode(scope)).base64EncodedString()
                + "|" + CertificateTrust.fingerprint(certificate)
            defer {
                UserDefaults.vane.removeObject(forKey: key)
                CertificateTrust.forget(profile: tab.profileID)
            }
            let invalidRecords: [Any] = [true, Data([0, 1, 2])]
            for value in invalidRecords {
                UserDefaults.vane.set(value, forKey: key)
                let rejected = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                                in: tab, window: window, approve: false)
                XCTAssertEqual(rejected.0, .cancelAuthenticationChallenge)
                XCTAssertEqual(rejected.1, 1, "Only a native exception cookie that passes reevaluation can authorize reuse")
            }
        }
    }

    func testApprovedExceptionRemainsUnsafeForPasswordDelivery() async throws {
        try await withPresentationLoop {
            let certificate = try certificate()
            let document = URL(string: "https://trust-fixture.invalid/")!
            let (tab, window) = try await fixture(isPrivate: false, documentURL: document)
            defer { CertificateTrust.forget(profile: tab.profileID) }
            let raw = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
            let initial = await CertificateTrust.evaluate(raw, host: "trust-fixture.invalid", port: 443)
            XCTAssertFalse(initial.ok)
            let approved = try await answer(raw, in: tab, window: window, approve: true)
            XCTAssertEqual(approved.0, .useCredential)
            XCTAssertEqual(approved.1, 2)
            // Native cookie validation can report proceed on this same object.
            // That effective trust must not become browser system-trust provenance.
            let effective = await CertificateTrust.evaluate(raw, host: "trust-fixture.invalid", port: 443)
            XCTAssertTrue(effective.ok)
            tab.webView(tab.web, didCommit: try XCTUnwrap(fixtureNavigations[tab.id]))
            XCTAssertEqual(tab.certificateDocumentURL, document)
            // Replay the production publication of a successful copied/effective
            // trust, then the actual nil-serverTrust observer path of this HTML view.
            tab.applyCertificateTrustEvaluation(effective.ok)
            await tab.evaluateCertificateTrust(in: tab.web)
            XCTAssertFalse(tab.certificateTrusted, "An explicit TLS exception must remain untrusted in the browser")
            let decrypted = expectation(description: "No secret read for an excepted TLS document")
            decrypted.isInverted = true
            var reader = tab.passwordReader
            reader.password = { _, _, _ in decrypted.fulfill(); return nil }
            tab.passwordReader = reader
            tab.fill(.init(host: "trust-fixture.invalid", account: "fixture"), target: "fixture-field")
            await fulfillment(of: [decrypted], timeout: 0.2)
            tab.allowCertificateNavigation(to: URL(string: document.absoluteString + "#section"))
            tab.applyCertificateTrustEvaluation(true, result: .unspecified)
            await tab.evaluateCertificateTrust(in: tab.web)
            XCTAssertFalse(tab.certificateTrusted, "Same-document policy approval cannot erase exception provenance")
        }
    }

    private func approvedDocument() async throws -> (Tab, SecTrust, SecCertificate, URL) {
        let certificate = try certificate()
        let document = URL(string: "https://trust-fixture.invalid/")!
        let (tab, window) = try await fixture(isPrivate: false, documentURL: document)
        let raw = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
        let approved = try await answer(raw, in: tab, window: window, approve: true)
        XCTAssertEqual(approved.1, 2)
        guard approved.0 == .useCredential else { throw ExtensionHost.Failure("Fixture certificate consent was not accepted") }
        tab.webView(tab.web, didCommit: try XCTUnwrap(fixtureNavigations[tab.id]))
        XCTAssertFalse(tab.certificateTrusted)
        return (tab, raw, certificate, document)
    }

    private func beginReplacement(in tab: Tab, url: URL) async throws -> WKNavigation {
        let navigation = try XCTUnwrap(tab.web.loadHTMLString("exception fixture", baseURL: url))
        tab.allowCertificateNavigation(to: url)
        tab.webView(tab.web, didStartProvisionalNavigation: navigation)
        try await waitForPresentation("replacement certificate fixture document ready") {
            !tab.web.isLoading && tab.web.url == url
        }
        return navigation
    }

    func testFreshProceedWithoutBrowserProvenanceStillAllowsPasswordRead() async throws {
        try await withPresentationLoop {
            let document = URL(string: "https://trust-fixture.invalid/")!
            let (tab, _) = try await fixture(isPrivate: false, documentURL: document)
            tab.webView(tab.web, didCommit: try XCTUnwrap(fixtureNavigations[tab.id]))
            tab.applyCertificateTrustEvaluation(true, result: .proceed)
            XCTAssertTrue(tab.certificateTrusted, "Fresh enterprise/user trust remains valid without browser exception provenance")
            let read = expectation(description: "Fresh legitimate proceed retains password-read eligibility")
            var reader = tab.passwordReader
            reader.password = { _, _, _ in read.fulfill(); return nil }
            tab.passwordReader = reader
            tab.fill(.init(host: "trust-fixture.invalid", account: "fixture"), target: "fixture-field")
            await fulfillment(of: [read], timeout: 2)
        }
    }

    func testCopiedProceedOnSuccessorStaysUnsafeUntilFreshUnspecifiedTrust() async throws {
        try await withPresentationLoop {
            let (tab, original, certificate, document) = try await approvedDocument()
            let fresh = try trust(certificate, anchored: true, date: .now.addingTimeInterval(60))
            let system = await CertificateTrust.evaluate(fresh, host: "trust-fixture.invalid", port: 443)
            XCTAssertTrue(system.ok)
            XCTAssertEqual(system.result, .unspecified)
            tab.applyCertificateTrustEvaluation(system.ok, result: system.result, trust: fresh)
            XCTAssertFalse(tab.certificateTrusted, "The document that consumed the cookie cannot upgrade its own provenance")
            let navigation = try await beginReplacement(in: tab, url: document.appendingPathComponent("next"))
            tab.webView(tab.web, didCommit: navigation)
            let copied = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
            XCTAssertTrue(SecTrustSetExceptions(copied, try XCTUnwrap(SecTrustCopyExceptions(original))))
            let effective = await CertificateTrust.evaluate(copied, host: "trust-fixture.invalid", port: 443)
            XCTAssertTrue(effective.ok)
            XCTAssertEqual(effective.result, .proceed)
            tab.applyCertificateTrustEvaluation(effective.ok, result: effective.result, trust: copied)
            await tab.evaluateCertificateTrust(in: tab.web)
            XCTAssertFalse(tab.certificateTrusted, "A copied proceed or nil KVO cannot clear inherited bad-origin provenance")
            tab.applyCertificateTrustEvaluation(true, result: .unspecified, trust: original)
            XCTAssertFalse(tab.certificateTrusted, "Known cookie-mutated trust identity cannot serve as fresh system evidence")
            tab.applyCertificateTrustEvaluation(system.ok, result: system.result, trust: fresh)
            XCTAssertTrue(tab.certificateTrusted, "A new document with genuinely fresh system trust can recover")
            // Exercise system evidence delivered before commit as well as after it.
            let third = try await beginReplacement(in: tab, url: document.appendingPathComponent("third"))
            tab.applyCertificateTrustEvaluation(system.ok, result: system.result, trust: fresh)
            tab.webView(tab.web, didCommit: third)
            XCTAssertTrue(tab.certificateTrusted)
        }
    }

    func testFailedOrSupersededNavigationPreservesCommittedException() async throws {
        try await withPresentationLoop {
            let (tab, _, _, document) = try await approvedDocument()
            let older = try await beginReplacement(in: tab, url: URL(string: "https://older.invalid/")!)
            let newer = try await beginReplacement(in: tab, url: URL(string: "https://newer.invalid/")!)
            tab.webView(tab.web, didFailProvisionalNavigation: older, withError: URLError(.cancelled))
            tab.applyCertificateTrustEvaluation(true, result: .proceed)
            XCTAssertFalse(tab.certificateTrusted)
            tab.webView(tab.web, didFailProvisionalNavigation: newer, withError: URLError(.cancelled))
            tab.applyCertificateTrustEvaluation(true, result: .proceed)
            XCTAssertEqual(tab.certificateDocumentURL, document)
            XCTAssertFalse(tab.certificateTrusted, "Failure leaves the old excepted document's provenance intact")
        }
    }

    func testCrossOriginSubresourceExceptionDoesNotMarkMainDocument() async throws {
        try await withPresentationLoop {
            let document = URL(string: "https://trust-fixture.invalid/")!
            let (tab, _) = try await fixture(isPrivate: false, documentURL: document)
            tab.webView(tab.web, didCommit: try XCTUnwrap(fixtureNavigations[tab.id]))
            let foreign = try trust(try certificate(), anchored: false, date: .now.addingTimeInterval(60))
            tab.noteCertificateException(host: "cdn.other.invalid", port: 443, trust: foreign, in: tab.web)
            tab.applyCertificateTrustEvaluation(true, result: .proceed)
            XCTAssertTrue(tab.certificateTrusted, "Only the actual main-frame origin owns its exception marker")
        }
    }

    func testCancelledExceptedProvisionalRestoresValidCommittedTrust() async throws {
        try await withPresentationLoop {
            let document = URL(string: "https://trust-fixture.invalid/")!
            let (tab, _) = try await fixture(isPrivate: false, documentURL: document)
            tab.webView(tab.web, didCommit: try XCTUnwrap(fixtureNavigations[tab.id]))
            tab.applyCertificateTrustEvaluation(true, result: .unspecified)
            XCTAssertTrue(tab.certificateTrusted)
            let destination = URL(string: "https://untrusted.invalid/")!
            let navigation = try await beginReplacement(in: tab, url: destination)
            let raw = try trust(try certificate(), anchored: false, date: .now.addingTimeInterval(60))
            tab.noteCertificateException(host: "untrusted.invalid", port: 443, trust: raw, in: tab.web)
            XCTAssertFalse(tab.certificateTrusted)
            tab.webView(tab.web, didFailProvisionalNavigation: navigation, withError: URLError(.cancelled))
            XCTAssertEqual(tab.certificateDocumentURL, document)
            XCTAssertTrue(tab.certificateTrusted, "Cancel must restore the still-displayed valid document's recorded policy")
        }
    }

    func testStoppingExceptedProvisionalRestoresValidCommittedTrust() async throws {
        try await withPresentationLoop {
            let document = URL(string: "https://trust-fixture.invalid/")!
            let (tab, _) = try await fixture(isPrivate: false, documentURL: document)
            tab.webView(tab.web, didCommit: try XCTUnwrap(fixtureNavigations[tab.id]))
            tab.applyCertificateTrustEvaluation(true, result: .unspecified)
            XCTAssertTrue(tab.certificateTrusted)
            let destination = URL(string: "https://untrusted.invalid/")!
            _ = try await beginReplacement(in: tab, url: destination)
            let raw = try trust(try certificate(), anchored: false, date: .now.addingTimeInterval(60))
            tab.noteCertificateException(host: "untrusted.invalid", port: 443, trust: raw, in: tab.web)
            XCTAssertFalse(tab.certificateTrusted)
            tab.stop()
            XCTAssertTrue(tab.certificateTrusted, "Stop must restore recorded committed trust without evaluating destination trust")
        }
    }

    func testStoppingProvisionalNeverUpgradesExceptedCommittedDocument() async throws {
        try await withPresentationLoop {
            let (tab, _, _, _) = try await approvedDocument()
            _ = try await beginReplacement(in: tab, url: URL(string: "https://newer.invalid/")!)
            tab.stop()
            XCTAssertFalse(tab.certificateTrusted, "Stopping a replacement must preserve the old document's exception provenance")
        }
    }

    func testForgettingCookieCannotUpgradeCopiedProceedInAnotherProfileView() async throws {
        try await withPresentationLoop {
            let (first, original, certificate, document) = try await approvedDocument()
            let cookie = try XCTUnwrap(SecTrustCopyExceptions(original))
            CertificateTrust.forget(host: "trust-fixture.invalid", profileID: first.profileID)
            CertificateTrust.forget(profile: first.profileID)
            CertificateTrust.forgetAll()
            let (second, window) = try await fixture(isPrivate: false, profileID: first.profileID, documentURL: document)
            // Forget revokes reusable authorization, even though native connection
            // state may still carry a copy of the original exception cookie.
            let unapproved = try await answer(try trust(certificate, anchored: false, date: .now.addingTimeInterval(60)),
                                               in: second, window: window, approve: false)
            XCTAssertEqual(unapproved.0, .cancelAuthenticationChallenge)
            XCTAssertEqual(unapproved.1, 1)
            let copied = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
            XCTAssertTrue(SecTrustSetExceptions(copied, cookie))
            let effective = await CertificateTrust.evaluate(copied, host: "trust-fixture.invalid", port: 443)
            XCTAssertTrue(effective.ok)
            XCTAssertEqual(effective.result, .proceed)
            let native = try await answer(copied, in: second, window: window, approve: false)
            XCTAssertEqual(native.0, .performDefaultHandling)
            XCTAssertEqual(native.1, 0)
            second.webView(second.web, didCommit: try XCTUnwrap(fixtureNavigations[second.id]))
            second.applyCertificateTrustEvaluation(effective.ok, result: effective.result, trust: copied)
            await second.evaluateCertificateTrust(in: second.web)
            XCTAssertFalse(second.certificateTrusted, "Erasing reusable cookies must not erase disqualifying session provenance while WebKit can retain copied exceptions")
        }
    }

    func testPrivateDisqualifyingProvenanceSurvivesForgetOnlyInOwningTab() async throws {
        try await withPresentationLoop {
            let certificate = try certificate()
            let (owner, window) = try await fixture(isPrivate: true)
            let raw = try trust(certificate, anchored: false, date: .now.addingTimeInterval(60))
            let approved = try await answer(raw, in: owner, window: window, approve: true)
            XCTAssertEqual(approved.0, .useCredential)
            CertificateTrust.forgetAll()
            let fingerprint = CertificateTrust.fingerprint(certificate)
            XCTAssertTrue(CertificateTrust.hasExceptionProvenance(in: owner, host: "trust-fixture.invalid", port: 443,
                                                                  fingerprint: fingerprint))
            let (otherPrivate, _) = try await fixture(isPrivate: true, profileID: owner.profileID)
            XCTAssertFalse(CertificateTrust.hasExceptionProvenance(in: otherPrivate, host: "trust-fixture.invalid", port: 443,
                                                                   fingerprint: fingerprint))
            let (normal, _) = try await fixture(isPrivate: false, profileID: owner.profileID)
            XCTAssertFalse(CertificateTrust.hasExceptionProvenance(in: normal, host: "trust-fixture.invalid", port: 443,
                                                                   fingerprint: fingerprint), "Private exception history never reaches process/profile provenance")
        }
    }

    private func trust(_ certificate: SecCertificate, anchored: Bool, date: Date) throws -> SecTrust {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let result = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(result, (anchored ? [certificate] : []) as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(result, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetNetworkFetchAllowed(result, false), errSecSuccess)
        XCTAssertEqual(SecTrustSetVerifyDate(result, date as CFDate), errSecSuccess)
        return result
    }

    private func certificate() throws -> SecCertificate {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for arguments in [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=trust-fixture.invalid",
             "-addext", "subjectAltName=DNS:trust-fixture.invalid",
             "-keyout", dir.appendingPathComponent("key.pem").path, "-out", dir.appendingPathComponent("cert.pem").path],
            ["x509", "-in", dir.appendingPathComponent("cert.pem").path, "-outform", "der", "-out", dir.appendingPathComponent("cert.der").path]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        return try XCTUnwrap(SecCertificateCreateWithData(nil,
            Data(contentsOf: dir.appendingPathComponent("cert.der")) as CFData))
    }
}
