import Foundation

/// Live query completions from the current search engine, for the address bar.
///
/// PRIVACY — read this before turning it on anywhere.
/// Every other suggestion in this browser is computed from the user's own SQLite file and
/// never leaves the machine. This one is different in kind: it sends what is being typed,
/// keystroke by keystroke, to a third party that logs it. That is the entire trade — the
/// address bar gets noticeably better at guessing, and in exchange the search engine sees
/// the half-typed thoughts the user never pressed Return on. It is not a small trade, so:
///
///   * `enabled` is off unless the user turns it on. No "helpful" default, no first-run
///     opt-out flow that everyone clicks through.
///   * A private window never asks, at all. Private browsing that phones home per keystroke
///     is not private browsing.
///   * Anything that could be a url, a host, a file path or a credential is withheld even
///     when the feature is on — `looksLikeURL` is deliberately over-eager. A false positive
///     costs one missing completion list; a false negative hands an internal hostname or a
///     pasted password to Bing.
///   * The request goes out on an ephemeral session: no cookies sent, none stored, no cache,
///     so consecutive queries are not trivially linkable to each other or to the user's
///     logged-in session with that engine.
///
/// ponytail: raw endpoint urls and JSONSerialization, no Codable models — these are two
/// array shapes between them and the engines have never versioned them. Ceiling: an engine
/// that changes shape degrades to "no completions", never to a crash.
@MainActor enum SearchSuggestions {

    /// Swapped out by `check()` so the assertions never touch the user's real preferences.
    static var defaults = UserDefaults.standard

    /// OFF by default — see the privacy note above. `object(forKey:)` is not consulted
    /// because there is no third state: absent means off, which is what `bool` returns.
    static var enabled: Bool {
        get { defaults.bool(forKey: "searchSuggestions") }
        set { defaults.set(newValue, forKey: "searchSuggestions") }
    }

    /// Hard cap on completions. The address bar shows a handful; asking for more only
    /// widens what gets sent back and how much of the screen the list eats.
    static let limit = 8
    /// Long enough that a fast typist's middle keystrokes never reach the wire, short
    /// enough that the list feels like it is keeping up.
    static let debounce = Duration.milliseconds(150)
    /// A completion that lands after the user finished typing is worthless, so failing
    /// fast is better than being right late.
    static let timeout: TimeInterval = 2

    // MARK: - Endpoints

    /// The two JSON shapes in the wild, both verified against live responses:
    ///   `.phrases`    → `[{"phrase":"swift concurrency"}, …]`            (DuckDuckGo)
    ///   `.openSearch` → `["swift conc", ["swift concurrency", …], …]`    (everyone else)
    enum Shape { case phrases, openSearch }

    /// engine id → (endpoint prefix, response shape). An engine that is missing here — Kagi,
    /// which has no public completion endpoint, and every custom engine the user adds — is
    /// not an error: it simply has no completions, and `fetch` returns an empty array.
    static let endpoints: [String: (prefix: String, shape: Shape)] = [
        "duckduckgo": ("https://duckduckgo.com/ac/?q=", .phrases),
        "google":     ("https://suggestqueries.google.com/complete/search?client=firefox&q=", .openSearch),
        "bing":       ("https://api.bing.com/osjson.aspx?query=", .openSearch),
        "brave":      ("https://search.brave.com/api/suggest?q=", .openSearch),
        "ecosia":     ("https://ac.ecosia.org/autocomplete?type=list&q=", .openSearch),
    ]

    /// Nothing is trusted about the body beyond "it is JSON": every cast is optional and
    /// every failure is an empty list.
    static func parse(_ data: Data, engine id: String) -> [String] {
        guard let shape = endpoints[id]?.shape,
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let phrases: [String]
        switch shape {
        case .phrases:
            phrases = ((json as? [[String: Any]]) ?? []).compactMap { $0["phrase"] as? String }
        case .openSearch:
            // Element 0 echoes the query and later elements are engine-specific metadata
            // (Google ships a `google:suggestsubtypes` dictionary); only element 1 matters.
            phrases = ((json as? [Any])?.dropFirst().first as? [String]) ?? []
        }
        return Array(phrases.filter { !$0.isEmpty }.prefix(limit))
    }

