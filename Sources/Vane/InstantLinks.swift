import Foundation

/// Instant Links — Shift+Return on a search skips the results page and opens the top
/// organic result directly. A comma-separated input resolves several at once, one tab each.
///
/// PRIVACY — read this before wiring it to a key.
/// Pressing Return on a search sends the query to the engine anyway, so this feature does
/// not leak a query the user was not about to send. What it *does* do is send it from the
/// app rather than from the WebView, and — because only one engine's results are parseable
/// without an API key — send it to DuckDuckGo even when the user's chosen engine is Google.
/// That is the honest cost, and the reasons it is still on by default:
///
///   * It only ever fires on an explicit Shift+Return. Unlike `SearchSuggestions`, nothing
///     goes out while the user is still typing, so there is no half-formed-thought leak.
///   * A private window never resolves. `isPrivate` is threaded in from the window, same
///     as the suggestion path, because only the window knows.
///   * Input that is already a url is never sent anywhere. `shouldResolve` reuses the
///     address bar's own decision table, so `example.com`, `localhost:3000`, a bare IP, a
///     file path and a `!bang` all skip resolution and just navigate.
///   * Ephemeral session: no cookies sent, none stored, no cache.
///
/// ponytail: string scanning, no HTML parser. Ceiling is that a markup change breaks
/// extraction — which is why every extracted href is validated before it is returned, and
/// why a failure falls back to the ordinary results page instead of guessing.
@MainActor enum InstantLinks {

    /// Swapped out by `check()` so the assertions never touch the user's real preferences.
    static var defaults = UserDefaults.standard

