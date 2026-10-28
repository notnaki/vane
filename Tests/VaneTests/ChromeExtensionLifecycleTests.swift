import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ChromeExtensionLifecycleTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var source: ChromeWebStore!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        source = try ChromeWebStore(input: String(repeating: "a", count: 32))
        folder = Store.directory.appendingPathComponent("store-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(version: "1.0")
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
        try await NativeFixtureProfileCleanup.release([profile])
    }

    private func write(version: String, permissions: [String] = ["storage"]) throws {
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Store Fixture", "description": "Store lifecycle test", "version": version, "permissions": permissions, "options_ui": ["page": "options.html"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Store options</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
    }

    @discardableResult private func install(_ host: ExtensionHost, automatic: Bool = false,
        review: @escaping @MainActor (ExtensionConsent.Review) -> Bool = { _ in true }) async throws -> Bool {
        let folder = folder!
        return try await host.installStore(source, automatic: automatic, fetch: { _, _ in folder }, review: review)
    }

    func testStoreIdentitySurvivesUpdateAndSourceDeletion() async throws {
        let host = ExtensionHost.host(for: profile)
        let accepted = try await install(host)
        XCTAssertTrue(accepted)
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, source.id)
        let origin = try XCTUnwrap(host.installed.first?.baseURL)
        host.togglePin(source.key)
        try write(version: "2.0")
        let updated = try await install(host)
        XCTAssertTrue(updated)
        XCTAssertEqual(host.entries.count, 1)
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, source.id)
        XCTAssertEqual(host.installed.first?.baseURL, origin)
        XCTAssertEqual(host.pins, [source.key])
        XCTAssertEqual(host.entries.first?.storeID, source.id)
        try FileManager.default.removeItem(at: folder)
        ExtensionHost.forget(profile)
        let restored = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(5)
        while restored.entries.contains(where: \.busy), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(restored.installed.first?.webExtension.version, "2.0")
        XCTAssertEqual(restored.installed.first?.uniqueIdentifier, source.id)
    }

    func testAutomaticUpdateDoesNotGrantAddedAccess() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        try write(version: "2.0", permissions: ["storage", "tabs"])
        let declined = try await install(host, automatic: true, review: { review in
            XCTAssertTrue(review.needsApproval)
            XCTAssertTrue(review.requested.permissions.contains("tabs"))
            return false
        })
        XCTAssertFalse(declined)
        XCTAssertEqual(host.installed.first?.webExtension.version, "1.0")
        XCTAssertEqual(host.entries.first?.requiredAccess?.permissions, ["storage"])
        XCTAssertNotNil(host.entries.first?.failure)
        let reviewed = try await install(host)
        XCTAssertTrue(reviewed)
        XCTAssertEqual(host.installed.first?.webExtension.version, "2.0")
    }

    func testAutomaticSameAccessUpdateAndDisabledState() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        try write(version: "1.1")
        let automatic = try await install(host, automatic: true, review: { _ in XCTFail("Same-access update should not prompt"); return false })
        XCTAssertTrue(automatic)
        try await host.setEnabled(false, for: source.key)
        try write(version: "1.2")
        let disabledUpdate = try await install(host, automatic: true)
        XCTAssertTrue(disabledUpdate)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertEqual(host.entries.first?.version, "1.2")
        XCTAssertEqual(host.entries.first?.status, "Disabled")
        try write(version: "1.0")
        let downgrade = try await install(host)
        XCTAssertFalse(downgrade)
        XCTAssertEqual(host.entries.first?.version, "1.2")
    }

    func testRemoveDuringDownloadCannotResurrectInstallation() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let source = source!, folder = folder!
        let task = Task {
            try await host.installStore(source, fetch: { _, _ in
                for await _ in stream { break }
                return folder
            }, review: { _ in true })
        }
        while !host.entries.contains(where: \.busy) { await Task.yield() }
        try host.remove(folder: source.key)
        continuation.finish()
        do { _ = try await task.value; XCTFail("Removed installation must cancel") }
        catch is CancellationError { }
        XCTAssertTrue(host.entries.isEmpty)
        XCTAssertTrue(host.installed.isEmpty)
    }

    func testPrivateProfileCannotFetchStorePackages() async throws {
        let host = ExtensionHost.host(for: Profile.incognito.id)
        do {
            _ = try await host.installStore(source, fetch: { _, _ in XCTFail("Private install fetched a package"); throw CancellationError() }, review: { _ in true })
            XCTFail("Private installs must be rejected")
        } catch is CancellationError { }
        XCTAssertTrue(host.entries.isEmpty)
    }

    func testReinstallDoesNotInheritRemovedStoreExtensionData() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        func options(_ context: WKWebExtensionContext) async throws -> WKWebView {
            let web = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
            web.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
            let deadline = ContinuousClock.now + .seconds(5)
            while web.isLoading || web.title != "Store options" {
                guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Store options did not load") }
                try await Task.sleep(for: .milliseconds(10))
            }
            return web
        }
        var web: WKWebView? = try await options(XCTUnwrap(host.installed.first))
        _ = try await web!.callAsyncJavaScript("await browser.storage.local.set({oldInstall:'private'}); return true;", arguments: [:], in: nil, contentWorld: .page)
        web?.stopLoading(); web = nil
        try host.remove(folder: source.key)
        _ = try await install(host)
        web = try await options(XCTUnwrap(host.installed.first))
        let value = try await web!.callAsyncJavaScript("return (await browser.storage.local.get('oldInstall')).oldInstall ?? 'empty';", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(value as? String, "empty")
        web?.stopLoading()
    }

    func testRealStoreDownloadAndBackgroundWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["VANE_STORE_LIVE_CHECK"] == "1" else {
            throw XCTSkip("Set VANE_STORE_LIVE_CHECK=1 for the real store download/runtime check.")
        }
        let source = try ChromeWebStore(input: "eimadpbcbfnmbkopoojfekhnkhdbieeh")
        let host = ExtensionHost.host(for: profile)
        let accepted = try await host.installStore(source, review: { _ in true })
        XCTAssertTrue(accepted)
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, source.id)
        XCTAssertEqual(host.installed.first?.webExtension.displayName, "Dark Reader")
        XCTAssertNil(host.entries.first?.failure)
    }

    func testExplicitStoreInstallRepairsUnreadableMetadataWithoutChangingOrigin() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        let origin = host.installed.first?.baseURL
        ExtensionHost.forget(profile)
        let store = ExtensionCodeStore(profileID: profile)
        try Data("corrupt".utf8).write(to: store.root.appendingPathComponent("installations.json"))
        let restored = ExtensionHost.host(for: profile)
        XCTAssertEqual(restored.entries.first?.storeID, source.id)
        XCTAssertTrue(restored.installed.isEmpty)
        var reviewed = false
        let accepted = try await install(restored, review: { review in
            reviewed = true; XCTAssertTrue(review.needsApproval); return true
        })
        XCTAssertTrue(accepted)
        XCTAssertTrue(reviewed)
        XCTAssertEqual(restored.installed.first?.baseURL, origin)
        XCTAssertNil(restored.entries.first?.failure)
    }

    func testExplicitSameVersionUpdateRepairsMissingCodeWithoutChangingOrigin() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        let origin = host.installed.first?.baseURL
        ExtensionHost.forget(profile)
        let store = ExtensionCodeStore(profileID: profile)
        let record = try XCTUnwrap(store.records()[source.key])
        try FileManager.default.removeItem(at: store.code(for: record).appendingPathComponent("manifest.json"))
        let restored = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(5)
        while restored.entries.contains(where: \.busy), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(restored.installed.isEmpty)
        var reviewed = false
        let accepted = try await install(restored, review: { review in
            reviewed = true; XCTAssertTrue(review.updating); return true
        })
        XCTAssertTrue(accepted)
        XCTAssertTrue(reviewed)
        XCTAssertEqual(restored.installed.first?.baseURL, origin)
        XCTAssertNil(restored.entries.first?.failure)
    }

    func testSuccessfulUnchangedCheckClearsResolvedAttentionWithoutReplacingHealthyCode() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await install(host)
        let store = ExtensionCodeStore(profileID: profile)
        let revision = try XCTUnwrap(store.records()[source.key]?.revision)
        try write(version: "2.0", permissions: ["storage", "tabs"])
        _ = try await install(host, automatic: true, review: { _ in false })
        XCTAssertNotNil(host.entries.first?.failure)
        // The store withdrew the permission-increasing release; the accepted version is current again.
        try write(version: "1.0")
        let changed = try await install(host)
        XCTAssertFalse(changed)
        XCTAssertNil(host.entries.first?.failure)
        XCTAssertEqual(try store.records()[source.key]?.revision, revision)
    }
}
