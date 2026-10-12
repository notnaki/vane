import AppKit
import Combine
import Darwin
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionManagedCodeTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("accepted-code-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write()
    }

    override func tearDown() async throws {
        let host = ExtensionHost.host(for: profile)
        for entry in host.entries { try? host.remove(folder: entry.path) }
        ExtensionHost.forget(profile)
        for key in [ExtensionHost.baseKey, ExtensionHost.identifiersKey, ExtensionHost.namesKey,
                    ExtensionHost.disabledKey, ExtensionHost.bookmarksKey, ExtensionConsent.baseKey, ExtensionPins.key] {
            UserDefaults.vane.removeObject(forKey: ProfileManager.defaultsKey(key, profile))
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(version: String = "1.0", permissions: [String] = ["storage"], script: String = "globalThis.acceptedCode='accepted'") throws {
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Accepted Code Fixture", "version": version,
            "description": "An accepted-code regression", "permissions": permissions,
            "options_ui": ["page": "options.html"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Accepted code</title><script src='options.js'></script>".utf8).write(to: folder.appendingPathComponent("options.html"))
        try Data(script.utf8).write(to: folder.appendingPathComponent("options.js"))
    }

    private func install() async throws -> (ExtensionHost, WKWebExtensionContext) {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        return (host, try XCTUnwrap(host.installed.first))
    }

    private func restored() async throws -> ExtensionHost {
        ExtensionHost.forget(profile)
        let host = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(5)
        while host.entries.contains(where: \.busy) {
            if ContinuousClock.now >= deadline { XCTFail("Restore did not finish"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return host
    }

    private func options(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        web.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        let deadline = ContinuousClock.now + .seconds(5)
        while web.isLoading || web.title != "Accepted code" {
            if ContinuousClock.now >= deadline { throw ExtensionHost.Failure("Options fixture timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return web
    }

    func testSourceEditsDoNotApplyOnRestore() async throws {
        let (_, original) = try await install()
        let identity = original.uniqueIdentifier
        ExtensionHost.forget(profile)
        try write(version: "2.0", script: "globalThis.acceptedCode='unreviewed'")
        let host = try await restored()
        let current = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(current.uniqueIdentifier, identity)
        XCTAssertEqual(current.webExtension.version, "1.0")
        let value = try await options(current).evaluateJavaScript("globalThis.acceptedCode")
        XCTAssertEqual(value as? String, "accepted")
    }

    func testMissingSourceDoesNotBreakAcceptedCode() async throws {
        let (_, original) = try await install()
        let identity = original.uniqueIdentifier
        ExtensionHost.forget(profile)
        try FileManager.default.removeItem(at: folder)
        let host = try await restored()
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        XCTAssertEqual(host.entries.count, 1)
    }

    func testDeclinedExpandedUpdateKeepsWorkingContextAndApproval() async throws {
        let (host, old) = try await install()
        let approval = ExtensionConsent.saved(for: folder, profileID: profile)
        try write(version: "2.0", permissions: ["storage", "cookies"])
        let accepted = try await host.refresh(folder.path) { _ in false }
        XCTAssertFalse(accepted)
        XCTAssertTrue(old.isLoaded)
        XCTAssertTrue(host.installed.first === old)
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: profile), approval)
        XCTAssertEqual(host.installed.first?.webExtension.version, "1.0")
    }

    func testBrokenUpdateKeepsAcceptedCodeThroughRestore() async throws {
        let (host, old) = try await install()
        let identity = old.uniqueIdentifier
        try Data("not json".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        do { _ = try await host.refresh(folder.path) { _ in XCTFail("Invalid code cannot reach review"); return true }; XCTFail("Invalid update must fail") }
        catch { }
        XCTAssertTrue(old.isLoaded)
        let again = try await restored()
        XCTAssertEqual(again.installed.first?.uniqueIdentifier, identity)
        XCTAssertEqual(again.installed.first?.webExtension.version, "1.0")
    }

    func testSourceResourceMutationDuringReviewCannotChangeAcceptedBytes() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in
            try! Data("globalThis.acceptedCode='unreviewed'".utf8).write(to: self.folder.appendingPathComponent("options.js"))
            return true
        }
        let web = try await options(XCTUnwrap(host.installed.first))
        let value = try await web.evaluateJavaScript("globalThis.acceptedCode")
        XCTAssertEqual(value as? String, "accepted")
    }

    func testUpdatingDisabledInstallationPreservesDisabledState() async throws {
        let (host, _) = try await install()
        try host.disable(folder.path)
        try write(version: "2.0")
        _ = try await host.refresh(folder.path) { _ in true }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertEqual(host.entries.first?.status, "Disabled")
        let again = try await restored()
        XCTAssertTrue(again.installed.isEmpty)
    }
    func testCopyDiagnosticsExcludesSensitiveFailureAndSourceData() throws {
        let host = ExtensionHost.host(for: profile)
        let entry = ExtensionHost.Entry(path: "/Users/private-user/secret-folder", name: "Fixture", context: nil,
            status: "Needs attention", failure: "https://user:private-credential-716@example.test/private?q=token — secret-content", busy: false)
        let report = host.diagnostic(for: entry)
        for secret in ["private-user", "secret-folder", "private-credential-716", "example.test", "token", "secret-content"] {
            XCTAssertFalse(report.contains(secret), "Diagnostic leaked \(secret)")
        }
        XCTAssertTrue(report.contains("macOS"))
        XCTAssertTrue(report.contains("Vane"))
    }

}

extension ExtensionManagedCodeTests {
    func testValidUpdateAndRestartPreserveActualExtensionStorageAndIdentity() async throws {
        let (host, context) = try await install()
        let identity = context.uniqueIdentifier
        var web: WKWebView? = try await options(context)
        _ = try await web!.callAsyncJavaScript("await browser.storage.local.set({fixture:'kept'}); return true", arguments: [:], in: nil, contentWorld: .page)
        web = nil
        try write(version: "2.0")
        var reviews = 0
        _ = try await host.refresh(folder.path) { review in
            reviews += 1
            XCTAssertTrue(review.updating)
            XCTAssertEqual(review.currentVersion, "1.0")
            XCTAssertEqual(review.candidateVersion, "2.0")
            return true
        }
        XCTAssertEqual(reviews, 1, "Same-access code updates still require review")
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        web = try await options(XCTUnwrap(host.installed.first))
        var value = try await web!.callAsyncJavaScript("return (await browser.storage.local.get('fixture')).fixture", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(value as? String, "kept")
        web = nil
        let again = try await restored()
        web = try await options(XCTUnwrap(again.installed.first))
        value = try await web!.callAsyncJavaScript("return (await browser.storage.local.get('fixture')).fixture", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(value as? String, "kept")
    }

    func testLegacyMigrationPreservesUUIDApprovalPinsAndDisabledState() async throws {
        let identity = UUID().uuidString
        XCTAssertTrue(ScopedPaths.add(folder, to: ExtensionHost.key(for: profile)))
        UserDefaults.vane.set([folder.path: identity], forKey: ProfileManager.defaultsKey(ExtensionHost.identifiersKey, profile))
        UserDefaults.vane.set([folder.path: "Legacy"], forKey: ProfileManager.defaultsKey(ExtensionHost.namesKey, profile))
        UserDefaults.vane.set([folder.path], forKey: ProfileManager.defaultsKey(ExtensionHost.disabledKey, profile))
        UserDefaults.vane.set([folder.path], forKey: ProfileManager.defaultsKey(ExtensionPins.key, profile))
        try ExtensionConsent.save(ExtensionAccess(permissions: ["storage"], sites: []), for: folder, profileID: profile)
        let host = ExtensionHost.host(for: profile)
        XCTAssertFalse(host.entries.first?.managed ?? true)
        XCTAssertTrue(host.installed.isEmpty)
        try await host.setEnabled(true, for: folder.path) { review in
            XCTAssertTrue(review.updating)
            return true
        }
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity.lowercased())
        XCTAssertTrue(host.entries.first?.managed ?? false)
        XCTAssertEqual(host.pins, [folder.path])
        let record = try XCTUnwrap(ExtensionCodeStore(profileID: profile).records()[folder.path])
        XCTAssertEqual(record.identity.lowercased(), identity.lowercased())
        XCTAssertEqual(record.required, ExtensionConsent.saved(for: folder, profileID: profile))
    }

    func testNewlyIntegratedMenuAccessRequiresApprovalBeforeActivation() async throws {
        try write(permissions: ["storage", "contextMenus"])
        let (host, _) = try await install()
        try host.disable(folder.path)
        let store = ExtensionCodeStore(profileID: profile)
        var records = try store.records()
        records[folder.path]?.integratedCapabilities = nil // metadata from before native menu integration
        try store.save(records)
        let again = try await restored()
        var reviews = 0
        try await again.setEnabled(true, for: folder.path) { review in
            reviews += 1
            XCTAssertEqual(review.newlySupportedCapabilities, ["contextMenus"])
            return false
        }
        XCTAssertEqual(reviews, 1)
        XCTAssertTrue(again.installed.isEmpty)
        try await again.setEnabled(true, for: folder.path) { _ in true }
        XCTAssertEqual(again.installed.count, 1)
        XCTAssertEqual(try store.records()[folder.path]?.integratedCapabilities, ["contextMenus"])
    }

    func testFailedIndexCommitRestartsAcceptedVersionWithoutChangingApproval() async throws {
        let (host, old) = try await install()
        let identity = old.uniqueIdentifier
        let store = ExtensionCodeStore(profileID: profile)
        let index = store.root.appendingPathComponent("installations.json")
        let savedIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: index); try? savedIndex.write(to: index) }
        try write(version: "2.0", permissions: ["storage", "cookies"])
        do { _ = try await host.refresh(folder.path) { _ in true }; XCTFail("Index commit should fail") }
        catch { }
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        XCTAssertEqual(host.installed.first?.webExtension.version, "1.0")
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: profile)?.permissions, ["storage"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("revisions").path).count, 1)
    }
    func testCancellingOnlyUpdateTaskRecoversAcceptedVersion() async throws {
        let (host, old) = try await install()
        let identity = old.uniqueIdentifier
        try write(version: "2.0")
        var update: Task<Bool, Error>?
        let observation = host.$loaded.sink { loaded in
            if loaded.isEmpty { update?.cancel() }
        }
        update = Task { try await host.refresh(self.folder.path) { _ in true } }
        do { _ = try await update!.value; XCTFail("Update was cancelled") }
        catch is CancellationError { }
        withExtendedLifetime(observation) { }
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        XCTAssertEqual(host.installed.first?.webExtension.version, "1.0")
        XCTAssertEqual(host.controller.extensionContexts.count, 1)
    }

    func testMissingManagedIndexCannotSilentlyExecuteChangedSource() async throws {
        _ = try await install()
        ExtensionHost.forget(profile)
        try FileManager.default.removeItem(at: ExtensionCodeStore(profileID: profile).root.appendingPathComponent("installations.json"))
        try write(version: "2.0", script: "globalThis.acceptedCode='unreviewed'")
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApp.modalWindow != nil { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let host = try await restored()
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertNotNil(host.entries.first?.failure)
    }

    func testCorruptMetadataFailsClosedAndReviewedRepairPreservesIdentity() async throws {
        let (_, old) = try await install()
        let identity = old.uniqueIdentifier
        ExtensionHost.forget(profile)
        let store = ExtensionCodeStore(profileID: profile)
        try Data("broken metadata".utf8).write(to: store.root.appendingPathComponent("installations.json"))
        let host = try await restored()
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertNotNil(host.entries.first?.failure)
        var reviews = 0
        _ = try await host.refresh(folder.path) { review in
            reviews += 1
            XCTAssertTrue(review.updating)
            return true
        }
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix("metadata-recovery-") })
        XCTAssertNil(host.entries.first?.failure)
    }

    func testManifestFIFOIsRejectedWithoutBlockingLegacyMetadataRead() throws {
        let manifest = folder.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        XCTAssertEqual(mkfifo(manifest.path, 0o600), 0)
        XCTAssertThrowsError(try ExtensionHost.readManifest(folder))
    }

}
