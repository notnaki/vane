import XCTest
@testable import vane

/// Intercept the real resolver request without contacting a search provider.
private final class InstantResultProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var html = "<div class=\"result\"><a class=\"result__a\" href=\"https://docs.swift.org/\">Swift</a></div>"
        var error: URLError?
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply] = []
        private var recorded: [URLRequest] = []

        func reset(_ replies: [Reply] = []) {
            lock.lock(); defer { lock.unlock() }
            self.replies = replies
            recorded = []
        }

        func receive(_ request: URLRequest) -> Reply {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            return replies.isEmpty ? Reply() : replies.removeFirst()
        }

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class InstantLinksTests: XCTestCase {
    private func withSettings(_ body: (URLSession) async -> Void) async {
        TestEnvironment.prepare()
        let suite = "vane.instant.engine-tests.\(UUID())"
        let scratch = UserDefaults(suiteName: suite)!
        let savedSearch = Search.defaults
        let savedInstant = InstantLinks.defaults
        Search.defaults = scratch
        InstantLinks.defaults = scratch
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstantResultProtocol.self]
        let session = URLSession(configuration: configuration)
        InstantResultProtocol.state.reset()
        defer {
            session.invalidateAndCancel()
            Search.defaults = savedSearch
            InstantLinks.defaults = savedInstant
            UserDefaults.dropScratchSuite(suite)
        }
        await body(session)
    }

    private var custom: SearchEngine {
        SearchEngine(id: "fixture", name: "Fixture", queryTemplate: "https://search.example/?q=%s&mode=web")
    }

    func testEverySelectedEngineUsesDuckDuckGoResolver() async {
        await withSettings { _ in
            Search.add(custom)
            for engine in Search.all {
                Search.current = engine
                XCTAssertTrue(InstantLinks.shouldResolve("swift concurrency"),
                              "Shift+Return must use DuckDuckGo even with \(engine.name) selected")
            }
        }
    }

    func testEveryEngineSendsEncodedQueriesToDuckDuckGoAndOpensOrganicResult() async {
        await withSettings { session in
            Search.add(custom)
            let query = "swift & concurrency # examples+guide"
            for engine in Search.all {
                Search.current = engine
                InstantResultProtocol.state.reset()
                let targets = await InstantLinks.targets(for: query, using: session)
                XCTAssertEqual(targets.map(\.absoluteString), ["https://docs.swift.org/"])
                let requests = InstantResultProtocol.state.requests
                XCTAssertEqual(requests.count, 1, engine.name)
                let components = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
                XCTAssertEqual(components.scheme, "https")
                XCTAssertEqual(components.host, "html.duckduckgo.com")
                XCTAssertEqual(components.path, "/html/")
                XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query)])
                XCTAssertEqual(Search.current, engine, "Instant Links must not change the ordinary search preference")
                XCTAssertEqual(Search.url(for: "swift concurrency")?.host(), engine.home?.host())
            }
        }
    }

    func testResolutionFailuresAlwaysOpenDuckDuckGoResults() async {
        await withSettings { session in
            Search.add(custom)
            let failures: [InstantResultProtocol.Reply] = [
                .init(status: 202, html: "<html>challenge</html>"),
                .init(status: 500),
                .init(html: "<html>no results or changed markup</html>"),
                .init(error: URLError(.timedOut)),
                .init(error: URLError(.notConnectedToInternet)),
            ]
            for engine in Search.all {
                Search.current = engine
                for failure in failures {
                    InstantResultProtocol.state.reset([failure])
                    let targets = await InstantLinks.targets(for: "swift & concurrency", using: session)
                    XCTAssertEqual(targets.map(\.absoluteString),
                                   ["https://duckduckgo.com/?q=swift%20%26%20concurrency"], engine.name)
                    XCTAssertEqual(InstantResultProtocol.state.requests.count, 1)
                }
            }
        }
    }

    func testMultipleQueriesPreserveOrderAndLeaveAddressesAndBangsAlone() async {
        await withSettings { session in
            Search.current = Search.defaultEngine
            InstantResultProtocol.state.reset([.init(), .init(html: "no results")])
            let targets = await InstantLinks.targets(
                for: "swift docs, hacker news, https://example.com/path, !g swift", using: session)
            XCTAssertEqual(targets.map(\.absoluteString), [
                "https://docs.swift.org/", "https://duckduckgo.com/?q=hacker%20news",
                "https://example.com/path", "https://www.google.com/search?q=swift",
            ])
            let queries = InstantResultProtocol.state.requests.map {
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            }
            XCTAssertEqual(queries, ["swift docs", "hacker news"])
        }
    }

    func testPrivateDisabledAndNonSearchInputsKeepOrdinaryNavigationWithoutRequests() async {
        await withSettings { session in
            Search.add(custom)
            for engine in Search.all {
                Search.current = engine
                let normal = Search.search("swift concurrency")!
                let privateTargets = await InstantLinks.targets(for: "swift concurrency", isPrivate: true, using: session)
                XCTAssertEqual(privateTargets, [normal])
                let privateResult = await InstantLinks.topResult(for: "swift concurrency", isPrivate: true, using: session)
                XCTAssertNil(privateResult)
                InstantLinks.enabled = false
                let disabledTargets = await InstantLinks.targets(for: "swift concurrency", using: session)
                XCTAssertEqual(disabledTargets, [normal])
                InstantLinks.enabled = true
                for input in ["https://example.com/path", "localhost:8080", "!g swift docs", "?swift docs",
                              "!zzq swift docs", "swift docs !zzq"] {
                    XCTAssertFalse(InstantLinks.shouldResolve(input))
                    let targets = await InstantLinks.targets(for: input, using: session)
                    XCTAssertEqual(targets, [Search.url(for: input)!])
                }
            }
            XCTAssertTrue(InstantResultProtocol.state.requests.isEmpty)
        }
    }

    func testDuckDuckGoExtractionAndExistingPrivacyGates() {
        TestEnvironment.prepare()
        for (name, passed) in InstantLinks.check() { XCTAssertTrue(passed, name) }
    }
}