    // MARK: - The privacy gate

    /// Everything that must be true before a keystroke is allowed to leave the machine.
    /// `isPrivate` is a parameter rather than global state because only the window knows.
    static func shouldSend(_ query: String, isPrivate: Bool = false) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Two characters matches what Store.suggest already refuses to act on, and an empty
        // field is the one case where an outbound request would be pure telemetry.
        guard enabled, !isPrivate, q.count >= 2 else { return false }
        return !looksLikeURL(q)
    }

    /// Over-eager on purpose. The cheap explicit tests catch what the address bar would
    /// happily search for anyway — an email address, a pasted `user:pass@host`, an absolute
    /// path that does not exist on this machine — and the last line reuses the address bar's
    /// own decision table, so localhost, bare IPs, `host:port` and any real hostname are all
    /// withheld without a second copy of that logic living here.
    static func looksLikeURL(_ s: String) -> Bool {
        if s.contains("://") || s.contains("@") { return true }
        if s.hasPrefix("/") || s.hasPrefix("~/") { return true }
        return Search.url(for: s) != Search.search(s)
    }

    // MARK: - Fetch

    /// Ephemeral, so a completion request carries no cookie and leaves none behind.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    /// Monotonic "which query is newest" counter. The in-flight Task is cancelled when a
    /// newer query arrives, but cancellation is cooperative and a socket read that already
    /// completed cannot be un-completed — so the token is what actually guarantees a stale
    /// body is dropped instead of overwriting a newer list.
    private static var latest = 0
    private static var inFlight: Task<[String], Never>?

    static func stamp() -> Int { latest += 1; return latest }
    static func isCurrent(_ token: Int) -> Bool { token == latest }

    /// Completions for `query` from the current engine. Empty — never a throw — for a
    /// suppressed query, an engine with no endpoint, a timeout, a broken body, or a
    /// response that a newer query has already made stale.
    static func fetch(_ query: String, isPrivate: Bool = false) async -> [String] {
        guard shouldSend(query, isPrivate: isPrivate) else { return [] }
        let id = Search.current.id
        guard let endpoint = endpoints[id],
              let url = URL(string: endpoint.prefix + encode(query)) else { return [] }

        let token = stamp()
        inFlight?.cancel()
        let task = Task { () -> [String] in
            // The debounce sits inside the cancellable Task, so a keystroke superseded
            // within the window never opens a connection at all.
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let (data, _) = try? await session.data(from: url) else { return [] }
            return parse(data, engine: id)
        }
        inFlight = task
        let phrases = await task.value
        guard isCurrent(token) else { return [] }
        return phrases
    }

    /// RFC 3986 unreserved set, same rule as Search.encode — a query holding & or # must
    /// not be able to rewrite the endpoint url.
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    // MARK: - Merge

    /// Local history and bookmarks first, then remote completions, as one ranked list.
    /// Local always wins: it is free, it is private, and it is what the user has actually
    /// visited.
    static func merged(_ query: String, local: [Suggestion], isPrivate: Bool = false) async -> [Suggestion] {
        merge(query, local: local, remote: await fetch(query, isPrivate: isPrivate))
    }

    /// The pure half, so `check()` can prove the de-duplication with no network.
    ///
    /// A remote completion is expressed as an ordinary `Suggestion`: `title` is the phrase,
    /// `url` is where pressing Return on it goes. Nothing had to change in `Suggestion` —
    /// ponytail: the ceiling is that the list cannot draw a magnifying glass instead of a
    /// favicon for these, because there is no field saying which is which. If the redesigned
    /// address bar wants that, add `var completion = false` to Suggestion with a default.
    static func merge(_ query: String, local: [Suggestion], remote: [String]) -> [Suggestion] {
        var seen = Set(local.flatMap { [key($0.title), key($0.url)] })
        seen.insert(key(query))          // never offer back exactly what was typed
        var out = local
        for phrase in remote {
            guard out.count < limit, let u = Search.search(phrase) else { continue }
            // Both keys: the phrase against local titles, and the url it would open against
            // local urls — otherwise two rows could share an id, which ForEach cannot draw.
            let fresh = seen.insert(key(phrase)).inserted
            guard seen.insert(key(u.absoluteString)).inserted, fresh else { continue }
            out.append(Suggestion(url: u.absoluteString, title: phrase, bookmarked: false))
        }
        return out
    }

    /// "https://www.Example.com/" and "example.com" are the same row to a user.
    private static func key(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    // MARK: - check

    /// Real response bodies, captured once with curl against the live endpoints and frozen
    /// here. The assertions below run offline against these — a check that needs the network
    /// is a check that fails on a plane, and none of this is testing that DuckDuckGo is up.
    static let fixtures: [String: String] = [
        "duckduckgo": #"[{"phrase":"swift concurrency"},{"phrase":"swift concert tickets"},{"phrase":"swift concert cincinnati dates"},{"phrase":"swift concert cincinnati venue"},{"phrase":"swift concert cincinnati photos"},{"phrase":"swift concert cincinnati parking"},{"phrase":"swift concert cincinnati reviews"},{"phrase":"swift concert cincinnati setlist"}]"#,
        "google": #"["swift conc",["swift concurrency","@concurrent swift","swift concurrency tutorial","swift concurrency course","swift concert","swift concurrency skill","swift concurrency book","swift-concurrency-extras","swift concurrency by example","swift concurrency wwdc"],[],{"google:suggestsubtypes":[[512],[22,30,10],[22,30],[22,30],[22,30],[22,30],[22,30],[22,30,10],[22,30],[22,30]]}]"#,
        "bing": #"["swift conc",["swift concurrency","swift concert tickets","swift concert cincinnati dates","swift concert cincinnati venue","swift concert cincinnati photos","swift concert cincinnati parking","swift concert cincinnati reviews","swift concert cincinnati setlist","swift concert cincinnati tickets","swift concert cincinnati covid-19","swift concert cincinnati live stream","swift concert cincinnati opening act"]]"#,
        "brave": #"["swift conc",["swift concurrency","swift concurrency skill","swift concatenate string","swift concurrency tutorial","swift concatenate string and int","swift concurrency book","swift concurrency example","swift concat string"]]"#,
        "ecosia": #"["swift conc",["swift concurrency","swift concert tickets","swift concert cincinnati dates","swift concert cincinnati venue","swift concert cincinnati photos","swift concert cincinnati parking","swift concert cincinnati reviews","swift concert cincinnati setlist"]]"#,
    ]

    static func check() -> [(String, Bool)] {
        let suite = "vane.suggest.check.\(ProcessInfo.processInfo.processIdentifier)"
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
            // The default that matters most. Read before anything below writes the key.
            ("remote suggestions are off until the user turns them on", enabled == false),
        ]

        // Parsing, against the captured bodies. Each engine's own first completion, so a
        // fixture pasted into the wrong slot fails rather than passing by coincidence.
        func body(_ id: String) -> Data { Data((fixtures[id] ?? "").utf8) }
        results += [
            ("duckduckgo's phrase objects parse",
             parse(body("duckduckgo"), engine: "duckduckgo").first == "swift concurrency"),
            ("duckduckgo yields all 8 of its completions",
             parse(body("duckduckgo"), engine: "duckduckgo").count == 8),
            ("google's 4-element array parses past its metadata",
             parse(body("google"), engine: "google").first == "swift concurrency"),
            ("google's second completion survives an @ in the phrase",
             parse(body("google"), engine: "google")[1] == "@concurrent swift"),
            ("bing's opensearch array parses",
             parse(body("bing"), engine: "bing").first == "swift concurrency"),
            ("brave's opensearch array parses",
             parse(body("brave"), engine: "brave")[2] == "swift concatenate string"),
            ("ecosia's opensearch array parses",
             parse(body("ecosia"), engine: "ecosia").last == "swift concert cincinnati setlist"),
            // Bing returned 12 and Google 10; neither is allowed to fill the address bar.
            ("more completions than the cap are truncated",
             parse(body("bing"), engine: "bing").count == limit
                && parse(body("google"), engine: "google").count == limit),
            ("an engine with no endpoint parses to nothing rather than failing",
             parse(body("duckduckgo"), engine: "kagi").isEmpty),
            ("a body that is not json parses to nothing",
             parse(Data("<html>rate limited</html>".utf8), engine: "google").isEmpty),
            ("kagi and custom engines have no endpoint",
             endpoints["kagi"] == nil && endpoints["mine"] == nil),
        ]

        // The gate. Everything here is about what does NOT go out.
        Search.current = Search.builtIn[0]
        enabled = false
        results += [
            ("the toggle round-trips on", { enabled = true; return enabled }()),
            ("with the toggle off nothing is sent",
             { enabled = false; defer { enabled = true }; return !shouldSend("swift concurrency") }()),
            ("a private window never sends, even with the toggle on",
             !shouldSend("swift concurrency", isPrivate: true)),
            ("an ordinary phrase is sent", shouldSend("swift concurrency")),
            ("the empty query is never sent", !shouldSend("")),
            ("a whitespace-only query is never sent", !shouldSend("   \n ")),
            ("a one-character query is never sent", !shouldSend("s")),
            ("a full url is never sent", !shouldSend("https://bank.example.com/statement")),
            ("a bare hostname is never sent", !shouldSend("internal.corp.example")),
            ("localhost is never sent", !shouldSend("localhost:3000")),
            ("a bare ip is never sent", !shouldSend("192.168.1.7")),
            ("an email address is never sent", !shouldSend("ada@example.com")),
            ("a url carrying credentials is never sent", !shouldSend("https://ada:hunter2@host.example")),
            ("a phrase containing an @ handle is never sent", !shouldSend("mail ada@example.com now")),
            ("an absolute file path is never sent", !shouldSend("/Users/ada/taxes/2025.pdf")),
            ("a ~ file path is never sent", !shouldSend("~/Documents/passwords.txt")),
            ("a phrase with a dot in it is still sent", shouldSend("swift 6.2 concurrency")),
        ]

        // Merge + de-duplication. Local first, no repeats, capped.
        let local = [
            Suggestion(url: "https://swift.org/concurrency", title: "Swift Concurrency", bookmarked: true),
            Suggestion(url: "https://www.example.com/", title: "Example", bookmarked: false),
        ]
        let remote = ["swift concurrency",          // dupe of a local title, different case
                      "swift Concurrency",          // dupe of the one above
                      "example.com",                // dupe of a local url once normalised
                      "swift conc",                 // exactly what was typed
                      "swift concurrency tutorial", // the first genuinely new one
                      "swift actors", "swift sendable", "swift tasks", "swift async",
                      "swift macros",               // 6 new + 2 local == the cap
                      "swift generics"]             // one past it
        let m = merge("swift conc", local: local, remote: remote)
        results += [
            ("local suggestions come first and keep their order",
             Array(m.prefix(2)) == local),
            ("a completion matching a local title is dropped",
             m.filter { $0.title.lowercased() == "swift concurrency" }.count == 1),
            ("a completion matching a local url is dropped",
             !m.contains { $0.title == "example.com" }),
            ("the query itself is not offered back", !m.contains { $0.title == "swift conc" }),
            ("a new completion is kept", m.contains { $0.title == "swift concurrency tutorial" }),
            ("a completion opens a search for its own phrase",
             m.first { $0.title == "swift concurrency tutorial" }?.url
                == "https://duckduckgo.com/?q=swift%20concurrency%20tutorial"),
            ("completions are not bookmarks", m.allSatisfy { $0.bookmarked == false || local.contains($0) }),
            ("every row has a distinct id", Set(m.map(\.id)).count == m.count),
            ("the merged list is capped",
             m.count == limit && !m.contains { $0.title == "swift generics" }),
            ("with the toggle off merge still returns the local list",
             merge("swift conc", local: local, remote: []) == local),
        ]

        // Staleness. Two queries in flight, the older one's body must be discarded.
        let older = stamp()
        let newer = stamp()
        results += [
            ("the newest query's response is accepted", isCurrent(newer)),
            ("a response from an older query is discarded", !isCurrent(older)),
            ("a second response for the newest query is still accepted", isCurrent(newer)),
        ]
        return results
    }
}
