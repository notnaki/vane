import XCTest
@testable import vane

@MainActor final class BangScopeTests: XCTestCase {
    func testWordsAndNamesOfferExactShortcuts() {
        TestEnvironment.prepare()
        XCTAssertEqual(Bangs.activation("youtube")?.engine.keyword, "yt")
        XCTAssertEqual(Bangs.activation("YouTube cats & dogs")?.query, "cats & dogs")
        XCTAssertEqual(Bangs.activation("twitter")?.engine.keyword, "x")
        XCTAssertEqual(Bangs.activation("github swift")?.engine.keyword, "gh")
        XCTAssertEqual(Bangs.activation("yt cats")?.engine.keyword, "yt")
        XCTAssertNil(Bangs.activation("you"))
        XCTAssertNil(Bangs.activation("youtube.com"))
        XCTAssertNil(Bangs.activation("?youtube cats"))
        XCTAssertNil(Bangs.activation("cats youtube"))
    }

    func testExplicitBangsActivateOnlyOnceDelimited() {
        TestEnvironment.prepare()
        XCTAssertNil(Bangs.activation("!yt", explicitOnly: true))
        XCTAssertEqual(Bangs.activation("!yt ", explicitOnly: true)?.engine.keyword, "yt")
        XCTAssertEqual(Bangs.activation("!YT cats", explicitOnly: true)?.query, "cats")
        XCTAssertEqual(Bangs.activation("!youtube cats", explicitOnly: true)?.engine.keyword, "yt")
        XCTAssertEqual(Bangs.activation("!twitter cats", explicitOnly: true)?.engine.keyword, "x")
        XCTAssertEqual(Bangs.activation("cats !yt ", explicitOnly: true)?.query, "cats")
        XCTAssertNil(Bangs.activation("cats !g", explicitOnly: true),
                     "A trailing !g must remain editable so the user can finish !gh")
        XCTAssertNil(Bangs.activation("youtube cats", explicitOnly: true))
        XCTAssertNil(Bangs.activation("!unknown cats", explicitOnly: true))
        XCTAssertNil(Bangs.activation("?cats !yt ", explicitOnly: true),
                     "The leading ? forces a literal search even with a trailing bang")
    }

    func testScopeSearchTreatsQueriesLiterallyAndSupportsEmptyHomepage() {
        TestEnvironment.prepare()
        let engine = Bangs.lookup("yt")!
        XCTAssertEqual(Bangs.scopedURL("", using: engine)?.absoluteString, "https://www.youtube.com")
        XCTAssertEqual(Bangs.scopedURL("cats & dogs", using: engine)?.absoluteString,
                       "https://www.youtube.com/results?search_query=cats%20%26%20dogs")
        XCTAssertEqual(Bangs.scopedURL("!gh swift", using: engine)?.absoluteString,
                       "https://www.youtube.com/results?search_query=%21gh%20swift")
        XCTAssertEqual(Bangs.scopedURL("example.com", using: engine)?.absoluteString,
                       "https://www.youtube.com/results?search_query=example.com")
        // Word scopes require explicit activation; ordinary searches still mean what was typed.
        XCTAssertNil(Bangs.resolve("youtube cats"))
    }

    func testCustomKeywordsKeepPrecedenceOverSiteNames() {
        TestEnvironment.prepare()
        let old = Bangs.defaults
        let suite = "vane.bang-scope.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        Bangs.defaults = defaults
        defer { Bangs.defaults = old; defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Bangs.add(.init(bang: "youtube", "My videos", "https://videos.example/?q=%s")),
                       .accepted(replaced: false, shadows: false))
        XCTAssertEqual(Bangs.activation("youtube")?.engine.name, "My videos")
    }

    func testSiteScopeIncludesSubdomainsButRejectsSimilarHosts() {
        let engine = Bangs.lookup("yt")!
        XCTAssertTrue(Bangs.contains(URL(string: "https://youtube.com/watch?v=1"), in: engine))
        XCTAssertTrue(Bangs.contains(URL(string: "https://m.youtube.com/watch?v=1"), in: engine))
        XCTAssertFalse(Bangs.contains(URL(string: "https://notyoutube.com/"), in: engine))
        XCTAssertFalse(Bangs.contains(URL(string: "https://youtube.com.evil.example/"), in: engine))
        XCTAssertFalse(Bangs.contains(nil, in: engine))
    }

    func testAdditionalDefaultSitesSupportBothWordsAndBangs() {
        TestEnvironment.prepare()
        let sites: [(word: String, keyword: String, url: String)] = [
            ("twitch", "twitch", "https://www.twitch.tv/search?term=cats%20%26%20dogs"),
            ("tiktok", "tiktok", "https://www.tiktok.com/search?q=cats%20%26%20dogs"),
            ("pinterest", "pinterest", "https://www.pinterest.com/search/pins/?q=cats%20%26%20dogs"),
            ("imdb", "imdb", "https://www.imdb.com/find/?q=cats%20%26%20dogs"),
            ("soundcloud", "soundcloud", "https://soundcloud.com/search?q=cats%20%26%20dogs"),
            ("vimeo", "vimeo", "https://vimeo.com/search?q=cats%20%26%20dogs"),
            ("etsy", "etsy", "https://www.etsy.com/search?q=cats%20%26%20dogs"),
            ("goodreads", "goodreads", "https://www.goodreads.com/search?q=cats%20%26%20dogs"),
            ("letterboxd", "letterboxd", "https://letterboxd.com/search/cats%20%26%20dogs/"),
            ("medium", "medium", "https://medium.com/search?q=cats%20%26%20dogs"),
            ("bluesky", "bluesky", "https://bsky.app/search?q=cats%20%26%20dogs"),
            ("DEV.to", "devto", "https://dev.to/search?q=cats%20%26%20dogs"),
            ("dribbble", "dribbble", "https://dribbble.com/search/cats%20%26%20dogs"),
            ("behance", "behance", "https://www.behance.net/search/projects?search=cats%20%26%20dogs"),
            ("target", "target", "https://www.target.com/s?searchTerm=cats%20%26%20dogs"),
            ("unsplash", "unsplash", "https://unsplash.com/s/photos/cats%20%26%20dogs"),
            ("pexels", "pexels", "https://www.pexels.com/search/cats%20%26%20dogs/"),
            ("gitlab", "gitlab", "https://gitlab.com/search?search=cats%20%26%20dogs"),
        ]
        for site in sites {
            XCTAssertEqual(Bangs.activation(site.word)?.engine.keyword, site.keyword, site.word)
            XCTAssertEqual(Bangs.resolve("!\(site.keyword) cats & dogs")?.absoluteString, site.url, site.keyword)
        }
    }
}
