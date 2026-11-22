import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor private final class FaviconPerPageNavigation: NSObject, WKNavigationDelegate {
    var expected: WKNavigation?
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === expected { finished = true }
    }
}

/// Issue #756: two rows on one host each declare their own icon, and loading one must not
/// replace the other's.
@MainActor final class FaviconPerPageTests: XCTestCase {
    private static func artwork(_ fill: String) -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='\(fill)'/></svg>".utf8)
    }

    private func colour(_ image: NSImage?) -> String? {
        guard let bitmap = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let pixel = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return pixel[0] > pixel[2] ? "red" : "blue"
    }

    private func open(_ tab: Tab, at page: URL, declaring icon: URL) async throws {
        let web = tab.web
        let navigation = FaviconPerPageNavigation()
        web.navigationDelegate = navigation
        defer { web.navigationDelegate = nil }
        navigation.expected = try XCTUnwrap(web.loadHTMLString(
            "<html><head><link rel='icon' href='\(icon.absoluteString)'></head><body>Page</body></html>",
            baseURL: page))
        try await compatibilityWait { navigation.finished && tab.currentURL == page && !web.isLoading }
        tab.kind = .pinned
        XCTAssertTrue(tab.atHome)
    }

    func testEachPinnedRowOnOneHostKeepsItsOwnIconAcrossLoadsAndRelaunch() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let docs = URL(string: "http://127.0.0.1:1/document")!
        let sheets = URL(string: "http://127.0.0.1:1/spreadsheets")!
        let unvisited = URL(string: "http://127.0.0.1:1/unvisited")!
        let docsIcon = URL(string: "http://127.0.0.1:1/docs.svg")!
        let sheetsIcon = URL(string: "http://127.0.0.1:1/sheets.svg")!
        let red = Self.artwork("red"), blue = Self.artwork("blue")
        let cache = Favicons(profileID: profile, fetch: { url in
            url == docsIcon ? red : url == sheetsIcon ? blue : nil
        })
        let a = Tab(profileID: profile), b = Tab(profileID: profile), waiting = Tab(profileID: profile)
        let restoredA = Tab(profileID: profile), restoredB = Tab(profileID: profile)
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        defer {
            [a, b, waiting, restoredA, restoredB].forEach { $0.tearDown() }
            Favicons.forget(profile)
            Store.forget(profile)
            try? FileManager.default.removeItem(at: directory)
        }

        waiting.park(url: unvisited, Parked(title: "No icon of its own yet"))
        cache.load(for: waiting)
        try await open(a, at: docs, declaring: docsIcon)
        cache.load(for: a)
        try await compatibilityWait { a.favicon != nil && waiting.favicon != nil }
        let own = try XCTUnwrap(a.favicon)
        XCTAssertEqual(colour(own), "red")
        XCTAssertTrue(waiting.favicon === own, "A row with no icon of its own falls back to its host's")

        try await open(b, at: sheets, declaring: sheetsIcon)
        cache.load(for: b)
        try await compatibilityWait { self.colour(b.favicon) == "blue" }
        XCTAssertTrue(a.favicon === own, "Loading one row must not replace another row's icon on that host")
        XCTAssertTrue(waiting.favicon === own, "The fallback a row already shows is not replaced either")
        XCTAssertTrue(cache.icon(for: docs) === own)
        XCTAssertTrue(cache.icon(for: sheets) === b.favicon)

        // What a relaunch has: the files, a cold cache, and parked rows with no page to ask.
        let files = [docs: red, sheets: blue].map { (directory.appendingPathComponent(Favicons.pageKey(for: $0)!), $1) }
        try await compatibilityWait { files.allSatisfy { (try? Data(contentsOf: $0)) == $1 } }
        let relaunched = Favicons(profileID: profile, fetch: { _ in nil })
        restoredA.park(url: docs, Parked(title: "Docs"))
        restoredB.park(url: sheets, Parked(title: "Sheets"))
        relaunched.load(for: restoredA)
        relaunched.load(for: restoredB)
        try await compatibilityWait {
            self.colour(restoredA.favicon) == "red" && self.colour(restoredB.favicon) == "blue"
                && self.colour(relaunched.icon(for: docs)) == "red"
                && self.colour(relaunched.icon(for: sheets)) == "blue"
        }
        try await compatibilityWait { relaunched.icon(for: unvisited) != nil }
        XCTAssertEqual(colour(restoredA.favicon), "red", "The host's fallback arriving later leaves a row's own icon alone")
    }
}
