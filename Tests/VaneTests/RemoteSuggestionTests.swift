import XCTest
@testable import vane

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    func reset() { lock.lock(); defer { lock.unlock() }; value = 0 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Intercept the real URLSession boundary; no request reaches an external engine.
private final class CompletionProtocol: URLProtocol, @unchecked Sendable {
    static let requests = RequestCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.increment()
        let body = Data(#"["swift",["swift concurrency"]]"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class RemoteSuggestionTests: XCTestCase {
    func testCancelingTheOriginatingTaskPreventsTheRemoteRequest() async throws {
        TestEnvironment.prepare()
        let suite = "vane.remote-test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previousSuggest = SearchSuggestions.defaults, previousSearch = Search.defaults
        SearchSuggestions.defaults = defaults
        Search.defaults = defaults
        SearchSuggestions.enabled = true
        Search.current = Search.defaultEngine
        defer {
            SearchSuggestions.defaults = previousSuggest
            Search.defaults = previousSearch
            UserDefaults.dropScratchSuite(suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        CompletionProtocol.requests.reset()

        // First prove the same session intercepts a valid completion request.
        let active = await SearchSuggestions.fetch("swift", using: session)
        XCTAssertEqual(active, ["swift concurrency"])
        XCTAssertEqual(CompletionProtocol.requests.count, 1)
        CompletionProtocol.requests.reset()

        let pending = Task { await SearchSuggestions.fetch("swift", using: session) }
        // Allow fetch to enter its debounce, as it does before the next keystroke.
        try await Task.sleep(for: .milliseconds(25))
        pending.cancel()
        let phrases = await pending.value
        XCTAssertTrue(phrases.isEmpty)
        XCTAssertEqual(CompletionProtocol.requests.count, 0,
                       "A canceled query must never reach the URLSession boundary")
    }
}
