import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionConsentTests: XCTestCase {
    func testCancellingInstallationDoesNotRememberTheFolder() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vane-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Consent Fixture","version":"1.0","permissions":["tabs"],"host_permissions":["https://example.com/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        defer {
            ExtensionHost.forget(profile)
            ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
            try? FileManager.default.removeItem(at: folder)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApplication.shared.modalWindow != nil {
                    NSApplication.shared.stopModal(withCode: .alertSecondButtonReturn)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        try await ExtensionHost.host(for: profile).install(folder: folder)
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: profile)).isEmpty,
                      "Cancelled installation must not persist a bookmark before consent")
    }
}

@MainActor final class ExtensionAccessLifecycleTests: XCTestCase {
    private var profiles: [UUID] = []
    private var folders: [URL] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for profile in profiles {
            ExtensionHost.forget(profile)
            for folder in folders {
                ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
                ExtensionConsent.remove(for: folder, profileID: profile)
            }
        }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private func host() -> ExtensionHost {
        let profile = UUID()
        profiles.append(profile)
        return ExtensionHost.host(for: profile)
    }

    private func folder(permissions: [String] = ["tabs"], sites: [String] = ["https://example.com/*"],
                        version: Int = 3) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vane-access-\(UUID())")
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest(folder, permissions: permissions, sites: sites, version: version)
        return folder
    }

    private func manifest(_ folder: URL, permissions: [String], sites: [String], version: Int = 3) throws {
        var value: [String: Any] = ["manifest_version": version, "name": "Access Fixture", "version": "1.0"]
        value["permissions"] = version == 2 ? permissions + sites : permissions
        if version == 3 { value["host_permissions"] = sites }
        try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent("manifest.json"))
    }

    func testDeclineNeverLoadsOrPersistsMV2OrMV3() async throws {
        for version in [2, 3] {
            let host = host(), folder = try folder(version: version)
            let accepted = try await host.load(folder, installing: true) { review in
                XCTAssertEqual(review.requested.permissions, ["tabs"])
                XCTAssertEqual(review.requested.sites, ["https://example.com/*"])
                XCTAssertTrue(host.controller.extensionContexts.isEmpty)
                XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
                return false
            }
            XCTAssertFalse(accepted)
            XCTAssertTrue(host.installed.isEmpty)
            XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: host.profileID))
            XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
        }
    }

    func testApprovedAccessIsGrantedAndRestoredWithoutAnotherPrompt() async throws {
        let host = host(), folder = try folder()
        let accepted = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(Set(context.grantedPermissions.keys.map(\.rawValue)), ["tabs"])
        XCTAssertEqual(Set(context.grantedPermissionMatchPatterns.keys.map(\.string)), ["https://example.com/*"])
        XCTAssertEqual(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).count, 1)
        ExtensionHost.forget(host.profileID)
        let restored = ExtensionHost.host(for: host.profileID)
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApplication.shared.modalWindow != nil {
                    NSApplication.shared.stopModal(withCode: .alertSecondButtonReturn)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while restored.installed.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(restored.installed.count, 1, "An unchanged approval must restore on launch")
        let restoredContext = try XCTUnwrap(restored.installed.first)
        XCTAssertEqual(Set(restoredContext.grantedPermissions.keys.map(\.rawValue)), ["tabs"])
        XCTAssertEqual(Set(restoredContext.grantedPermissionMatchPatterns.keys.map(\.string)), ["https://example.com/*"])
    }

    func testExpandedAccessRequiresApprovalAndDeclinePreservesOldConsent() async throws {
        let host = host(), folder = try folder()
        let old = ExtensionAccess(permissions: ["tabs"], sites: ["https://example.com/*"])
        try ExtensionConsent.save(old, for: folder, profileID: host.profileID)
        try manifest(folder, permissions: ["tabs", "cookies"], sites: ["<all_urls>"])
        let accepted = try await host.load(folder, installing: false) { review in
            XCTAssertEqual(review.previous, old)
            XCTAssertEqual(review.requested.additions(over: old).permissions, ["cookies"])
            XCTAssertEqual(review.requested.additions(over: old).sites, ["<all_urls>"])
            return false
        }
        XCTAssertFalse(accepted)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: host.profileID), old)
        let retry = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(retry)
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: host.profileID)?.sites, ["<all_urls>"])
    }

    func testShrinkingAccessDropsOldGrantsAndReadditionRequiresReview() async throws {
        let host = host(), folder = try folder(permissions: [], sites: [])
        try ExtensionConsent.save(ExtensionAccess(permissions: ["tabs"], sites: ["<all_urls>"]),
                                  for: folder, profileID: host.profileID)
        let accepted = try await host.load(folder, installing: false) { _ in
            XCTFail("Shrinking access does not require review")
            return false
        }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertTrue(context.grantedPermissions.isEmpty)
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty)
        let saved = try XCTUnwrap(ExtensionConsent.saved(for: folder, profileID: host.profileID))
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(ExtensionConsent.Review(name: "Readded", requested: ExtensionAccess(permissions: ["tabs"], sites: []),
                                              previous: saved, installing: false).needsApproval)
    }

    func testLegacyInstallationAndDifferentProfilesNeedTheirOwnConsent() async throws {
        let first = host(), second = host(), folder = try folder()
        _ = try await first.load(folder, installing: true) { _ in true }
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: second.profileID))
        var reviewed = false
        let accepted = try await second.load(folder, installing: false) { review in
            reviewed = true
            XCTAssertNil(review.previous)
            return false
        }
        XCTAssertTrue(reviewed)
        XCTAssertFalse(accepted)
    }

    func testRemovalDeletesConsentAndBookmarksAndReinstallAsksAgain() async throws {
        let host = host(), folder = try folder()
        _ = try await host.load(folder, installing: true) { _ in true }
        host.remove(try XCTUnwrap(host.installed.first))
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: host.profileID))
        var reviewed = false
        _ = try await host.load(folder, installing: true) { review in
            reviewed = true
            XCTAssertNil(review.previous)
            return false
        }
        XCTAssertTrue(reviewed)
    }

    func testProfileDeletionDuringReviewCannotCommitAnInstallation() async throws {
        let host = host(), folder = try folder()
        do {
            _ = try await host.load(folder, installing: true) { _ in
                ExtensionHost.forget(host.profileID)
                return true
            }
            XCTFail("A forgotten host must fail closed")
        } catch is CancellationError { }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: host.profileID))
    }

    func testCancelledTaskCannotStartInstallation() async throws {
        let host = host(), folder = try folder()
        let task = Task {
            try await host.load(folder, installing: true) { _ in
                XCTFail("Cancelled task should not prompt")
                return true
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: host.profileID))
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
    }

    func testInvalidManifestIsNotRememberedAndCanBeRetried() async throws {
        let host = host(), folder = try folder(version: 99)
        do {
            _ = try await host.load(folder, installing: true) { _ in XCTFail("Invalid manifest must not prompt"); return true }
            XCTFail("Invalid manifest must fail")
        } catch is ExtensionHost.Failure { }
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: host.profileID))
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
        try manifest(folder, permissions: ["tabs"], sites: [])
        let retried = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(retried)
    }

    func testContentScriptExpansionIsIncludedInConsent() async throws {
        let host = host(), folder = try folder(permissions: [], sites: [])
        try Data("window.vaneConsentFixture = true".utf8).write(to: folder.appendingPathComponent("script.js"))
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Script Fixture", "version": "1.0",
            "content_scripts": [["matches": ["https://example.com/*"], "js": ["script.js"]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try ExtensionConsent.save(ExtensionAccess(permissions: [], sites: []), for: folder, profileID: host.profileID)
        var reviewed = false
        let accepted = try await host.load(folder, installing: false) { review in
            reviewed = true
            XCTAssertEqual(review.requested.sites, ["https://example.com/*"])
            return false
        }
        XCTAssertTrue(reviewed, "Wider content script injection must require review")
        XCTAssertFalse(accepted)
        XCTAssertTrue(host.installed.isEmpty)
    }

    func testApprovedContentScriptSitesAreGranted() async throws {
        let host = host(), folder = try folder(permissions: [], sites: [])
        try Data("window.vaneConsentFixture = true".utf8).write(to: folder.appendingPathComponent("script.js"))
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Script Fixture", "version": "1.0",
            "content_scripts": [["matches": ["https://example.com/*"], "js": ["script.js"]]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(Set(context.grantedPermissionMatchPatterns.keys.map(\.string)), ["https://example.com/*"])
    }

    func testCorruptConsentRequiresReview() async throws {
        let host = host(), folder = try folder()
        let key = ProfileManager.defaultsKey(ExtensionConsent.baseKey, host.profileID)
        UserDefaults.vane.set([folder.path: Data("corrupt".utf8)], forKey: key)
        var reviewed = false
        let accepted = try await host.load(folder, installing: false) { review in
            reviewed = true
            XCTAssertNil(review.previous)
            return false
        }
        XCTAssertTrue(reviewed)
        XCTAssertFalse(accepted)
        XCTAssertTrue(host.installed.isEmpty)
    }

    func testCancellationDuringReviewCannotPersistAccess() async throws {
        let host = host(), folder = try folder()
        do {
            _ = try await host.load(folder, installing: true) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
            XCTFail("Cancellation during review must fail closed")
        } catch is CancellationError { }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: host.profileID))
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: host.profileID)).isEmpty)
    }

    func testIncognitoCannotInstallExtensions() async throws {
        let host = ExtensionHost.host(for: Profile.incognito.id), folder = try folder()
        do {
            _ = try await host.load(folder, installing: true) { _ in XCTFail("Private installation must not prompt"); return true }
            XCTFail("Private installation must fail closed")
        } catch is CancellationError { }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: Profile.incognito.id))
    }

    func testOptionalAccessIsNotAutomaticallyGranted() async throws {
        let host = host(), folder = try folder(permissions: [], sites: [])
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Optional Fixture", "version": "1.0",
                                      "optional_permissions": ["cookies"], "optional_host_permissions": ["<all_urls>"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let accepted = try await host.load(folder, installing: true) { review in
            XCTAssertTrue(review.requested.isEmpty)
            return true
        }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertTrue(context.grantedPermissions.isEmpty)
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty)
    }

    func testReviewShowsNewAndFullAccessAndExplicitEmptyAccess() throws {
        let old = ExtensionAccess(permissions: ["tabs"], sites: ["https://example.com/*"])
        let review = ExtensionConsent.Review(name: "Fixture", requested: ExtensionAccess(permissions: ["tabs", "cookies"], sites: ["<all_urls>"]),
                                             previous: old, installing: false)
        let alert = ExtensionConsent.makePrompt(review)
        let scroll = try XCTUnwrap(alert.accessoryView as? NSScrollView)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertTrue(text.string.contains("New access"))
        XCTAssertTrue(text.string.contains("All websites (<all_urls>)"))
        XCTAssertTrue(text.string.contains("All requested access"))
        XCTAssertTrue(text.string.contains("tabs"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Allow and Enable", "Don’t Allow"])
        XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
        XCTAssertTrue(ExtensionAccess(permissions: [], sites: []).description.contains("None requested"))
    }
}
