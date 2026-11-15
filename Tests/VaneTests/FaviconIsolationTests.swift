import Foundation
import XCTest
@testable import vane

private final class FaviconRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: URLRequest?
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; latest = request }
    var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return latest }
}

private final class IsolatedFaviconProtocol: URLProtocol, @unchecked Sendable {
    static let capture = FaviconRequestCapture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.capture.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Set-Cookie": "favicon=tracking; Path=/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor final class FaviconIsolationTests: XCTestCase {
    @MainActor private final class FetchGate {
        var started = false
        var cancelled = false
        private var reply: CheckedContinuation<Data?, Never>?
        func fetch() async -> Data? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { reply in
                    self.reply = reply
                    started = true
                }
            } onCancel: {
                Task { @MainActor in self.cancelled = true }
            }
        }
        func finish(_ data: Data?) { reply?.resume(returning: data); reply = nil }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Favicon unit test timed out")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testProfilesAndPrivateBrowsingOwnSeparateStatelessSessions() async {
        TestEnvironment.prepare()
        let firstID = UUID(), secondID = UUID()
        let first = Favicons.cache(for: firstID), second = Favicons.cache(for: secondID)
        let privateCache = Favicons(profileID: Profile.incognito.id)
        XCTAssertTrue(Favicons.cache(for: firstID).session === first.session)
        XCTAssertFalse(first.session === second.session)
        XCTAssertFalse(first.session === privateCache.session)
        for cache in [first, second, privateCache] {
            let configuration = cache.session.configuration
            XCTAssertNil(configuration.httpCookieStorage)
            XCTAssertFalse(configuration.httpShouldSetCookies)
            XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
            XCTAssertNil(configuration.urlCache)
            XCTAssertNil(configuration.urlCredentialStorage)
            XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        }
        await Favicons.forget(firstID).value
        await Favicons.forget(secondID).value
        await privateCache.retire().value
    }

    func testFetchDisablesCookieHandlingAndNetworkCaching() async throws {
        TestEnvironment.prepare()
        let cache = Favicons(profileID: UUID())
        let configuration = cache.session.configuration
        configuration.protocolClasses = [IsolatedFaviconProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let data = await Favicons.fetch(URL(string: "https://favicon-unit.invalid/icon")!, session: session)
        XCTAssertEqual(data, Data([1, 2, 3]))
        let request = try XCTUnwrap(IsolatedFaviconProtocol.capture.request)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
        await cache.retire().value
    }

    func testRedirectDelegateAppliesCookieAndCredentialPolicyAgain() {
        TestEnvironment.prepare()
        let cache = Favicons(profileID: UUID())
        let url = URL(string: "https://favicon-unit.invalid/redirected")!
        var dirty = URLRequest(url: url)
        dirty.httpShouldHandleCookies = true
        dirty.setValue("tracking=secret", forHTTPHeaderField: "Cookie")
        dirty.setValue("Basic secret", forHTTPHeaderField: "Authorization")
        dirty.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = cache.session.dataTask(with: url)
        let policy = FaviconRequestPolicy()
        var redirected: URLRequest?
        policy.urlSession(cache.session, task: task, willPerformHTTPRedirection: response, newRequest: dirty) {
            redirected = $0
        }
        XCTAssertNotNil(redirected)
        XCTAssertEqual(redirected?.httpShouldHandleCookies, false)
        XCTAssertEqual(redirected?.cachePolicy, .reloadIgnoringLocalCacheData)
        for header in ["Cookie", "Authorization", "Proxy-Authorization"] {
            XCTAssertNil(redirected?.value(forHTTPHeaderField: header))
        }
        dirty.url = URL(string: "file:///tmp/favicon")!
        policy.urlSession(cache.session, task: task, willPerformHTTPRedirection: response, newRequest: dirty) {
            redirected = $0
        }
        XCTAssertNil(redirected)
        task.cancel()
    }

    func testRetirementCancelsAndDrainsLateFetchWithoutPublishingOrWriting() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), gate = FetchGate()
        let cache = Favicons(profileID: profile, fetch: { _ in await gate.fetch() })
        let url = URL(string: "https://retired-favicon.invalid/")!
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        defer { gate.finish(nil); try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(cache.icon(for: url))
        try await waitUntil { gate.started }
        let retirement = cache.retire()
        var drained = false
        let completion = Task { await retirement.value; drained = true }
        try await waitUntil { gate.cancelled }
        XCTAssertFalse(drained, "Retirement must await work even if it ignores cancellation")
        let artwork = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="))
        XCTAssertNotNil(Favicons.image(from: artwork))
        gate.finish(artwork)
        await completion.value
        XCTAssertTrue(drained)
        XCTAssertEqual(cache.generation, 0)
        XCTAssertNil(cache.icon(for: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeletedProfileCannotAcquireANewLiveCache() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), cache = Favicons.cache(for: profile)
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("visited.invalid"))
        await Favicons.forget(profile, retiring: true).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(cache.icon(for: URL(string: "https://visited.invalid/")!))
        let stale = Favicons.cache(for: profile)
        XCTAssertNil(stale.icon(for: URL(string: "https://never-contact.invalid/")!))
        await stale.retire().value
    }
}