    /// ON by default, unlike remote suggestions. The gesture *is* the consent: a user who
    /// never presses Shift+Return never sends a byte, and a user who does has asked for
    /// exactly this. `object(forKey:)` is consulted because absent must mean on, and
    /// `bool(forKey:)` returns false for absent.
    static var enabled: Bool {
        get { defaults.object(forKey: "instantLinks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "instantLinks") }
    }

    /// A page load is what this replaces, so it may take a page load's worth of time — but
    /// not more, because the fallback (open the results page) is instant and always right.
    static let timeout: TimeInterval = 6

    /// DuckDuckGo's no-JavaScript endpoint. Verified with curl: it returns server-rendered
    /// markup with the organic results as plain `<a class="result__a">` anchors carrying
    /// absolute hrefs, and no "people also ask" / video carousel / knowledge panel blocks
    /// at all — those simply do not exist in this template.
    ///
    /// ponytail: this is the *only* engine used, whatever the user picked. Google and Bing
    /// serve a JavaScript wall to a plain GET (verified: zero organic links in the body),
    /// Ecosia answers 403, and Brave's markup is a different extractor's worth of work for
    /// one more engine. Respecting the user's engine here would mean shipping four
    /// scrapers that each rot separately. Ceiling: if Brave ever matters, it is a second
    /// entry in a dictionary of (endpoint, anchor class), not a rewrite.
    static let endpoint = "https://html.duckduckgo.com/html/?q="

    /// The endpoint tailors its markup to the agent and has served nothing at all to some.
    /// Same string WebKit sends, so what we parse is what the user would have seen.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Hosts that are never an answer: a redirector we failed to unwrap, a settings link,
    /// an ad hop. If the top result really is duckduckgo.com the user can search for it.
    static let engineHosts = ["duckduckgo.com", "duck.com", "duckduckgo.co"]

    // MARK: - Splitting a multi-query input

    /// `swift docs, hacker news, weather` → three queries, three tabs.
    ///
    /// Comma, because that is what Arc uses and what a user typing a list already reaches
    /// for. A quoted segment protects its commas, so `"san francisco, ca" weather` stays
    /// one query. The quotes are left in the query rather than stripped: they are also a
    /// phrase operator on every engine, and a user who typed them meant them.
    ///
    /// Empty and whitespace-only segments are dropped, so a trailing comma — which is what
    /// a half-typed list looks like — costs nothing.
    static func split(_ input: String) -> [String] {
        var out: [String] = []
        var segment = ""
        var quoted = false
        for c in input {
            if c == "\"" { quoted.toggle(); segment.append(c) }
            else if c == "," && !quoted { out.append(segment); segment = "" }
            else { segment.append(c) }
        }
        out.append(segment)                        // an unterminated quote keeps its tail
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: - The gate

    /// Everything that must be true before a query is allowed to leave the machine.
    ///
    /// The last line is the "already a url" guard, and it is the address bar's own answer
    /// rather than a second copy of that logic: if `Search.url(for:)` would do anything
    /// other than search for this string verbatim — navigate to a host, open a file, route
    /// a bang — then there is no search to skip and nothing to resolve.
    static func shouldResolve(_ query: String, isPrivate: Bool = false) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !isPrivate, !q.isEmpty else { return false }
        return Search.url(for: q) == Search.search(q)
    }

    // MARK: - Extraction

    /// The first organic result in a DuckDuckGo HTML results body, or nil.
    ///
    /// nil is a perfectly good answer — the caller opens the results page instead. Every
    /// branch below prefers nil to a link it is not sure about, because a wrong tab is
    /// worse than a results page.
    static func extract(_ html: String) -> URL? {
        // Each result row opens `<div class="result …">`. Splitting on that is all the
        // structure this page needs; the chunk that follows runs past the row's end, but
        // the row's own `result__a` is the first one in it, so "first match wins" is right.
        for chunk in html.components(separatedBy: "<div class=\"result").dropFirst() {
            let classes = chunk.prefix { $0 != "\"" }
            // `result` has to have been a whole class token. Without this, the row's inner
            // `result__extras` / `result__body` divs match too and an ad row's skip could
            // be undone by its own children.
            guard classes.isEmpty || classes.first == " " else { continue }
            // Ads and sponsored rows carry a modifier class. Skipping the row (not just
            // the link) is what keeps the ad's own children from being reconsidered.
            guard !classes.contains("--ad"), !classes.contains("sponsored") else { continue }
            guard let href = anchor(class: "result__a", in: chunk),
                  let url = validate(unwrap(href)) else { continue }
            return url
        }
        return nil
    }

    /// The href of the first anchor carrying `class`. Bounded to that one tag — `<` before
    /// and `>` after — so an attribute order of `href` then `class` cannot make this return
    /// the *next* link's url, which is the one failure mode that would be silent.
    static func anchor(class name: String, in html: some StringProtocol) -> String? {
        guard let c = html.range(of: "class=\"\(name)\""),
              let open = html[..<c.lowerBound].lastIndex(of: "<"),
              let close = html[c.upperBound...].firstIndex(of: ">") else { return nil }
        let tag = html[open...close]
        guard let h = tag.range(of: "href=\"") else { return nil }
        return String(tag[h.upperBound...].prefix { $0 != "\"" })
    }

    /// Absolutises and un-redirects an href.
    ///
    /// DuckDuckGo wraps some results as `/l/?uddg=<the real url>&rut=…` (and the `&` comes
    /// back HTML-escaped). Following it here rather than letting the tab do it means the
    /// history row and the address bar show the destination, not the hop.
    static func unwrap(_ href: String) -> URL? {
        var s = href.replacingOccurrences(of: "&amp;", with: "&")
        if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("/") { s = "https://duckduckgo.com" + s }
        guard let c = URLComponents(string: s) else { return nil }
        // queryItems percent-decodes for us, so the wrapped url comes back whole.
        if let inner = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: inner)
        }
        return c.url
    }

    /// The last line of defence: absolute http(s), a real host, not the engine's own.
    static func validate(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), host.contains(".") else { return nil }
        // Any duckduckgo host means we are still inside the engine — an unwrapped
        // redirector, a `y.js` ad hop, a "settings" link — not a result.
        guard !engineHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    // MARK: - Fetch

