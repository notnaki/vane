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
    func testRemoteResultsArriveWhileHistoryIsStillPending() async throws {
        TestEnvironment.prepare()
        let gate = DebounceFixture()
        defer { gate.finish() }
        var updates: [[Suggestion]] = []
        let pending = Task {
            await SearchSuggestions.stream("swift", local: {
                try? await gate.sleep(.zero)
                return [Suggestion(url: "https://swift.org", title: "Swift", bookmarked: true)]
            }, remote: { ["swift concurrency"] }, publish: { updates.append($0) })
        }
        defer { pending.cancel() }
        try await gate.waitUntil { gate.count == 1 }
        // History remains blocked until a completion is visible. This catches the
        // serial lookup that made remote results wait behind a full history scan.
        do {
            try await gate.waitUntil { updates.first?.first?.title == "swift concurrency" }
        } catch {
            XCTFail("Online suggestions must appear before the history scan finishes")
        }
        gate.release(0)
        await pending.value
        XCTAssertEqual(updates.last?.map(\.title), ["Swift", "swift concurrency"])
    }

    func testHistoryResultsDoNotWaitForTheNetwork() async throws {
        TestEnvironment.prepare()
        let gate = DebounceFixture()
        defer { gate.finish() }
        var updates: [[Suggestion]] = []
        let pending = Task {
            await SearchSuggestions.stream("swift", local: {
                [Suggestion(url: "https://swift.org", title: "Swift", bookmarked: true)]
            }, remote: {
                try? await gate.sleep(.zero)
                return ["swift concurrency", "Swift"]
            }, publish: { updates.append($0) })
        }
        defer { pending.cancel() }
        try await gate.waitUntil { gate.count == 1 && updates.first?.first?.title == "Swift" }
        XCTAssertEqual(updates.first?.count, 1)
        gate.release(0)
        await pending.value
        XCTAssertEqual(updates.last?.map(\.title), ["Swift", "swift concurrency"],
                       "Local pages must keep priority and deduplicate engine completions")
    }

    func testCancelledPipelineDoesNotPublishLateResults() async throws {
        TestEnvironment.prepare()
        let gate = DebounceFixture()
        defer { gate.finish() }
        var updates: [[Suggestion]] = []
        let pending = Task {
            await SearchSuggestions.stream("swift", local: {
                try? await gate.sleep(.zero)
                return [Suggestion(url: "https://swift.org", title: "Swift", bookmarked: true)]
            }, remote: {
                try? await gate.sleep(.zero)
                return ["swift concurrency"]
            }, publish: { updates.append($0) })
        }
        defer { pending.cancel() }
        try await gate.waitUntil { gate.count == 2 }
        pending.cancel()
        gate.finish()
        await pending.value
        XCTAssertTrue(updates.isEmpty, "Closing or replacing a query must discard both sources")
    }

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

        let debounce = DebounceFixture()
        defer { debounce.finish() }
        let pending = Task {
            await SearchSuggestions.fetch("swift", using: session, debounceSleep: debounce.sleep)
        }
        defer { pending.cancel() }
        // Cancel only once fetch has entered its debounce, regardless of runner load.
        try await debounce.waitUntil { debounce.count == 1 }
        pending.cancel()
        debounce.release(0)
        let phrases = await pending.value
        XCTAssertTrue(phrases.isEmpty)
        XCTAssertEqual(CompletionProtocol.requests.count, 0,
                       "A canceled query must never reach the URLSession boundary")
    }
}
