import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class DownloadWebKitTests: XCTestCase {
    var root: URL!
    var server: DownloadHTTPFixture!
    var manager: Downloads!
    var web: WKWebView!
    var fixtureProfile: UUID!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fputs("DOWNLOAD FIXTURE root=\(root.path)\n", stderr)
        manager = Downloads(profileID: UUID(), directory: root, sandboxed: true)
        manager.destinationDirectory = root
        fixtureProfile = manager.profileID
        let identifier = ProfileManager.dataStoreIdentifier(for: fixtureProfile, dataDirectory: Store.overrideDirectory)!
        fputs("DOWNLOAD FIXTURE store=\(identifier) namespace=\(Store.overrideDirectory ?? "")\n", stderr)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ProfileManager.dataStore(for: manager.profileID)
        web = WKWebView(frame: .zero, configuration: config)
        server = try DownloadHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
    }

    override func tearDown() async throws {
        manager.items.filter { $0.status.isLive }.forEach { manager.cancel($0) }
        web.stopLoading()
        web = nil
        server.stop()
        server = nil
        let profile = fixtureProfile!
        manager = nil
        var store: WKWebsiteDataStore? = ProfileManager.dataStore(for: profile)
        await store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        store = nil
        ProfileManager.releaseDataStore(for: profile)
        let identifier = ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: Store.overrideDirectory)!
        var removalError: Error?
        for _ in 0..<20 {
            removalError = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: identifier) { continuation.resume(returning: $0) }
            }
            if removalError == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(removalError, "Owned WebKit fixture store remains registered: \(identifier)")
        try? FileManager.default.removeItem(at: root)
    }

    func start(_ path: String = "/file") async throws -> Downloads.Item {
        let count = manager.items.count
        let download = await web.startDownload(using: URLRequest(url: try server.url(path)))
        manager.attach(download, from: web)
        try await compatibilityWait { self.manager.items.count > count }
        return try XCTUnwrap(manager.items.first)
    }

    func complete(_ row: Downloads.Item, bytes: Data, persisted: Bool = true) async throws {
        try await compatibilityWait { !row.status.isLive }
        XCTAssertEqual(row.status, .done, row.subtitle)
        let file = try XCTUnwrap(row.url)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let restored = Downloads(profileID: manager.profileID, directory: root, sandboxed: true)
        if persisted { XCTAssertEqual(restored.items.first { $0.id == row.id }?.status, .done) }
        else { XCTAssertTrue(restored.items.isEmpty) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloads.resumeDir(for: manager.profileID, in: root).appendingPathComponent("\(row.id).resume").path))
    }

    func testConcurrentDuplicateNamesAndRedirectHaveExactBytes() async throws {
        server.held = true
        let first = try await start()
        let second = try await start("/redirect")
        XCTAssertNotEqual(first.url, second.url)
        server.held = false
        try await complete(first, bytes: server.bytes)
        try await complete(second, bytes: server.bytes)
    }

    func testPauseThenCancelDoesNotResurrectRowOrLeavePartial() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        manager.pause(row)
        manager.cancel(row)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(row.state, .failed(Downloads.cancelledText))
        XCTAssertFalse(manager.canResume(row))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(row.url).path))
    }

    func testRemovingRunningTransferStopsItAndCleansPartial() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        let file = try XCTUnwrap(row.url)
        manager.forget(row)
        server.held = false
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPauseResumeUsesWebKitDataAndFinalBytes() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        print("DOWNLOAD pause status=\(row.status) resume=\(manager.canResume(row)) pathExists=\(FileManager.default.fileExists(atPath: row.url!.path)) \(row.subtitle)")
        XCTAssertTrue(manager.canResume(row))
        XCTAssertTrue(manager.resume(row))
        XCTAssertFalse(manager.resume(row))
        server.held = false
        try await complete(row, bytes: server.bytes)
    }

    func testImmediatePauseDuringResumeIsHonored() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertTrue(manager.resume(row))
        manager.pause(row)
        XCTAssertFalse(manager.canRetry(row))
        XCTAssertFalse(manager.retry(row))
        try await compatibilityWait { row.download == nil && row.status != .running && !row.subtitle.hasPrefix("Pausing") }
        XCTAssertEqual(row.status, .paused)
        XCTAssertTrue(manager.canResume(row))
    }

    func testQuitWaitsForAlreadyRequestedPause() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        manager.pauseAll()
        XCTAssertNil(row.download)
        XCTAssertTrue(manager.canResume(row))
        let loaded = Downloads(profileID: manager.profileID, directory: root, sandboxed: true)
        XCTAssertTrue(loaded.items.first.map { loaded.canResume($0) } ?? false)
    }

    func testDisconnectNeverCompletesTruncatedFile() async throws {
        server.disconnectAfter = 32768
        let row = try await start()
        try await compatibilityWait { row.download == nil }
        XCTAssertNotEqual(row.status, .done)
        let restored = Downloads(profileID: manager.profileID, directory: root, sandboxed: true)
        XCTAssertNotEqual(restored.items.first?.status, .done)
    }

    func testMissingDestinationDoesNotComplete() async throws {
        manager.destinationDirectory = root.appendingPathComponent("missing")
        let row = try await start()
        try await compatibilityWait { row.download == nil }
        XCTAssertNotEqual(row.status, .done)
    }

    func testReloadedPauseResumesInOriginalFolderAfterPreferenceChange() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        let target = try XCTUnwrap(row.url)
        manager = Downloads(profileID: manager.profileID, directory: root, sandboxed: true)
        let loaded = try XCTUnwrap(manager.items.first)
        manager.destinationDirectory = root.appendingPathComponent("new-folder")
        XCTAssertTrue(manager.resume(loaded))
        server.held = false
        try await complete(loaded, bytes: server.bytes)
        XCTAssertEqual(loaded.url, target)
    }

    func testIgnoredRangesDoNotProduceAppendedOrTruncatedCompletedFile() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertTrue(manager.canResume(row))
        server.supportsRanges = false
        server.held = false
        XCTAssertTrue(manager.resume(row))
        try await compatibilityWait { row.download == nil && row.status != .running }
        if row.status == .done { try await complete(row, bytes: server.bytes) }
        else { XCTAssertNotEqual(row.status, .done) }
        XCTAssertTrue(server.requests.contains { $0.lowercased().contains("range:") })
    }

    func testRejectedRangesDoNotAppearCompleted() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        server.rejectRanges = true
        server.held = false
        XCTAssertTrue(manager.resume(row))
        try await compatibilityWait { row.download == nil && row.status != .running }
        XCTAssertNotEqual(row.status, .done)
        print("DOWNLOAD rejected-range status=\(row.status) size=\(row.received) requests=\(server.requests.map { $0.components(separatedBy: "\r\n").prefix(5).joined(separator: " | ") })")
        XCTAssertTrue(server.requests.contains { $0.lowercased().contains("range:") })
    }

    func testUnknownLengthRejectedRangeCannotCompleteEmptyFile() async throws {
        server.omitLength = true
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        if manager.canResume(row) {
            server.rejectRanges = true
            server.held = false
            XCTAssertTrue(manager.resume(row))
            try await compatibilityWait { row.download == nil && row.status != .running }
            XCTAssertNotEqual(row.status, .done)
        } else {
            XCTAssertTrue(manager.canRetry(row))
        }
    }

    func testChangedResourceNeverCompletesMixedBytes() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        server.version = 2
        server.variantCount = 131072
        server.held = false
        XCTAssertTrue(manager.resume(row))
        try await compatibilityWait { row.download == nil && row.status != .running }
        if row.status == .done {
            let bytes = try Data(contentsOf: XCTUnwrap(row.url))
            XCTAssertTrue(bytes == server.bytes || bytes == server.body, "A completed file must be one whole resource version")
        }
    }

    func testDestinationBecomingUnwritableFailsAndDoesNotComplete() async throws {
        let destination = root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path) }
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: destination.path))
        manager.destinationDirectory = destination
        let row = try await start()
        try await compatibilityWait { row.download == nil }
        XCTAssertNotEqual(row.status, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(row.url).path))
    }

    func testCompletionCallbackWithMissingFinalFileCannotPublishDone() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        let download = try XCTUnwrap(row.download)
        try FileManager.default.removeItem(at: XCTUnwrap(row.url))
        manager.downloadDidFinish(download)
        XCTAssertNotEqual(row.status, .done)
        XCTAssertNil(row.completed)
        _ = await download.cancel()
    }


    func testRetryStartsFreshWithoutReplacingExistingFile() async throws {
        let existing = root.appendingPathComponent("fixture.bin")
        let keep = Data("user-owned file".utf8)
        try keep.write(to: existing)
        let row = manager.add(.init(name: "fixture.bin", destination: root.appendingPathComponent("missing.bin"),
            source: try server.url(), state: "failed", sourceMethod: "GET"))
        XCTAssertTrue(manager.canRetry(row))
        XCTAssertTrue(manager.retry(row))
        XCTAssertFalse(manager.retry(row))
        try await compatibilityWait { self.manager.items.count == 2 }
        let retried = try XCTUnwrap(manager.items.first)
        try await complete(retried, bytes: server.bytes)
        XCTAssertNotEqual(retried.url, existing)
        XCTAssertEqual(try Data(contentsOf: existing), keep)
    }

    func testDisconnectWithoutResumeHasVisibleRetryAndNoPartial() async throws {
        server.offersValidators = false
        server.supportsRanges = false
        server.disconnectAfter = 32768
        let row = try await start()
        try await compatibilityWait { row.download == nil }
        if !manager.canResume(row) {
            XCTAssertTrue(manager.canRetry(row))
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(row.url).path))
        }
    }


    func testResumePersistenceWriteFailureDoesNotPromiseResume() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        try Data([0]).write(to: Downloads.resumeDir(for: manager.profileID, in: root))
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertEqual(row.status, .failed)
        XCTAssertFalse(manager.canResume(row))
        XCTAssertTrue(manager.canRetry(row))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(row.url).path))
        XCTAssertTrue(row.subtitle.contains("save resume data"))
        let reloaded = Downloads(profileID: manager.profileID, directory: root, sandboxed: true)
        XCTAssertEqual(reloaded.items.first?.status, .failed)
    }

    func testPrivateResumeStaysInMemoryAndCannotReachRegularRows() async throws {
        let regular = manager!
        let privateManager = Downloads(profileID: Profile.incognito.id, directory: root, sandboxed: true)
        privateManager.destinationDirectory = root
        manager = privateManager
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        regular.pause(row)
        XCTAssertEqual(row.status, .running)
        privateManager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertTrue(privateManager.canResume(row))
        XCTAssertFalse(regular.resume(row))
        XCTAssertFalse(regular.retry(row))
        regular.cancel(row)
        XCTAssertEqual(row.status, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloads.listURL(for: Profile.incognito.id, in: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloads.resumeDir(for: Profile.incognito.id, in: root).path))
        XCTAssertTrue(Downloads(profileID: Profile.incognito.id, directory: root, sandboxed: true).items.isEmpty)
        privateManager.cancel(row)
        XCTAssertFalse(privateManager.canResume(row))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(row.url).path))
    }


    func testInvalidCompletionDoesNotDeleteReplacementFile() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        let destination = try XCTUnwrap(row.url)
        let replacement = root.appendingPathComponent("replacement.bin")
        let keep = Data("user replacement".utf8)
        try keep.write(to: replacement)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        let download = try XCTUnwrap(row.download)
        manager.downloadDidFinish(download)
        XCTAssertNotEqual(row.status, .done)
        XCTAssertEqual(try Data(contentsOf: destination), keep)
        _ = await download.cancel()
    }

    func testResumeCannotAppendToReplacedPartialFile() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        let destination = try XCTUnwrap(row.url)
        let replacement = root.appendingPathComponent("replacement.bin")
        let keep = Data("user replacement".utf8)
        try keep.write(to: replacement)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        XCTAssertFalse(manager.canResume(row))
        XCTAssertFalse(manager.resume(row))
        XCTAssertTrue(manager.canRetry(row))
        XCTAssertEqual(try Data(contentsOf: destination), keep)
    }

    func testPrivateFreshRetryKeepsOriginatingCookies() async throws {
        manager = Downloads(profileID: Profile.incognito.id, directory: root, sandboxed: true)
        manager.destinationDirectory = root
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: config)
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "privateFixture", .value: "keep"])!
        await withCheckedContinuation { continuation in
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
        web.load(URLRequest(url: try server.url("/page")))
        try await compatibilityWait { self.web.title == "Download Cookie Fixture" && !self.web.isLoading }
        _ = try await web.evaluateJavaScript("document.cookie='privateFixture=keep; Path=/; SameSite=Lax'")
        server.offersValidators = false
        server.supportsRanges = false
        server.disconnectAfter = 32768
        let row = try await start()
        try await compatibilityWait { row.download == nil }
        if row.status == .paused { manager.cancel(row) }
        server.disconnectAfter = nil
        XCTAssertTrue(manager.retry(row))
        try await compatibilityWait { self.manager.items.count == 2 }
        try await complete(try XCTUnwrap(manager.items.first), bytes: server.bytes, persisted: false)
        XCTAssertTrue(server.requests.count >= 2)
        print("DOWNLOAD private cookies requests=\(server.requests.map { $0.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("cookie:") } })")
        XCTAssertTrue(server.requests.first { $0.hasPrefix("GET /file ") }?.contains("privateFixture=keep") == true, "The initial source download must carry its cookie")
        XCTAssertTrue(server.requests.last?.contains("privateFixture=keep") == true)
    }

    func testDeletingProfileCancelsItsLiveDownload() async throws {
        manager = Downloads.manager(for: fixtureProfile)
        manager.destinationDirectory = root
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        let destination = try XCTUnwrap(row.url)
        Downloads.forget(fixtureProfile)
        server.held = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(row.download)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloads.listURL(for: fixtureProfile, in: Store.directory).path))
    }


    func testCancelBeforeFirstBytesPreservesUnverifiedDestination() async throws {
        server.holdAllBytes = true
        let row = try await start()
        let file = try XCTUnwrap(row.url)
        try await compatibilityWait { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertEqual(row.received, 0)
        manager.cancel(row)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(row.state, .failed(Downloads.cancelledText))
        // WKDownload exposes no macOS destination-created callback. An empty file may
        // have been created by another process; cancellation must not adopt/delete it.
        if FileManager.default.fileExists(atPath: file.path) {
            XCTAssertEqual(try Data(contentsOf: file).count, 0)
        }
        XCTAssertFalse(manager.canResume(row))
    }

    func testFileCreatedBeforeWebKitAcceptsDestinationIsPreserved() async throws {
        let download = await web.startDownload(using: URLRequest(url: try server.url()))
        manager.attach(download, from: web)
        let collision = DestinationCollisionDelegate(manager: manager)
        download.delegate = collision
        try await compatibilityWait { self.manager.items.first?.status == .failed }
        let file = try XCTUnwrap(collision.createdURL)
        XCTAssertEqual(try Data(contentsOf: file), collision.bytes)
        XCTAssertEqual(manager.items.count, 1)
    }


    func testEncodedAndUnknownLengthResponsesPreserveWebKitDownloadBytes() async throws {
        server.encodedBody = Data(base64Encoded: "H4sIAAAAAAAC/+3PQ4IQAAAAwM22udm2bdu2bddm27Zt27ZtW6c+0BNmfjABwYKHCBkqdJiw4cJHiBgpcpSo0aLHiBkrdpy48eInSJgocWCSpMmSp0iZKnWatOnSZ8iYKXOWrNmy58iZK3eevPnyFyhYqHCRosWKlyhZqnSZsuXKV6hYqXKVqtWq16hZq3aduvXqN2jYqHGTps2at2jZqnWbtu3ad+jYqXOXrt269+jZq3efvv36Dxg4aPCQocOCho8YOWr0mLHjxk+YOGnylKnTps+YOWv2nLnz5i9YuGjxkqXLlq9YuWr1mrXr1m/YuGnzlq3btu/YuWv3nr379h84eOjwkaPHjp84eer0mbPnzl+4eOnylavXrt+4eev2nbv37j94+Ojxk6fPnr94+er1m7fv3n/4+Onzl6/fvv/4+ev3n78B6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6v+v/wMTR1cYAAAEAA==")!
        let encoded = try await start()
        try await complete(encoded, bytes: server.bytes)
        server.encodedBody = nil
        server.omitLength = true
        let unknown = try await start()
        try await complete(unknown, bytes: server.bytes)
    }

    func testPausingRetriedTransferReleasesOriginRetryGate() async throws {
        server.held = true
        let origin = manager.add(.init(name: "failed", source: try server.url(), state: "failed", sourceMethod: "GET"))
        XCTAssertTrue(manager.retry(origin))
        try await compatibilityWait { self.manager.items.count == 2 }
        let row = try XCTUnwrap(manager.items.first)
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertTrue(manager.canRetry(origin))
    }

    func testCancelledOrRemovedPendingRetryCannotAddDownload() async throws {
        for remove in [false, true] {
            server.holdHeaders = true
            let origin = manager.add(.init(name: "paused", source: try server.url(), state: "paused", sourceMethod: "GET"))
            XCTAssertTrue(manager.retry(origin))
            try await compatibilityWait { self.server.requests.count > (remove ? 1 : 0) }
            if remove { manager.forget(origin) } else { manager.cancel(origin) }
            let count = manager.items.count
            server.holdHeaders = false
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(manager.items.count, count)
            XCTAssertFalse(manager.items.contains { $0.status.isLive })
            if !remove { XCTAssertEqual(origin.state, .failed(Downloads.cancelledText)) }
        }
    }

    func testCancelWhileResumeCallbackIsPendingCannotResurrectTransfer() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertTrue(manager.resume(row))
        manager.cancel(row)
        server.held = false
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(row.state, .failed(Downloads.cancelledText))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(row.url).path))
        XCTAssertFalse(manager.canResume(row))
    }

    func testCancelledResumedDestinationCallbackCannotCreateFreshRow() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        XCTAssertTrue(manager.resume(row))
        try await compatibilityWait { row.download != nil }
        let retired = try XCTUnwrap(row.download)
        manager.cancel(row)
        var supplied: URL?
        manager.download(retired, decideDestinationUsing: URLResponse(url: try server.url(),
            mimeType: "application/octet-stream", expectedContentLength: server.bytes.count, textEncodingName: nil),
            suggestedFilename: "late.bin") { supplied = $0 }
        XCTAssertNil(supplied)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(row.state, .failed(Downloads.cancelledText))
    }


    func testStructurallyValidButUnavailableResumeDataFailsHonestly() async throws {
        server.held = true
        let row = try await start()
        try await compatibilityWait { row.received > 0 }
        manager.pause(row)
        try await compatibilityWait { row.download == nil }
        let blob = Downloads.resumeDir(for: manager.profileID, in: root).appendingPathComponent("\(row.id).resume")
        try PropertyListSerialization.data(fromPropertyList: ["invalid": "not WebKit resume data"], format: .binary, options: 0).write(to: blob)
        server.held = false
        if manager.resume(row) {
            try await compatibilityWait { row.download == nil && row.status != .running }
        }
        XCTAssertNotEqual(row.status, .done)
        XCTAssertTrue(manager.canRetry(row))
    }


    func testSimultaneousDestinationDecisionsReserveDistinctNames() async throws {
        server.holdHeaders = true
        for _ in 0..<8 {
            let download = await web.startDownload(using: URLRequest(url: try server.url()))
            manager.attach(download, from: web)
        }
        try await compatibilityWait { self.server.requests.count >= 6 }
        server.holdHeaders = false
        try await compatibilityWait { self.manager.items.count == 8 }
        XCTAssertEqual(Set(manager.items.compactMap(\.url)).count, 8)
        for row in manager.items { try await complete(row, bytes: server.bytes) }
    }

}

/// Creates a foreign file in the gap between Vane choosing a path and WebKit's
/// exclusive create. The delay reproduces the old ownership poll adopting that file.
@MainActor private final class DestinationCollisionDelegate: NSObject, WKDownloadDelegate {
    let manager: Downloads
    let bytes = Data("foreign destination".utf8)
    var createdURL: URL?
    init(manager: Downloads) { self.manager = manager }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        manager.download(download, decideDestinationUsing: response, suggestedFilename: suggestedFilename) { url in
            guard let url else { completionHandler(nil); return }
            do { try self.bytes.write(to: url); self.createdURL = url }
            catch { completionHandler(nil); return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                completionHandler(url)
            }
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        manager.download(download, didFailWithError: error, resumeData: resumeData)
    }
    func downloadDidFinish(_ download: WKDownload) { manager.downloadDidFinish(download) }
}
