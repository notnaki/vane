import XCTest
@testable import vane

/// The request boundary is local; no completion test contacts a search provider.
private final class Feel03CompletionProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var starts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.starts += 1; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"["swift",["swift concurrency"]]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class Feel03RemoteTests: XCTestCase {
    func testRevokedConsentDuringDebounceDoesNotStartARequest() async throws {
        TestEnvironment.prepare()
        let suite = "vane.feel03.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = SearchSuggestions.defaults, previousSearch = Search.defaults
        SearchSuggestions.defaults = defaults
        Search.defaults = defaults
        Search.current = Search.defaultEngine
        SearchSuggestions.enabled = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Feel03CompletionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SearchSuggestions.defaults = previous
            Search.defaults = previousSearch
            UserDefaults.dropScratchSuite(suite)
        }
        Feel03CompletionProtocol.lock.withLock { Feel03CompletionProtocol.starts = 0 }
        let active = await SearchSuggestions.fetch("swift", using: session)
        XCTAssertEqual(active, ["swift concurrency"], "Prove this session reaches the protocol boundary")
        Feel03CompletionProtocol.lock.withLock { Feel03CompletionProtocol.starts = 0 }
        let debounce = DebounceFixture()
        defer { debounce.finish() }
        let pending = Task {
            await SearchSuggestions.fetch("swift", using: session, debounceSleep: debounce.sleep)
        }
        defer { pending.cancel() }
        try await debounce.waitUntil { debounce.count == 1 }
        SearchSuggestions.enabled = false
        debounce.release(0)
        let result = await pending.value
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(Feel03CompletionProtocol.lock.withLock { Feel03CompletionProtocol.starts }, 0)
    }
}