    /// Ephemeral, so a resolution carries no cookie and leaves none behind.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)
    }()

    /// The top organic result for `query`, or nil for a suppressed query, a request that
    /// failed or timed out, a body that does not parse, or a link that does not validate.
    /// Never a guess.
    ///
    /// The `statusCode == 200` line is load-bearing, not ceremony: the endpoint answers a
    /// too-fast caller with `202` and a CAPTCHA page that parses to nothing anyway, and
    /// checking the code turns that into an obvious no rather than a mysterious one.
    static func topResult(for query: String, isPrivate: Bool = false) async -> URL? {
        guard shouldResolve(query, isPrivate: isPrivate),
              let url = URL(string: endpoint + encode(query)) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return extract(html)
    }

    /// One url per query, in the order typed. A query that cannot be resolved falls back to
    /// its own ordinary address-bar destination — the results page for a search, the site
    /// itself for something that was a url all along — so a tab is never silently dropped.
    ///
    /// Sequential, and that is not laziness for its own sake: resolving three queries in a
    /// TaskGroup was measured against the live endpoint and DuckDuckGo answered the burst
    /// with `202` and a CAPTCHA page, so two of the three fell back. One at a time, the same
    /// three all resolved. ponytail: ceiling is that a five-query input takes five round
    /// trips and may still trip the limiter — at which point the extra tabs open on their
    /// results pages, which is exactly what pressing plain Return would have done.
    static func targets(for input: String, isPrivate: Bool = false) async -> [URL] {
        // Worked out up front: every query already has an answer before a single request
        // goes out, which is what makes "fall back" a one-liner instead of a code path.
        let planned = split(input).compactMap { q in Search.url(for: q).map { (q, $0) } }
        guard enabled, !isPrivate else { return planned.map(\.1) }
        var out: [URL] = []
        for (query, fallback) in planned { out.append(await topResult(for: query) ?? fallback) }
        return out
    }

    /// RFC 3986 unreserved set, same rule as Search.encode — a query holding & or # must
    /// not be able to rewrite the endpoint url.
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    // MARK: - check

    /// A real body, captured once with `curl https://html.duckduckgo.com/html/?q=swift+concurrency`
    /// and frozen here, trimmed to the results container and its first three rows. The
    /// assertions run offline against it — a check that needs the network is a check that
    /// fails on a plane, and none of this is testing that DuckDuckGo is up.
    ///
    /// The captured page carried no ads (this endpoint served none for any query tried), so
    /// the ad-skipping assertion below uses `adFixture`, hand-written around DuckDuckGo's
    /// `result--ad` modifier class. That one is modelled, not captured — said plainly here
    /// rather than left to look like evidence it is not.
    static let fixture = ##"""
    <div id="links" class="results">
                    <div class="result results_links results_links_deep web-result ">
                      <div class="links_main links_deep result__body"> <!-- This is the visible part -->
                          <h2 class="result__title">
                            <a rel="nofollow" class="result__a" href="https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/">Concurrency - Documentation</a>
                          </h2>
                          <div class="result__extras">
                            <div class="result__extras__url">
                              <span class="result__icon">
                                <a rel="nofollow" href="https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/">
                                  <img class="result__icon__img" width="16" height="16" alt="" src="//external-content.duckduckgo.com/ip3/docs.swift.org.ico" name="i15" />
                                </a>
                              </span>
                              <a class="result__url" href="https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/">
                                docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
                              </a>
                            </div>
                          </div>
                            <a class="result__snippet" href="https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/">Learn how to use <b>Swift</b>'s built-in support for writing asynchronous and parallel code in a structured way.</a>
                        <div class="clear"></div>
                      </div>
                    </div>
                    <div class="result results_links results_links_deep web-result ">
                      <div class="links_main links_deep result__body"> <!-- This is the visible part -->
                          <h2 class="result__title">
                            <a rel="nofollow" class="result__a" href="https://developer.apple.com/documentation/swift/concurrency">Concurrency | Apple Developer Documentation</a>
                          </h2>
                          <div class="result__extras">
                            <div class="result__extras__url">
                              <span class="result__icon">
                                <a rel="nofollow" href="https://developer.apple.com/documentation/swift/concurrency">
                                  <img class="result__icon__img" width="16" height="16" alt="" src="//external-content.duckduckgo.com/ip3/developer.apple.com.ico" name="i15" />
                                </a>
                              </span>
                              <a class="result__url" href="https://developer.apple.com/documentation/swift/concurrency">
                                developer.apple.com/documentation/swift/concurrency
                              </a>
                            </div>
                          </div>
                            <a class="result__snippet" href="https://developer.apple.com/documentation/swift/concurrency">Perform asynchronous and parallel operations. Code along with the WWDC presenter to elevate a SwiftUI app with <b>Swift</b> <b>concurrency</b>.</a>
                        <div class="clear"></div>
                      </div>
                    </div>
                    <div class="result results_links results_links_deep web-result ">
                      <div class="links_main links_deep result__body"> <!-- This is the visible part -->
                          <h2 class="result__title">
                            <a rel="nofollow" class="result__a" href="https://www.hackingwithswift.com/quick-start/concurrency">Swift Concurrency by Example - free quick start tutorials for Swift ...</a>
                          </h2>
                          <div class="result__extras">
                            <div class="result__extras__url">
                              <span class="result__icon">
                                <a rel="nofollow" href="https://www.hackingwithswift.com/quick-start/concurrency">
                                  <img class="result__icon__img" width="16" height="16" alt="" src="//external-content.duckduckgo.com/ip3/www.hackingwithswift.com.ico" name="i15" />
                                </a>
                              </span>
                              <a class="result__url" href="https://www.hackingwithswift.com/quick-start/concurrency">
                                www.hackingwithswift.com/quick-start/concurrency
                              </a>
                            </div>
                          </div>
                            <a class="result__snippet" href="https://www.hackingwithswift.com/quick-start/concurrency"><b>Swift</b> <b>Concurrency</b> by Example is the largest free book teaching all aspects of <b>Swift</b> <b>concurrency</b>.</a>
                        <div class="clear"></div>
                      </div>
                    </div>
    """##

    /// Hand-written, not captured — see the note on `fixture`. An ad row ahead of an
    /// organic one, with the ad's link wrapped in the redirector so both the skip and the
    /// unwrap are exercised by one body.
    static let adFixture = ##"""
    <div id="links" class="results">
      <div class="result results_links results_links_deep result--ad result--ad--small">
        <div class="links_main">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/y.js?ad_domain=sponsor.example&amp;u3=https%3A%2F%2Fsponsor.example%2F">Sponsored</a>
          </h2>
          <div class="result__extras"><div class="result__extras__url">
            <a class="result__url" href="//duckduckgo.com/y.js?ad_domain=sponsor.example">sponsor.example</a>
          </div></div>
        </div>
      </div>
      <div class="result results_links results_links_deep web-result ">
        <div class="links_main links_deep result__body">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Freal.example%2Fpage%3Fa%3D1%26b%3D2&amp;rut=deadbeef">Real Result</a>
          </h2>
        </div>
      </div>
    """##

    /// Offline assertions. Runs against a throwaway defaults suite, so the user's engine,
    /// custom engines and toggle are neither read nor written. No network: `topResult` and
    /// `targets` are not called here, only the pure halves they are built from.
    static func check() -> [(String, Bool)] {
        let suite = "vane.instant.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let (realMine, realSearch) = (defaults, Search.defaults)
        defaults = scratch
        Search.defaults = scratch
        defer {
            defaults = realMine
            Search.defaults = realSearch
            scratch.removePersistentDomain(forName: suite)
        }

        var results: [(String, Bool)] = [
            // Read before anything below writes the key.
            ("instant links are on until the user turns them off", enabled == true),
            ("the toggle round-trips off", { enabled = false; return enabled == false }()),
            ("the toggle round-trips back on", { enabled = true; return enabled == true }()),
        ]

        // The splitter. Pure, and the branchiest thing here.
        results += [
            ("a single query splits to itself", split("swift concurrency") == ["swift concurrency"]),
            ("commas split", split("swift docs, hacker news, weather") == ["swift docs", "hacker news", "weather"]),
            ("segments are trimmed", split("  a  ,   b  ") == ["a", "b"]),
            ("a trailing comma adds no query", split("a, b,") == ["a", "b"]),
            ("a leading comma adds no query", split(", a") == ["a"]),
            ("an empty segment in the middle is dropped", split("a,,b") == ["a", "b"]),
            ("commas alone yield nothing", split(",,,") == []),
            ("an empty input yields nothing", split("") == []),
            ("a whitespace-only input yields nothing", split("   \n ") == []),
            ("a quoted comma does not split",
             split("\"san francisco, ca\" weather") == ["\"san francisco, ca\" weather"]),
            ("quotes are kept, because they are also a phrase operator",
             split("\"exact phrase\"") == ["\"exact phrase\""]),
            ("a quoted segment sits alongside unquoted ones",
             split("a, \"b, c\", d") == ["a", "\"b, c\"", "d"]),
            ("an unterminated quote keeps its tail in one query",
             split("a, \"b, c") == ["a", "\"b, c"]),
            ("a query with no comma but a quote is untouched",
             split("weather in \"nyc\"") == ["weather in \"nyc\""]),
        ]

        // The "is this already a url" guard. Nothing here is allowed to hit the network.
        Search.current = Search.builtIn[0]
        enabled = true
        results += [
            ("an ordinary phrase resolves", shouldResolve("swift concurrency")),
            ("a private window never resolves", !shouldResolve("swift concurrency", isPrivate: true)),
            ("with the toggle off nothing resolves",
             { enabled = false; defer { enabled = true }; return !shouldResolve("swift concurrency") }()),
            ("a bare hostname is already a url and never resolves", !shouldResolve("example.com")),
            ("a full url never resolves", !shouldResolve("https://example.com/a?b=1")),
            ("localhost never resolves", !shouldResolve("localhost:3000")),
            ("a bare ip never resolves", !shouldResolve("192.168.1.7")),
            ("an ipv6 literal never resolves", !shouldResolve("[::1]:8080")),
            ("a mailto never resolves", !shouldResolve("mailto:ada@example.com")),
            ("a bang routes to its engine rather than resolving", !shouldResolve("!g swift")),
            ("the empty query never resolves", !shouldResolve("")),
            ("a whitespace-only query never resolves", !shouldResolve("   \n ")),
            ("a phrase with a dot in it still resolves", shouldResolve("swift 6.2 concurrency")),
        ]

        // Extraction, against the real captured body.
        results += [
            ("the first organic result is extracted from a real body",
             extract(fixture)?.absoluteString
                == "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/"),
            ("the row's own link wins, not a later row's",
             extract(fixture)?.host == "docs.swift.org"),
            ("a body with no results extracts nothing rather than guessing",
             extract("<html><body><p>no results</p></body></html>") == nil),
            ("a rate-limit page extracts nothing",
             extract("<html>If this error persists, please let us know</html>") == nil),
            ("an empty body extracts nothing", extract("") == nil),
            // The one that matters if DuckDuckGo renames its anchor class: fail, do not
            // fall through to some other link on the page.
            ("a renamed anchor class fails rather than picking a neighbour",
             extract(fixture.replacingOccurrences(of: "result__a", with: "result__link")) == nil),
        ]

        // Ads and redirectors.
        results += [
            ("a sponsored row is skipped and the organic one below it wins",
             extract(adFixture)?.absoluteString == "https://real.example/page?a=1&b=2"),
            ("the redirector is unwrapped to the destination",
             unwrap("//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fx%3Fy%3D1&amp;rut=abc")?.absoluteString
                == "https://example.com/x?y=1"),
            ("a root-relative redirector is unwrapped too",
             unwrap("/l/?uddg=https%3A%2F%2Fexample.com%2F")?.absoluteString == "https://example.com/"),
            ("a protocol-relative href gets https",
             unwrap("//example.com/x")?.absoluteString == "https://example.com/x"),
            ("a plain absolute href survives unwrapping unchanged",
             unwrap("https://example.com/a")?.absoluteString == "https://example.com/a"),
        ]

        // Validation. Everything that must NOT be returned.
        func bad(_ s: String) -> Bool { validate(unwrap(s)) == nil }
        results += [
            ("a good result validates", validate(unwrap("https://example.com/a")) != nil),
            ("http validates too", validate(unwrap("http://example.com/a")) != nil),
            ("the engine's own host is rejected", bad("https://duckduckgo.com/settings")),
            ("an engine subdomain is rejected", bad("https://html.duckduckgo.com/html/?q=x")),
            ("a duck.com link is rejected", bad("https://duck.com/about")),
            ("an unwrapped ad redirector is rejected as the engine's own host",
             bad("//duckduckgo.com/y.js?ad_domain=sponsor.example")),
            ("a javascript: href is rejected", bad("javascript:void(0)")),
            ("a data: href is rejected", bad("data:text/html,<b>hi</b>")),
            ("a mailto: href is rejected", bad("mailto:ada@example.com")),
            ("a relative href that stays on the engine is rejected", bad("/html/?q=next")),
            ("a hostless href is rejected", bad("https:///nohost")),
            ("a host with no dot is rejected", bad("http://intranet/")),
            ("an empty href is rejected", bad("")),
        ]
        return results
    }
}
