import AppKit
import Darwin
import XCTest
@testable import vane

@MainActor final class FaviconPublicationTests: XCTestCase {
    private static let artwork = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Favicon publication timed out")
                throw NSError(domain: "FaviconPublicationTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The writer cannot open a FIFO until its reader exists. A nonblocking reader
    /// also gives failed fixtures a bounded cleanup path rather than stranding a worker.
    private nonisolated static func drain(_ file: URL) async -> Data {
        await Task.detached {
            let descriptor = file.path.withCString { open($0, O_RDONLY | O_NONBLOCK) }
            guard descriptor >= 0 else { return Data() }
            defer { Darwin.close(descriptor) }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                else if count == 0, !data.isEmpty { return data }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return data
        }.value
    }

    func testFetchedIconPublishesToTabsAndCacheBeforeBlockedPersistenceFinishes() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), data = Self.artwork
        let url = URL(string: "https://publication-\(UUID().uuidString.lowercased()).invalid/")!
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        let file = directory.appendingPathComponent(url.host!)
        let admission = AsyncStream<Void>.makeStream()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache: Favicons? = Favicons(profileID: profile, fetch: { _ in
            defer { admission.continuation.finish() }
            // Install the blocked destination after the initial disk read misses.
            // This exercises the real persistence worker, without mocking publication.
            guard file.path.withCString({ mkfifo($0, S_IRUSR | S_IWUSR) }) == 0 else { return nil }
            admission.continuation.yield(())
            return data
        })
        let tab = Tab(profileID: profile)
        defer { tab.tearDown() }
        tab.park(url: url, Parked(title: "Publication fixture"))
        cache?.load(for: tab)
        var admitted = admission.stream.makeAsyncIterator()
        let began = await admitted.next()
        XCTAssertNotNil(began)
        do {
            try await waitUntil { cache?.icon(for: url) != nil }
            XCTAssertNotNil(tab.favicon, "Tabs must show decoded artwork while its disk write is blocked")
            XCTAssertEqual(cache?.generation, 1, "Cache-only leaves must be notified before persistence finishes")
            XCTAssertTrue(cache?.icon(for: url) === tab.favicon)
        } catch {
            _ = await Self.drain(file)
            throw error
        }
        let persisted = await Self.drain(file)
        XCTAssertEqual(persisted, data, "Publication must not skip the authorized write")
        try await waitUntil { cache?.generation == 1 && tab.favicon != nil }
        weak var completing = cache
        cache = nil
        try await waitUntil { completing == nil }
    }

    func testPrivateOnlyFetchInPublicCacheDoesNotAuthorizePersistence() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), data = Self.artwork
        let url = URL(string: "https://private-public-cache-\(UUID().uuidString.lowercased()).invalid/")!
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache: Favicons? = Favicons(profileID: profile, fetch: { _ in data })
        let tab = Tab(isPrivate: true, profileID: profile)
        defer { tab.tearDown() }
        tab.park(url: url, Parked(title: "Private fixture"))
        cache?.load(for: tab)
        try await waitUntil { cache?.generation == 1 && tab.favicon != nil }
        // The warm task retains the cache through any authorized disk write and
        // pruning. Check privacy only once even an erroneous write would be finished.
        weak var completing = cache
        cache = nil
        try await waitUntil { completing == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(url.host!).path),
                       "A fetched private-only URL must not gain persistence authorization")
    }

    func testIncognitoCacheNeverWritesFetchedArtwork() async throws {
        TestEnvironment.prepare()
        let data = Self.artwork
        let url = URL(string: "https://incognito-publication-\(UUID().uuidString.lowercased()).invalid/")!
        let file = ProfileManager.faviconDir(for: Profile.incognito.id, in: Store.directory)
            .appendingPathComponent(url.host!)
        defer { try? FileManager.default.removeItem(at: file) }
        var cache: Favicons? = Favicons(profileID: Profile.incognito.id, fetch: { _ in data })
        // Even an accidentally persist-eligible caller cannot make this cache write.
        let tab = Tab(profileID: Profile.incognito.id)
        defer { tab.tearDown() }
        tab.park(url: url, Parked(title: "Incognito fixture"))
        cache?.load(for: tab)
        try await waitUntil { cache?.generation == 1 && tab.favicon != nil }
        weak var completing = cache
        cache = nil
        try await waitUntil { completing == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
