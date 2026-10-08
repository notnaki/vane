import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionManagementTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("management-extension-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folder = URL(fileURLWithPath: folder.path).resolvingSymlinksInPath()
        try writeManifest()
    }

    override func tearDown() async throws {
        ExtensionHost.forget(profile)
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        ExtensionConsent.remove(for: folder, profileID: profile)
        for key in [ExtensionHost.identifiersKey, ExtensionHost.namesKey, ExtensionHost.disabledKey] {
            UserDefaults.vane.removeObject(forKey: ProfileManager.defaultsKey(key, profile))
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeManifest(extra: [String: Any] = [:]) throws {
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Management Fixture", "version": "1.0", "permissions": ["storage"]]
        manifest.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    func testMissingContentScriptFailsBeforeConsentOrActivation() async throws {
        try writeManifest(extra: ["content_scripts": [["matches": ["https://example.test/*"], "js": ["missing.js"]]]])
        let host = ExtensionHost.host(for: profile)
        do {
            _ = try await host.load(folder, installing: true) { _ in
                XCTFail("A missing script must be diagnosed before consent")
                return true
            }
            XCTFail("An extension with missing code must not activate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("missing.js"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("missing or unreadable"), error.localizedDescription)
        }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: profile))
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: profile)).isEmpty)
    }

    func testInvalidManifestEntryFailsBeforeConsent() async throws {
        try writeManifest(extra: ["background": ["service_worker": 7]])
        let host = ExtensionHost.host(for: profile)
        do {
            _ = try await host.load(folder, installing: true) { _ in XCTFail("Parse errors must not prompt"); return true }
            XCTFail("Invalid background must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("background"), error.localizedDescription)
        }
        XCTAssertTrue(host.installed.isEmpty)
    }
    private func install() async throws -> (ExtensionHost, WKWebExtensionContext) {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        return (host, try XCTUnwrap(host.installed.first))
    }

    func testBrokenUpdateStopsCodeAndPreservesRecoverableConfiguration() async throws {
        let (host, old) = try await install()
        let identity = old.uniqueIdentifier
        host.togglePin(old)
        let consent = ExtensionConsent.saved(for: folder, profileID: profile)
        try writeManifest(extra: ["content_scripts": [["matches": ["https://example.test/*"], "js": ["missing.js"]]]])
        do {
            _ = try await host.refresh(folder.path) { _ in XCTFail("Broken update must not request consent"); return true }
            XCTFail("Broken update must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing.js")) }
        XCTAssertFalse(old.isLoaded)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        XCTAssertTrue(host.pinned(private: false).isEmpty)
        XCTAssertEqual(host.pins, [folder.path], "A recoverable failure must preserve the pin")
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: profile), consent)
        XCTAssertEqual(ScopedPaths.urls(ExtensionHost.key(for: profile)).map { $0.resolvingSymlinksInPath().path }, [folder.path])
        XCTAssertTrue(try XCTUnwrap(host.entries.first).status.contains("Failed"))
        try writeManifest()
        _ = try await host.refresh(folder.path) { _ in XCTFail("Unchanged approval must remain valid"); return false }
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        XCTAssertEqual(host.pinned(private: false).count, 1)
        XCTAssertNil(host.entries.first?.failure)
    }

    func testDisableSurvivesRestoreAndEnablePreservesIdentity() async throws {
        let (host, context) = try await install()
        let identity = context.uniqueIdentifier
        try host.disable(folder.path)
        XCTAssertFalse(context.isLoaded)
        XCTAssertTrue(host.visible(private: false).isEmpty)
        ExtensionHost.forget(profile)
        let restored = ExtensionHost.host(for: profile)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(restored.installed.isEmpty)
        XCTAssertEqual(restored.entries.first?.status, "Disabled")
        _ = try await restored.refresh(folder.path) { _ in XCTFail("Enabling unchanged code needs no new consent"); return false }
        XCTAssertEqual(restored.installed.first?.uniqueIdentifier, identity)
    }

    func testDeclinedUpdateDropsActiveContextButKeepsOldApproval() async throws {
        let (host, context) = try await install()
        try writeManifest(extra: ["permissions": ["storage", "cookies"]])
        let accepted = try await host.refresh(folder.path) { review in
            XCTAssertEqual(review.requested.additions(over: review.previous!).permissions, ["cookies"])
            return false
        }
        XCTAssertFalse(accepted)
        XCTAssertFalse(context.isLoaded)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: profile)?.permissions, ["storage"])
        XCTAssertNotNil(host.entries.first?.failure)
    }

    func testRemovalDuringUpdateReviewCannotReactivateOrOverwriteConsent() async throws {
        let (host, _) = try await install()
        try writeManifest(extra: ["permissions": ["storage", "cookies"]])
        do {
            _ = try await host.refresh(folder.path) { _ in
                try! host.remove(folder: self.folder.path)
                return true
            }
            XCTFail("Removal must invalidate the candidate")
        } catch is CancellationError { }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(host.entries.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: profile))
    }

    func testManifestChangeDuringReviewCannotActivateUnreviewedCode() async throws {
        let host = ExtensionHost.host(for: profile)
        do {
            _ = try await host.load(folder, installing: true) { _ in
                try! self.writeManifest(extra: ["permissions": ["storage", "cookies"]])
                return true
            }
            XCTFail("A manifest changed during consent must be reviewed again")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: profile))
    }

    func testRemovalOfFailedFolderDeletesIdentityConsentPinsAndDisabledState() async throws {
        let (host, context) = try await install()
        host.togglePin(context)
        try host.disable(folder.path)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
        do { _ = try await host.refresh(folder.path) { _ in true }; XCTFail("Missing manifest must fail") }
        catch { }
        try host.remove(folder: folder.path)
        XCTAssertTrue(host.entries.isEmpty)
        XCTAssertTrue(host.pins.isEmpty)
        XCTAssertNil(ExtensionConsent.saved(for: folder, profileID: profile))
        XCTAssertTrue(ScopedPaths.paths(ExtensionHost.key(for: profile)).isEmpty)
        try writeManifest()
        _ = try await host.load(folder, installing: true) { review in XCTAssertNil(review.previous); return true }
        XCTAssertNotEqual(host.installed.first?.uniqueIdentifier, context.uniqueIdentifier)
    }

    func testDisableClosesOwnedOptionsAndIgnoresStaleControls() async throws {
        try Data("<title>Owned options</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
        try writeManifest(extra: ["options_ui": ["page": "options.html"]])
        let (host, context) = try await install()
        try await host.webExtensionController(host.controller, openOptionsPageFor: context)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Management Fixture" && $0.isVisible })
        XCTAssertNotNil(window.contentView as? WKWebView)
        try host.disable(folder.path)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.contentView)
        XCTAssertFalse(context.isLoaded)
        host.run(context, for: nil, from: nil)
        try await host.webExtensionController(host.controller, openOptionsPageFor: context)
        XCTAssertFalse(NSApp.windows.contains { $0.title == "Management Fixture" && $0.isVisible })
    }

    func testResourceEscapingFolderFailsBeforeConsent() async throws {
        let external = folder.deletingLastPathComponent().appendingPathComponent("external-\(UUID()).js")
        try Data("window.external = true".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.js"), withDestinationURL: external)
        try writeManifest(extra: ["content_scripts": [["matches": ["https://example.test/*"], "js": ["escape.js"]]]])
        let host = ExtensionHost.host(for: profile)
        do {
            _ = try await host.load(folder, installing: true) { _ in XCTFail("Escaping resources must not prompt"); return true }
            XCTFail("Resources must stay inside the selected folder")
        } catch { XCTAssertTrue(error.localizedDescription.contains("escape.js")) }
        XCTAssertTrue(host.installed.isEmpty)
    }

    func testRevokingAdditionalAccessPreservesManifestGrants() async throws {
        let (host, context) = try await install()
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "cookies"))
        context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "tabs"))
        host.revokeRuntimeAccess(context)
        XCTAssertTrue(context.hasPermission(WKWebExtension.Permission(rawValue: "storage")))
        XCTAssertFalse(context.hasPermission(WKWebExtension.Permission(rawValue: "cookies")))
        XCTAssertTrue(context.deniedPermissions.isEmpty)
        XCTAssertEqual(ExtensionConsent.saved(for: folder, profileID: profile)?.permissions, ["storage"])
    }

}
