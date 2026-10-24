import AppKit
import WebKit
import XCTest
@testable import vane

private actor FaviconRecoveryRequests {
    private var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
    func count(_ url: URL) -> Int { urls.filter { $0 == url }.count }
    var total: Int { urls.count }
}

@MainActor final class FaviconEvictionRecoveryTests: XCTestCase {
    private static let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)

    private func waitUntil(line: UInt = #line, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Favicon recovery condition timed out", line: line)
                throw NSError(domain: "FaviconRecoveryFixtureTimeout line \(line)", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loadIconPage(_ html: String, page: URL, artwork: URL, in tab: Tab) async throws {
        let web = tab.web
        // The injected cache owns this fixture's icons. Tab's didFinish would also
        // start the profile cache, whose failed lookup could clear the injected result.
        web.navigationDelegate = nil
        web.loadHTMLString(html, baseURL: page)
        try await waitUntil { tab.currentURL == page && !web.isLoading }
        XCTAssertEqual(web.url, page)
        let declared = Favicons.declared(try await web.evaluateJavaScript(Favicons.linkJS))
        XCTAssertEqual(declared, [artwork], "The loaded document must supply the real icon declaration")
    }

    func testLegacyDiskCachedSVGLoadsOnWorkerWithoutNetworkOrRewritingOriginal() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), requests = FaviconRecoveryRequests(), data = Self.svg
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "http://cached-svg.invalid/")!
        let file = directory.appendingPathComponent("cached-svg.invalid")
        try data.write(to: file)
        let cache = Favicons(profileID: profile, fetch: { url in
            await requests.record(url)
            return nil
        })
        XCTAssertNil(cache.icon(for: url), "Vector decoding must leave the calling UI actor")
        try await waitUntil { cache.generation == 1 }
        let image = try XCTUnwrap(cache.icon(for: url))
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(bitmap.width, 64)
        XCTAssertLessThanOrEqual(bitmap.height, 64)
        let fetched = await requests.total
        XCTAssertEqual(fetched, 0)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testRejectedDiskIconPreservesNegativeCacheAcrossRepeatedLookups() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), requests = FaviconRecoveryRequests()
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "http://rejected-disk-icon.invalid/")!
        try Data("corrupt cached icon".utf8).write(to: directory.appendingPathComponent("rejected-disk-icon.invalid"))
        let cache = Favicons(profileID: profile, fetch: { url in
            await requests.record(url)
            return nil
        })
        XCTAssertNil(cache.icon(for: url))
        try await waitUntil { await requests.total == 1 }
        // Give each UI lookup its own event-loop turn: a rejected disk decode must not
        // bypass the fallback's existing ten-minute negative cache on a later lookup.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(cache.icon(for: url))
        }
        try await Task.sleep(for: .milliseconds(20))
        let fetched = await requests.total
        XCTAssertEqual(fetched, 1, "Rejected cached bytes must not restart the failed fallback during its retry delay")
    }

    func testEvictedPrivateIconRefetchesUnchangedDeclarationForFreshTab() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let requests = FaviconRecoveryRequests(), data = Self.svg
        let cache = Favicons(profileID: Profile.incognito.id, fetch: { url in
            await requests.record(url)
            return data
        })
        let page = URL(string: "http://127.0.0.1:1/fixture")!
        let artwork = URL(string: "http://127.0.0.1:1/declared.svg")!
        let html = "<link rel='icon' href='\(artwork.absoluteString)'><p>Private icon fixture</p>"
        let first = Tab(isPrivate: true), replacement = Tab(isPrivate: true)
        defer { first.tearDown(); replacement.tearDown() }
        try await loadIconPage(html, page: page, artwork: artwork, in: first)
        cache.load(for: first)
        try await waitUntil { cache.generation == 1 }
        XCTAssertNotNil(first.favicon)
        // Only the first host has declarations. Successful root fallbacks must still
        // evict its image without letting retained discovery metadata suppress recovery.
        for index in 0..<300 {
            XCTAssertNil(cache.icon(for: URL(string: "http://fill-\(index).invalid/")!))
        }
        try await waitUntil { cache.generation == 301 }
        try await loadIconPage(html, page: page, artwork: artwork, in: replacement)
        cache.load(for: replacement)
        try await waitUntil { await requests.count(artwork) == 2 }
        try await waitUntil { replacement.favicon != nil }
        let fetches = await requests.count(artwork)
        XCTAssertEqual(fetches, 2, "A matching declaration is reusable only while its image is available")
    }
}
