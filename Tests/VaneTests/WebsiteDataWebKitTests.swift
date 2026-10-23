import AppKit
import Darwin
import WebKit
import XCTest
@testable import vane

@MainActor final class WebsiteDataWebKitTests: XCTestCase {
    private var identifiers: [UUID] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
    }

    override func tearDown() async throws {
        for id in identifiers {
            var fixture: WKWebsiteDataStore? = ProfileManager.dataStore(for: id)
            await fixture!.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            let remaining = await fixture!.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            XCTAssertTrue(remaining.isEmpty, "Fixture contents must be erased even if WebKit cannot unregister its store yet")
            fixture = nil
            ProfileManager.releaseDataStore(for: id)
            let storeID = ProfileManager.dataStoreIdentifier(for: id, dataDirectory: Store.overrideDirectory)!
            let error: Error? = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: storeID) { continuation.resume(returning: $0) }
            }
            if let error {
                let failure = error as NSError
                XCTAssertEqual(failure.domain, "WKWebSiteDataStore")
                XCTAssertEqual(failure.code, 1, "Unexpected fixture-unregister failure: \(error)")
                print("Website-data fixture \(storeID): contents erased; WebKit still has the empty store in use.")
            }
        }
        identifiers = []
    }

    private func store() -> (UUID, WKWebsiteDataStore) {
        let id = UUID()
        identifiers.append(id)
        return (id, ProfileManager.dataStore(for: id))
    }

    private func cookie(_ host: String, in store: WKWebsiteDataStore) async {
        let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "fixture", .value: "keep",
            .expires: Date.now.addingTimeInterval(3600)])!
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func cookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    /// A long native suite can leave WebKit's named-store backend unable to open
    /// a new origin database, even though isolated runs succeed. Execute each
    /// real-store check in a fresh host; do not skip or replace its assertions.
    private func runInFreshHost(_ function: String) async throws -> Bool {
        let marker = "VANE_WEBSITE_DATA_TEST_CHILD"
        guard ProcessInfo.processInfo.environment[marker] != "1" else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-website-data-host-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let selector = "VaneTests.WebsiteDataWebKitTests/" + function.replacingOccurrences(of: "()", with: "")
        let bundle = Bundle(for: Self.self).bundleURL.path
        process.arguments = ["xctest", "-XCTest", selector, bundle]
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        let pid = process.processIdentifier
        print("WEBSITE_DATA_TEST_PROCESS pid=\(pid) launched=\(Date.now) bundle=\(bundle) selector=\(selector)")

        func stopOwnedChild() async {
            await Task { @MainActor in
                // Process retains this launch's child identity until it is reaped.
                // Never signal a name or another test host.
                if process.isRunning { process.terminate() }
                var deadline = ContinuousClock.now + .seconds(2)
                while process.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning { _ = kill(pid, SIGKILL) }
                deadline = ContinuousClock.now + .seconds(2)
                while process.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(process.isRunning, "Owned native test host did not exit: \(pid)")
            }.value
        }
        do {
            let deadline = ContinuousClock.now + .seconds(60)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                await stopOwnedChild()
                XCTFail("Native website-data check timed out: \(selector)")
            }
        } catch {
            await stopOwnedChild()
            throw error
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        print(text)
        guard !process.isRunning else { return true }
        print("WEBSITE_DATA_TEST_PROCESS exited pid=\(pid) status=\(process.terminationStatus)")
        XCTAssertEqual(process.terminationReason, .exit, text)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("Executed 1 test, with 0 failures"), "Child must execute the selected assertion set: \(text)")
        return true
    }

    func testDeletingOneSitePreservesAnotherSiteAndSameSiteInAnotherProfile() async throws {
        if try await runInFreshHost(#function) { return }
        let (victimID, victim) = store()
        let (_, survivor) = store()
        await cookie("one.invalid", in: victim)
        await cookie("two.invalid", in: victim)
        await cookie("one.invalid", in: survivor)
        let model = WebsiteDataModel(profileID: victimID, store: victim, isValid: { true })
        model.refresh()
        try await compatibilityWait { !model.isBusy }
        model.select("one.invalid")
        XCTAssertNotNil(model.selectedEntry)
        model.clearSelection()
        try await compatibilityWait { !model.isBusy }
        XCTAssertNil(model.error)
        let left = await cookies(victim)
        let kept = await cookies(survivor)
        XCTAssertEqual(left.map(\.domain), ["two.invalid"])
        XCTAssertEqual(kept.map(\.domain), ["one.invalid"])
    }

    func testDeletingOnlyCookiesPreservesLocalStorageAndPrivateStore() async throws {
        if try await runInFreshHost(#function) { return }
        let (profile, persistent) = store()
        let privateStore = WKWebsiteDataStore.nonPersistent()
        await cookie("one.invalid", in: privateStore)
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/storage"] = "<title>Storage fixture</title>"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent
        var web: WKWebView? = WKWebView(frame: .zero, configuration: configuration)
        web!.load(URLRequest(url: try server.url("/storage")))
        try await compatibilityWait { web?.title == "Storage fixture" && web?.isLoading == false }
        // Navigation completion alone does not prove a newly opened WebKit storage
        // area has retained its initial writes. Seed after navigation and require
        // both the live value and the store's record before exercising deletion.
        let seeded = try await web!.evaluateJavaScript("localStorage.setItem('fixture', 'keep'); document.cookie='fixture=keep; path=/; max-age=3600'; localStorage.getItem('fixture')")
        XCTAssertEqual(seeded as? String, "keep")
        let initialCookies = await cookies(persistent)
        XCTAssertTrue(initialCookies.contains { $0.name == "fixture" && $0.value == "keep" })
        try await compatibilityWait {
            let records = await persistent.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
            return records.contains { $0.displayName == "127.0.0.1" }
        }
        let model = WebsiteDataModel(profileID: profile, store: persistent, isValid: { true })
        model.refresh()
        try await compatibilityWait { !model.isBusy }
        model.select("127.0.0.1")
        if ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                _ = try SidebarSnapshot.pixels(WebsiteDataSheet(model: model, profileName: "Website Data Fixture"),
                    width: 720, height: 590, appearance: appearance)
            }
        }
        XCTAssertTrue(model.selectedEntry?.types.contains(WKWebsiteDataTypeLocalStorage) == true)
        model.selectedTypes = [WKWebsiteDataTypeCookies]
        model.clearSelection()
        try await compatibilityWait { !model.isBusy }
        XCTAssertNil(model.error)
        let persisted = await cookies(persistent)
        XCTAssertTrue(persisted.isEmpty)
        XCTAssertTrue(model.entries.first { $0.name == "127.0.0.1" }?.types.contains(WKWebsiteDataTypeLocalStorage) == true)
        let value = try await web!.evaluateJavaScript("localStorage.getItem('fixture')")
        XCTAssertEqual(value as? String, "keep")
        web!.stopLoading()
        web = nil

        let privateModel = WebsiteDataModel(profileID: Profile.incognito.id, store: privateStore, isValid: { true })
        privateModel.refresh()
        try await compatibilityWait { !privateModel.isBusy }
        privateModel.select("one.invalid")
        privateModel.clearSelection()
        try await compatibilityWait { !privateModel.isBusy }
        XCTAssertNil(privateModel.error)
        let privateCookies = await cookies(privateStore)
        XCTAssertTrue(privateCookies.isEmpty)
        let records = await persistent.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
        XCTAssertTrue(records.contains { $0.displayName == "127.0.0.1" })
        XCTAssertFalse(privateStore.isPersistent)
        XCTAssertNil(privateStore.identifier)
    }

    func testForeignRecordsAreRejectedAndConcurrentRemovalIsReported() async throws {
        if try await runInFreshHost(#function) { return }
        let (_, first) = store()
        let (_, other) = store()
        await cookie("same.invalid", in: first)
        await cookie("same.invalid", in: other)
        let backend = WebKitWebsiteDataBackend(store: first)
        let neighbour = WebKitWebsiteDataBackend(store: other)
        let entries = try await withCheckedThrowingContinuation { continuation in
            backend.fetch { continuation.resume(with: $0) }
        }
        let row = try XCTUnwrap(entries.first)
        var foreignError: Error?
        neighbour.remove(row, types: [WKWebsiteDataTypeCookies]) { if case .failure(let error) = $0 { foreignError = error } }
        XCTAssertNotNil(foreignError)
        let untouched = await cookies(other)
        XCTAssertEqual(untouched.map(\.domain), ["same.invalid"])

        let secondView = WebKitWebsiteDataBackend(store: first)
        let secondEntries = try await withCheckedThrowingContinuation { continuation in
            secondView.fetch { continuation.resume(with: $0) }
        }
        var finished = false
        backend.remove(row, types: [WKWebsiteDataTypeCookies]) { _ in finished = true }
        var pendingError: Error?
        secondView.remove(try XCTUnwrap(secondEntries.first), types: [WKWebsiteDataTypeCookies]) {
            if case .failure(let error) = $0 { pendingError = error }
        }
        XCTAssertNotNil(pendingError)
        try await compatibilityWait { finished }
    }

    func testBulkClearPreservesAnotherProfileAndExplicitAppPermissions() async throws {
        if try await runInFreshHost(#function) { return }
        let (profile, victim) = store()
        let (_, survivor) = store()
        await cookie("shared.invalid", in: victim)
        await cookie("shared.invalid", in: survivor)
        let scope = SitePermissions.Scope(url: URL(string: "https://shared.invalid"), profileID: profile)!
        ExternalApps.allow(scope: scope, scheme: "fixture-app")
        defer { ExternalApps.forgetAll(profileID: profile) }
        let completed = await withCheckedContinuation { continuation in
            BrowsingData.clear(.init(history: false, cookies: true), profileID: profile) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(completed)
        let erased = await cookies(victim)
        let kept = await cookies(survivor)
        XCTAssertTrue(erased.isEmpty)
        XCTAssertEqual(kept.map(\.domain), ["shared.invalid"])
        XCTAssertEqual(ExternalApps.schemes(scope: scope), ["fixture-app"])
    }

    func testDeletingProfileErasesOnlyItsWebsiteStore() async throws {
        if try await runInFreshHost(#function) { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = ProfileManager(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let victim = manager.create(name: "Victim")
        let survivor = manager.create(name: "Survivor")
        identifiers += [victim.id, survivor.id]
        let gone = ProfileManager.dataStore(for: victim.id)
        let kept = ProfileManager.dataStore(for: survivor.id)
        await cookie("same.invalid", in: gone)
        await cookie("same.invalid", in: kept)
        let bytes = Data("surviving database".utf8)
        let keptDB = ProfileManager.dbURL(for: survivor.id, in: directory)
        try bytes.write(to: keptDB)
        XCTAssertTrue(manager.delete(victim.id))
        try await compatibilityWait { await self.cookies(gone).isEmpty }
        let survivorCookies = await cookies(kept)
        XCTAssertEqual(survivorCookies.map(\.domain), ["same.invalid"])
        XCTAssertEqual(try Data(contentsOf: keptDB), bytes)
        XCTAssertTrue(manager.profiles.contains { $0.id == survivor.id })
    }
}
