import XCTest
@testable import vane

@MainActor final class InstantLinksTests: XCTestCase {
    private func withSettings(_ body: () async -> Void) async {
        TestEnvironment.prepare()
        let suite = "vane.instant.engine-tests.\(UUID())"
        let scratch = UserDefaults(suiteName: suite)!
        let savedSearch = Search.defaults
        let savedInstant = InstantLinks.defaults
        Search.defaults = scratch
        InstantLinks.defaults = scratch
        defer {
            Search.defaults = savedSearch
            InstantLinks.defaults = savedInstant
            UserDefaults.dropScratchSuite(suite)
        }
        await body()
    }

    func testOtherEnginesNeverUseDuckDuckGoResolver() async {
        await withSettings {
            for engine in Search.builtIn where engine.id != "duckduckgo" {
                Search.current = engine
                XCTAssertFalse(InstantLinks.shouldResolve("swift concurrency"),
                               "\(engine.name) searches must not go to DuckDuckGo")
            }
            let custom = SearchEngine(id: "fixture", name: "Fixture", queryTemplate: "https://search.example/?q=%s")
            Search.add(custom)
            Search.current = custom
            XCTAssertFalse(InstantLinks.shouldResolve("swift concurrency"))
            Search.current = Search.builtIn.first { $0.id == "duckduckgo" }!
            XCTAssertTrue(InstantLinks.shouldResolve("swift concurrency"))
        }
    }

    func testGoogleAndKagiUseTheirOwnFirstResultNavigation() async {
        await withSettings {
            let query = "swift & concurrency # examples+guide"
            for id in ["google", "kagi"] {
                let engine = Search.builtIn.first { $0.id == id }!
                Search.current = engine
                let targets = await InstantLinks.targets(for: query)
                XCTAssertEqual(targets.count, 1)
                let components = URLComponents(url: targets[0], resolvingAgainstBaseURL: false)!
                XCTAssertEqual(components.host, engine.home?.host())
                XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value,
                               id == "kagi" ? "! " + query : query)
                XCTAssertEqual(components.queryItems?.first { $0.name == "btnI" }?.value,
                               id == "google" ? "1" : nil)
            }
        }
    }

    func testUnsupportedEnginesKeepTheirOwnResultsAndQueryOrder() async {
        await withSettings {
            let custom = SearchEngine(id: "fixture", name: "Fixture", queryTemplate: "https://search.example/?q=%s&mode=web")
            Search.add(custom)
            for engine in Search.builtIn.filter({ ["bing", "brave", "ecosia"].contains($0.id) }) + [custom] {
                Search.current = engine
                let targets = await InstantLinks.targets(for: "swift docs, hacker news")
                XCTAssertEqual(targets, [Search.search("swift docs")!, Search.search("hacker news")!])
            }
        }
    }

    func testPrivateDisabledAndNonSearchInputsKeepOrdinaryNavigation() async {
        await withSettings {
            for engine in Search.builtIn {
                Search.current = engine
                let normal = Search.search("swift concurrency")!
                let privateTargets = await InstantLinks.targets(for: "swift concurrency", isPrivate: true)
                XCTAssertEqual(privateTargets, [normal])
                InstantLinks.enabled = false
                let disabledTargets = await InstantLinks.targets(for: "swift concurrency")
                XCTAssertEqual(disabledTargets, [normal])
                InstantLinks.enabled = true
                for input in ["https://example.com/path", "localhost:8080", "!g swift docs"] {
                    XCTAssertNil(InstantLinks.firstResultNavigation(for: input, using: engine))
                    XCTAssertFalse(InstantLinks.shouldResolve(input))
                    let targets = await InstantLinks.targets(for: input)
                    XCTAssertEqual(targets, [Search.url(for: input)!])
                }
            }
        }
    }

    func testDuckDuckGoExtractionAndExistingPrivacyGates() {
        TestEnvironment.prepare()
        for (name, passed) in InstantLinks.check() { XCTAssertTrue(passed, name) }
    }
}
