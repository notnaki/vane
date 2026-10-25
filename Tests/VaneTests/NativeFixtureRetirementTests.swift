import AppKit
import Darwin
import WebKit
import XCTest
@testable import vane

@MainActor final class NativeFixtureRetirementTests: XCTestCase {
    private final class Reply {
        var cookieStored = false
        var cookies: [HTTPCookie]?
        var identifiers: [UUID]?
    }
    private func waitForReply(_ stage: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else {
            NativeFixtureDiagnostics.emit("retirement integration timed out: \(stage)")
            throw NativeFixtureRetirement.Failure("Retirement integration timed out: \(stage)")
        }
    }
    func testRetireManifest() async throws {
        try await NativeFixtureRetirement.retireManifest()
    }

    func testDeferredRetirementKeepsOwnedBackendUntilHostExit() async throws {
        guard ProcessInfo.processInfo.environment["VANE_NATIVE_FIXTURE_MANIFEST_DIR"] != nil,
              ProcessInfo.processInfo.environment["VANE_NATIVE_FIXTURE_RETIREMENT_PHASE"] == nil else {
            throw XCTSkip("The native test wrapper owns deferred-retirement integration")
        }
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let profile = UUID()
        let directory = try XCTUnwrap(Store.overrideDirectory)
        let identifier = try XCTUnwrap(ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: directory))
        // Publish ownership before the first native allocation, including failing seeds.
        XCTAssertTrue(try NativeFixtureRetirement.recordIfEnabled(profile: profile, directory: directory))
        addTeardownBlock { @MainActor in try await NativeFixtureProfileCleanup.release([profile]) }
        func seed() async throws {
            let store = ProfileManager.dataStore(for: profile)
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "native-retirement.invalid", .path: "/", .name: "owned", .value: "fixture",
                                                              .expires: Date.now.addingTimeInterval(3600)]))
            let reply = Reply()
            store.httpCookieStore.setCookie(cookie) { reply.cookieStored = true }
            try await waitForReply("owned cookie storage") { reply.cookieStored }
            store.httpCookieStore.getAllCookies { reply.cookies = $0 }
            try await waitForReply("owned cookie readback") { reply.cookies != nil }
            XCTAssertTrue(try XCTUnwrap(reply.cookies).contains { $0.name == "owned" && $0.value == "fixture" })
        }
        try await seed()
        try await NativeFixtureProfileCleanup.release([profile])
        let reply = Reply()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { reply.identifiers = $0 }
        try await waitForReply("owned backend registration") { reply.identifiers != nil }
        let registered = try XCTUnwrap(reply.identifiers)
        XCTAssertTrue(registered.contains(identifier), "The real owned backend must survive until the wrapper's fresh retirement host")
    }
}

@MainActor final class NativeFixtureRetirementManifestTests: XCTestCase {
    private let directory = "/tmp/vane-retirement-pure-owned"
    private func entry(profile: UUID = UUID(), store: UUID? = nil, directory: String? = nil) -> NativeFixtureRetirement.Entry {
        let path = directory ?? self.directory
        return .init(profileID: profile, dataDirectory: path,
                     storeID: store ?? ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: path)!)
    }
    private func host(path: String = "/tmp/Owned.xctest/Contents/MacOS/Owned", bundle: String = "owned.tests") -> NativeFixtureRetirement.Host {
        .init(pid: 100, start: 200, path: path, processName: "Owned", bundleIdentifier: bundle, testBundlePath: "/tmp/Owned.xctest")
    }
    func testPhysicalManifestPathUsesSamePOSIXCanonicalizationAsWrapper() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-retirement-path-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(resolved) }
        let physical = String(cString: resolved)
        XCTAssertEqual(NativeFixtureRetirement.canonical(physical), physical,
                       "Foundation rewrites /private/var to /var; manifest ownership must use the same POSIX path as Python")
    }
    func testOnlyExplicitOwnedDerivedIdentifierIsAccepted() throws {
        XCTAssertNoThrow(try NativeFixtureRetirement.validate(entry()))
        XCTAssertThrowsError(try NativeFixtureRetirement.validate(entry(store: UUID())))
    }
    func testDefaultAndIncognitoProfilesAreRejected() {
        for profile in [ProfileManager.defaultID, Profile.incognito.id] {
            XCTAssertThrowsError(try NativeFixtureRetirement.validate(entry(profile: profile)))
        }
    }
    func testNonisolatedAndUnnormalizedNamespacesAreRejected() {
        for path in ["/", "relative", "/tmp/a/../b", "//tmp/owned"] {
            XCTAssertThrowsError(try NativeFixtureRetirement.validate(entry(directory: path)))
        }
    }
    func testCompleteManifestMustMatchTokenAndSameHostNamespace() throws {
        let owner = host()
        let manifest = NativeFixtureRetirement.Manifest(schema: 1, token: "owned", host: owner, profiles: [entry()])
        XCTAssertNoThrow(try NativeFixtureRetirement.validate(manifest, token: "owned", matching: owner))
        XCTAssertThrowsError(try NativeFixtureRetirement.validate(manifest, token: "other", matching: owner))
        XCTAssertThrowsError(try NativeFixtureRetirement.validate(manifest, token: "owned", matching: host(bundle: "another.tests")))
        XCTAssertThrowsError(try NativeFixtureRetirement.validate(manifest, token: "owned", matching: host(path: "/tmp/Other")))
        let mixed = NativeFixtureRetirement.Manifest(schema: 1, token: "owned", host: owner, profiles: [entry(), entry(store: UUID())])
        XCTAssertThrowsError(try NativeFixtureRetirement.validate(mixed, token: "owned", matching: owner))
    }
    func testRetirementDeletesOnlyOwnedExistingBackendAndPreservesUnrelatedStore() async throws {
        let owned = UUID(), neverOpened = UUID(), unrelated = UUID()
        var registry: Set<UUID> = [owned, unrelated]
        var removed: [UUID] = []
        try await NativeFixtureRetirement.retireOwned([owned, neverOpened], registered: { registry }, remove: {
            removed.append($0)
            registry.remove($0)
        })
        XCTAssertEqual(removed, [owned])
        XCTAssertEqual(registry, [unrelated])
    }
    func testSuccessfulRemovalCallbackStillRequiresObservedRegistryAbsence() async throws {
        let owned = UUID()
        do {
            try await NativeFixtureRetirement.retireOwned([owned], registered: { [owned] }, remove: { _ in })
            XCTFail("A successful callback cannot substitute for actual backend absence")
        } catch { XCTAssertTrue(String(describing: error).contains("remains registered")) }
    }
}
