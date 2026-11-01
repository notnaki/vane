import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionBackgroundStartupTests: XCTestCase {
    private var profile: UUID!
    private var ownedProfiles = Set<UUID>()
    private var folder: URL!
    private weak var probe: WKWebView?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        ownedProfiles.insert(profile)
        folder = Store.directory.appendingPathComponent("background-startup-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ExtensionHost.forget(profile)
        for key in [ExtensionHost.baseKey, ExtensionHost.identifiersKey, ExtensionHost.namesKey,
                    ExtensionHost.disabledKey, ExtensionHost.bookmarksKey, ExtensionConsent.baseKey, ExtensionPins.key] {
            UserDefaults.vane.removeObject(forKey: ProfileManager.defaultsKey(key, profile))
        }
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        try? ExtensionCodeStore.removeProfile(profile)
        try? FileManager.default.removeItem(at: folder)
        let released = ownedProfiles
        ownedProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(released)
    }

    private func writeWorker(_ script: String, version: String = "1.0", worker: String = "bg.js", optionalPermissions: [String] = [], in destination: URL? = nil) throws {
        let target = destination ?? folder!
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Throwing worker", "description": "repro",
            "version": version, "background": ["service_worker": worker]]
        if !optionalPermissions.isEmpty { manifest["optional_permissions"] = optionalPermissions }
        try JSONSerialization.data(withJSONObject: manifest).write(to: target.appendingPathComponent("manifest.json"))
        try Data(script.utf8).write(to: target.appendingPathComponent(worker))
    }

    // Removing the bounded callback bridge leaves this task suspended even after
    // cancellation, and retains both the candidate context and its private revision.
    func testThrowingWorkerInstallFinishesAndDiscardsCandidate() async throws {
        try writeWorker("chrome.runtime.onUpdateAvailable.addListener(() => {});")
        let host = ExtensionHost.host(for: profile)
        let finished = expectation(description: "Throwing worker reports startup failure")
        let install = Task {
            defer { finished.fulfill() }
            do { _ = try await host.load(folder, installing: true) { _ in true }; XCTFail("Throwing worker must fail") }
            catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("background"), error.localizedDescription) }
        }
        await fulfillment(of: [finished], timeout: 8)
        install.cancel()
        XCTAssertFalse(host.isBusy)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        let store = ExtensionCodeStore(profileID: profile)
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("revisions").path).isEmpty)
    }

    func testEscapedIdentifierPreservesClassicStrictFailure() async throws {
        // ASI makes this a strict directive followed by the identifier "infoo".
        // Treating its raw "in" prefix as an operator disables strict mode.
        try writeWorker("'use strict'\n" + #"in\u0066oo = 1;"# + "\nchrome.runtime.onInstalled.addListener(() => {});")
        let host = ExtensionHost.host(for: profile)
        let finished = expectation(description: "Strict vendor script reports its undeclared assignment")
        let install = Task {
            defer { finished.fulfill() }
            do { _ = try await host.load(folder, installing: true) { _ in true }; XCTFail("Vendor strict mode must remain active") }
            catch { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("background"), error.localizedDescription) }
        }
        await fulfillment(of: [finished], timeout: 8)
        install.cancel()
        XCTAssertFalse(host.isBusy)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        XCTAssertTrue(try ExtensionCodeStore(profileID: profile).records().isEmpty)
    }

    func testValidWorkerInstallAndRestoreComplete() async throws {
        try writeWorker("chrome.runtime.onInstalled.addListener(() => {});")
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let original = try XCTUnwrap(host.installed.first)
        let identity = original.uniqueIdentifier
        ExtensionHost.forget(profile)
        let again = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(8)
        while again.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(again.isBusy)
        XCTAssertEqual(again.installed.first?.uniqueIdentifier, identity)
        XCTAssertNil(again.entries.first?.failure)
    }

    func testPageScriptErrorDoesNotRejectWorkingBackgroundAndPopup() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await exercisePageScriptError() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Background fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exercisePageScriptError() async throws {
        let nonce = UUID().uuidString
        let manifest: [String: Any] = ["manifest_version": 2, "name": "Page with optional feature error",
            "description": "Runtime diagnostics are distinct from a failed background load", "version": "1.0",
            "background": ["page": "background.html", "persistent": true],
            "browser_action": ["default_popup": "popup.html"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<script src='background.js'></script>".utf8).write(to: folder.appendingPathComponent("background.html"))
        try Data("""
            browser.runtime.onMessage.addListener(() => Promise.resolve('\(nonce)'));
            throw new Error('Optional notification feature is unsupported');
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("<script src='popup.js'></script>".utf8).write(to: folder.appendingPathComponent("popup.html"))
        try Data("browser.runtime.sendMessage({}).then(value => window.reply = value);".utf8)
            .write(to: folder.appendingPathComponent("popup.js"))
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        let action = try XCTUnwrap(context.action(for: nil))
        defer { action.closePopup() }
        let web = try XCTUnwrap(action.popupWebView)
        let deadline = ContinuousClock.now + .seconds(5)
        var reply: String?
        while ContinuousClock.now < deadline {
            reply = try? await web.evaluateJavaScript("window.reply") as? String
            if reply == nonce { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reply, nonce, "The background must actually service the new popup's message")
        XCTAssertTrue(context.isLoaded)
        // Older supported engines do not report page script errors in this array.
        // Every diagnostic they do report must remain visible after activation.
        let entry = try XCTUnwrap(host.entries.first)
        for error in context.errors {
            let value = error as NSError
            if value.domain == WKWebExtensionContext.errorDomain && value.code == 7 {
                XCTAssertTrue(entry.runtimeDiagnostics?.contains(error.localizedDescription) == true,
                              "Runtime diagnostics remain visible without suggesting a broken update")
            } else {
                XCTAssertTrue(entry.failure?.contains(error.localizedDescription) == true,
                              "Other reported errors must still need attention")
            }
        }
        if ExtensionDiagnostics.blockingErrors(context.errors, manifest: context.webExtension.manifest).isEmpty {
            XCTAssertNil(entry.failure)
            XCTAssertEqual(entry.status, "Enabled")
        }
    }

    func testOnlyReportedRuntimeScriptErrorsAreNonblocking() {
        let script = NSError(domain: WKWebExtensionContext.errorDomain, code: 7,
                             userInfo: [NSLocalizedDescriptionKey: "Optional feature threw"])
        let failedLoad = NSError(domain: WKWebExtensionContext.errorDomain,
                                 code: WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue)
        let unknownContext = NSError(domain: WKWebExtensionContext.errorDomain, code: 8)
        let differentDomain = NSError(domain: WKWebExtension.errorDomain, code: 7)
        let blocking = ExtensionDiagnostics.blockingErrors([script, failedLoad, unknownContext, differentDomain],
                                                          manifest: ["description": "Error classification fixture"])
        XCTAssertEqual(blocking.map { ($0 as NSError).code }, [failedLoad.code, unknownContext.code, differentDomain.code])
        XCTAssertEqual(blocking.map { ($0 as NSError).domain }, [failedLoad.domain, unknownContext.domain, differentDomain.domain])
        let displayed = ExtensionDiagnostics.displayErrors([script, failedLoad, unknownContext, differentDomain],
                                                          manifest: ["description": "Error classification fixture"])
        XCTAssertEqual(displayed.count, 4, "Activation policy must retain runtime diagnostics for display")
        XCTAssertEqual(displayed.first?.localizedDescription, script.localizedDescription)
        let runtime = ExtensionDiagnostics.runtimeErrors([script, failedLoad, unknownContext, differentDomain],
                                                        manifest: ["description": "Error classification fixture"])
        XCTAssertEqual(runtime.count, 1)
        XCTAssertEqual(runtime.first?.localizedDescription, script.localizedDescription)
    }

    func testThrowingAcceptedWorkerRestoreLeavesVisibleFailureAndRetainsAcceptedCode() async throws {
        try writeWorker("chrome.runtime.onInstalled.addListener(() => {});")
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        ExtensionHost.forget(profile)
        let store = ExtensionCodeStore(profileID: profile)
        let record = try XCTUnwrap(store.records()[folder.path])
        try writeWorker("chrome.runtime.onUpdateAvailable.addListener(() => {});", in: store.code(for: record))
        let again = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(8)
        while again.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(again.isBusy)
        XCTAssertTrue(again.installed.isEmpty)
        XCTAssertTrue(again.controller.extensionContexts.isEmpty)
        XCTAssertTrue(again.entries.first?.failure?.localizedCaseInsensitiveContains("background") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.code(for: record).path))
        XCTAssertEqual(try store.records()[folder.path]?.revision, record.revision)
    }
}

extension ExtensionBackgroundStartupTests {
    func testLaunchSweepsOnlyUnreferencedInactiveRevisionsForThisProfile() throws {
        let store = ExtensionCodeStore(profileID: profile)
        let active = try store.stage(folder)
        var accepted: ExtensionCodeStore.Record!
        var orphanURL: URL!
        do {
            let stage = try store.stage(folder)
            accepted = .init(identity: UUID().uuidString, revision: stage.revision, sourcePath: folder.path,
                name: "Accepted", version: "1", summary: "", required: .init(permissions: [], sites: []),
                optional: .init(permissions: [], sites: []), compatibility: [])
            let orphan = try store.stage(folder)
            orphanURL = orphan.url
        }
        try store.save([folder.path: accepted])
        UserDefaults.vane.set([folder.path], forKey: ProfileManager.defaultsKey(ExtensionHost.disabledKey, profile))
        let unknown = store.root.appendingPathComponent("revisions/unknown-data")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let other = ExtensionCodeStore(profileID: UUID(), directory: Store.directory)
        let otherStage = try other.stage(folder)
        defer { try? FileManager.default.removeItem(at: other.root) }
        let host = ExtensionHost.host(for: profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.code(for: accepted).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherStage.url.path))
        XCTAssertEqual(host.entries.count, 1)
        withExtendedLifetime((active, otherStage)) { }
    }
}

extension ExtensionBackgroundStartupTests {
    func testThrowingWorkerUpdateFinishesAndRetainsAcceptedVersion() async throws {
        try await assertThrowingUpdate(version: "1.0")
    }

    func testVersionBumpedThrowingWorkerUpdateFinishesAndRetainsAcceptedVersion() async throws {
        try await assertThrowingUpdate(version: "2.0")
    }

    private func workerIdentity(_ context: WKWebExtensionContext) async throws -> [String: String] {
        let web = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        probe = web
        defer {
            web.stopLoading()
            let close = Selector(("_close"))
            if web.responds(to: close) { web.perform(close) }
            else { web.loadHTMLString("", baseURL: nil) }
        }
        web.load(URLRequest(url: context.baseURL.appendingPathComponent("probe.html")))
        let deadline = ContinuousClock.now + .seconds(2)
        while web.title != "Worker probe", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        var identity: [String: String]?
        try await ExtensionBackgroundStartup.wait(timeout: .seconds(2), start: { completion in
            web.callAsyncJavaScript("return await browser.runtime.sendMessage('startup-identity')", arguments: [:], in: nil, in: .page) { result in
                do { identity = try result.get() as? [String: String]; completion(nil) }
                catch { completion(error) }
            }
        }, check: {})
        return try XCTUnwrap(identity)
    }

    private func assertThrowingUpdate(version: String) async throws {
        try writeWorker("""
            const startupVersion = chrome.runtime.getManifest().version;
            chrome.runtime.onMessage.addListener((message, sender, reply) => reply({marker:'accepted-worker', version:startupVersion, currentVersion:chrome.runtime.getManifest().version}));
            chrome.runtime.onInstalled.addListener(() => {});
            """, optionalPermissions: ["tabs"])
        try Data("<title>Worker probe</title>".utf8).write(to: folder.appendingPathComponent("probe.html"))
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let identity = try XCTUnwrap(host.installed.first?.uniqueIdentifier)
        let originalContext = try XCTUnwrap(host.installed.first)
        originalContext.setPermissionStatus(.grantedExplicitly, for: .tabs)
        XCTAssertNotNil(originalContext.grantedPermissions[.tabs])
        let originalWorker = try await workerIdentity(originalContext)
        XCTAssertEqual(originalWorker, ["marker": "accepted-worker", "version": "1.0", "currentVersion": "1.0"])
        let probeDeadline = ContinuousClock.now + .seconds(2)
        while probe != nil, ContinuousClock.now < probeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(probe, "The identity probe must close before exercising worker-only update startup")
        let store = ExtensionCodeStore(profileID: profile)
        let accepted = try XCTUnwrap(store.records()[folder.path])
        let acceptedBytes = try Data(contentsOf: store.code(for: accepted).appendingPathComponent("bg.js"))
        try writeWorker("chrome.runtime.onUpdateAvailable.addListener(() => {});", version: version, optionalPermissions: ["tabs"])
        let finished = expectation(description: "Throwing update reports failure")
        var failure: String?
        let update = Task {
            defer { finished.fulfill() }
            do { _ = try await host.refresh(folder.path) { _ in true }; XCTFail("Throwing update must fail") }
            catch {
                failure = error.localizedDescription
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("background"), error.localizedDescription)
            }
        }
        await fulfillment(of: [finished], timeout: 8)
        update.cancel()
        XCTAssertNotNil(failure)
        XCTAssertFalse(host.isBusy)
        if let context = host.installed.first {
            XCTAssertEqual(context.uniqueIdentifier, identity)
            XCTAssertEqual(host.controller.extensionContexts.count, 1)
            let recoveredWorker = try await workerIdentity(context)
            XCTAssertEqual(recoveredWorker, originalWorker, "Successful recovery must execute the original accepted worker")
        } else {
            // Some WebKit versions fail to inject extension APIs when a worker
            // reconnects in another process (WebKit bug 324754). Recovery remains
            // bounded and explicit; it must never accept the failed candidate.
            XCTAssertTrue(host.controller.extensionContexts.isEmpty)
            XCTAssertTrue(host.entries.first?.failure?.contains("accepted version could not be restarted") == true)
            XCTAssertTrue(host.entries.first?.failure?.localizedCaseInsensitiveContains("background") == true)
        }
        XCTAssertNil(host.installed.first?.grantedPermissions[.tabs], "Context reload must end additional runtime grants")
        XCTAssertEqual(try store.records()[folder.path]?.revision, accepted.revision, failure ?? "Missing startup failure")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("revisions").path), [accepted.revision])
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: profile), accepted.required)
        // A new controller in the same process may still encounter WebKit's stale
        // worker connection. Both outcomes must finish without changing accepted
        // bytes; when startup succeeds it must execute the verified old worker.
        ExtensionHost.forget(profile)
        let fresh = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(8)
        while fresh.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(fresh.isBusy)
        if let restored = fresh.installed.first {
            XCTAssertEqual(restored.uniqueIdentifier, identity)
            XCTAssertNil(restored.grantedPermissions[.tabs])
            let freshWorker = try await workerIdentity(restored)
            XCTAssertEqual(freshWorker, originalWorker)
        } else {
            XCTAssertTrue(fresh.controller.extensionContexts.isEmpty)
            XCTAssertTrue(fresh.entries.first?.failure?.localizedCaseInsensitiveContains("background") == true)
        }
        XCTAssertEqual(try store.records()[folder.path]?.identity.lowercased(), identity)
        XCTAssertEqual(try store.records()[folder.path]?.revision, accepted.revision)
        XCTAssertEqual(try Data(contentsOf: store.code(for: accepted).appendingPathComponent("bg.js")), acceptedBytes)
    }
}

extension ExtensionBackgroundStartupTests {
    func testLaunchPreservesRevisionsWhenIndexIsMissingCorruptOrRetainedForRecovery() throws {
        let store = ExtensionCodeStore(profileID: profile)
        let index = store.root.appendingPathComponent("installations.json")
        var orphan: URL!
        do { orphan = try store.stage(folder).url }
        for state in ["missing", "corrupt", "recovery"] {
            ExtensionHost.forget(profile)
            try? FileManager.default.removeItem(at: index)
            if state == "corrupt" { try Data("broken".utf8).write(to: index) }
            if state == "recovery" {
                try store.save([:])
                try Data("unknown prior references".utf8).write(to: store.root.appendingPathComponent("metadata-recovery-" + UUID().uuidString))
            }
            _ = ExtensionHost.host(for: profile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), state)
        }
    }

    func testLaunchSweepDoesNotFollowRevisionSymlinks() throws {
        let store = ExtensionCodeStore(profileID: profile)
        try store.save([:])
        let revisions = store.root.appendingPathComponent("revisions")
        let outside = folder.appendingPathComponent("keep.js")
        try Data("keep".utf8).write(to: outside)
        let linked = revisions.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: folder)
        _ = ExtensionHost.host(for: profile)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path), folder.path)
        ExtensionHost.forget(profile)
        try FileManager.default.removeItem(at: revisions)
        try FileManager.default.createSymbolicLink(at: revisions, withDestinationURL: folder)
        _ = ExtensionHost.host(for: profile)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }
}

extension ExtensionBackgroundStartupTests {
    func testLaunchClearsCrashStageBeforeAnyInstallationWasAccepted() throws {
        let store = ExtensionCodeStore(profileID: profile)
        var orphan: URL!
        do { orphan = try store.stage(folder).url }
        _ = ExtensionHost.host(for: profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}

@MainActor final class ExtensionBackgroundWatchdogTests: XCTestCase {
    // The external operation deliberately never cooperates. A task-group timeout
    // would still wait for that child and fail to finish this test.
    func testNeverCallingCompletionTimesOutAndLateCallbacksAreHarmless() async throws {
        var callback: (@MainActor @Sendable (Error?) -> Void)?
        let finished = expectation(description: "Deadline does not wait for WebKit callback")
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await ExtensionBackgroundStartup.wait(timeout: .milliseconds(30), pollInterval: .milliseconds(5),
                    start: { callback = $0 }, check: {})
                XCTFail("Missing callback must time out")
            } catch { XCTAssertTrue(error.localizedDescription.contains("background")) }
        }
        await fulfillment(of: [finished], timeout: 1)
        task.cancel()
        callback?(nil)
        callback?(ExtensionHost.Failure("Late failure"))
    }

    func testCancellingNeverCallingCompletionFinishesImmediately() async throws {
        var callback: (@MainActor @Sendable (Error?) -> Void)?
        let started = expectation(description: "External operation started")
        let finished = expectation(description: "Cancellation finishes without a callback")
        let task = Task {
            defer { finished.fulfill() }
            do {
                try await ExtensionBackgroundStartup.wait(start: { callback = $0; started.fulfill() }, check: {})
                XCTFail("Cancelled startup must not succeed")
            } catch is CancellationError { }
            catch { XCTFail("Expected cancellation, got \(error)") }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [finished], timeout: 1)
        callback?(nil)
        callback?(ExtensionHost.Failure("Late failure"))
    }

    func testReportedFailureWinsWithoutCompletion() async throws {
        let failure = NSError(domain: WKWebExtensionContext.errorDomain,
            code: WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue)
        var reported = false
        do {
            try await ExtensionBackgroundStartup.wait(timeout: .seconds(1), pollInterval: .milliseconds(5),
                start: { _ in reported = true }, check: { if reported { throw failure } })
            XCTFail("Reported startup failure must be surfaced")
        } catch { XCTAssertEqual(error as NSError, failure) }
    }

    func testSynchronousAndRepeatedCompletionFinishesOnce() async throws {
        try await ExtensionBackgroundStartup.wait(start: { completion in
            completion(nil)
            completion(ExtensionHost.Failure("Repeated callback"))
            completion(nil)
        }, check: {})
    }

    func testTimedOutCallbackDoesNotRetainValidationResources() async throws {
        final class Resource { }
        weak var released: Resource?
        var callback: (@MainActor @Sendable (Error?) -> Void)?
        do {
            let resource = Resource()
            released = resource
            do {
                try await ExtensionBackgroundStartup.wait(timeout: .milliseconds(20), pollInterval: .milliseconds(5),
                    start: { callback = $0 }, check: { withExtendedLifetime(resource) {} })
                XCTFail("Missing callback must time out")
            } catch { }
        }
        await Task.yield()
        XCTAssertNil(released, "A late framework callback must not retain the context validation closure")
        callback?(nil)
    }
}

extension ExtensionBackgroundWatchdogTests {
    func testInvalidatedLifetimeCancelsWithoutCallback() async throws {
        var invalidated = false
        do {
            try await ExtensionBackgroundStartup.wait(start: { _ in invalidated = true }, check: {
                if invalidated { throw CancellationError() }
            })
            XCTFail("Removed or disabled installation must stop waiting")
        } catch is CancellationError { }
    }
}

extension ExtensionBackgroundWatchdogTests {
    func testCallbackFailureIsSurfaced() async throws {
        for failure in [NSError(domain: "Startup callback", code: 1),
                        NSError(domain: WKWebExtensionContext.errorDomain, code: 6),
                        NSError(domain: WKWebExtensionContext.errorDomain, code: 7)] {
            do {
                try await ExtensionBackgroundStartup.wait(start: { $0(failure) }, check: {})
                XCTFail("A callback error must fail startup: \(failure)")
            } catch { XCTAssertEqual(error as NSError, failure) }
        }
    }

    func testAlreadyCancelledStartupNeverCallsWebKit() async throws {
        var started = false
        let task = Task {
            try await ExtensionBackgroundStartup.wait(start: { started = true; $0(nil) }, check: {})
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled startup must not succeed") }
        catch is CancellationError { }
        XCTAssertFalse(started)
    }
}
