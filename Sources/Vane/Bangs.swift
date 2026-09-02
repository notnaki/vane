import Foundation

/// A bang is a `SearchEngine` with a keyword where its id would be — same record, same
/// `%s` template, same `home`, same encoder, same `Codable` shape.
///
/// ponytail: this is the whole reconciliation with "custom engines already act as bangs by
/// id". There is no second type, no second persistence format and no second resolver. A
/// bang and an engine differ only in *which list* they live in, and that is the difference
/// that matters: engines show up in the Search Engine picker and can be `Search.current`,
/// bangs do not and cannot. Same data, two lists, one lookup.
typealias Bang = SearchEngine

extension SearchEngine {
    /// Reads better than `.init(id:name:queryTemplate:)` in a forty-row table.
    init(bang: String, _ name: String, _ template: String) {
        self.init(id: bang, name: name, queryTemplate: template)
    }

    /// The bang spelling of `id`, so call sites do not have to pretend a keyword is an id.
    var keyword: String { id }
}

/// `!gh swift concurrency` → GitHub. `swift concurrency !gh` → the same place.
///
/// WHY THIS EXISTS AT ALL. Until Google became the default engine, Vane shipped no bang
/// table: an unrecognised bang was handed to the current engine intact, and that was the
/// right answer *only* because DuckDuckGo resolves thousands of its own server-side. On
/// Google, `!gh swift` is a literal search for the string "!gh swift". Changing the default
/// engine broke a feature nobody had written down, so the feature is written down here.
///
/// The table is deliberately small — roughly forty rows a developer actually types, not a
/// mirror of DuckDuckGo's index. Every template in it was resolved live with curl against a
/// real query before it shipped; anything that 404'd, dropped the query on a redirect, or
/// answered with a bot wall was cut rather than shipped broken. The ones that survived only
/// as a client-rendered shell are marked in the table.
///
/// ponytail: no bang *index*, no download, no update channel. Forty rows compiled in, plus
/// whatever the user adds. Ceiling: the table goes stale and a site changes its query
/// parameter — which is why `Bangs.add` exists, so a user can fix one without a release.
@MainActor enum Bangs {

    // MARK: - The table

    /// Verified live, one query each, before shipping. `%s` is the percent-encoded query.
    ///
    /// A few of these are jumps rather than searches, because the site has no server-side
    /// search worth pointing at: `!man` uses manpages.debian.org's `/jump`, `!brew` goes
    /// straight to the formula page (and 404s on a name that is not a formula), and `!w`
    /// / `!dict` / `!aw` use MediaWiki's search box, which lands on the article when the
    /// query names one exactly and shows results when it does not.
    static let builtIn: [Bang] = [
        // Engines. `!g`, `!ddg` and `!b` are here rather than left to engine-id matching so
        // that `!b` is unambiguously Bing — as an id prefix it also matches "brave".
        .init(bang: "g",        "Google",           "https://www.google.com/search?q=%s"),
        .init(bang: "ddg",      "DuckDuckGo",       "https://duckduckgo.com/?q=%s"),
        .init(bang: "b",        "Bing",             "https://www.bing.com/search?q=%s"),

        // Development.
        .init(bang: "gh",       "GitHub",           "https://github.com/search?q=%s"),
        .init(bang: "gist",     "GitHub Gist",      "https://gist.github.com/search?q=%s"),
        .init(bang: "mdn",      "MDN",              "https://developer.mozilla.org/en-US/search?q=%s"),
        .init(bang: "npm",      "npm",              "https://www.npmjs.com/search?q=%s"),
        .init(bang: "pypi",     "PyPI",             "https://pypi.org/search/?q=%s"),
        .init(bang: "crates",   "crates.io",        "https://crates.io/search?q=%s"),
        .init(bang: "docsrs",   "docs.rs",          "https://docs.rs/releases/search?query=%s"),
        .init(bang: "go",       "Go Packages",      "https://pkg.go.dev/search?q=%s"),
        .init(bang: "docker",   "Docker Hub",       "https://hub.docker.com/search?q=%s"),
        .init(bang: "man",      "Man Pages",        "https://manpages.debian.org/jump?q=%s"),
        .init(bang: "brew",     "Homebrew",         "https://formulae.brew.sh/formula/%s"),
        .init(bang: "cheat",    "cheat.sh",         "https://cheat.sh/%s"),
        .init(bang: "caniuse",  "Can I Use",        "https://caniuse.com/?search=%s"),
        .init(bang: "rfc",      "RFC Editor",       "https://www.rfc-editor.org/search/?q=%s"),

        // Reference.
        .init(bang: "w",        "Wikipedia",        "https://en.wikipedia.org/w/index.php?search=%s"),
        .init(bang: "wa",       "Wolfram Alpha",    "https://www.wolframalpha.com/input?i=%s"),
        .init(bang: "dict",     "Wiktionary",       "https://en.wiktionary.org/w/index.php?search=%s"),
        .init(bang: "ud",       "Urban Dictionary", "https://www.urbandictionary.com/define.php?term=%s"),
        .init(bang: "scholar",  "Google Scholar",   "https://scholar.google.com/scholar?q=%s"),
        .init(bang: "arxiv",    "arXiv",            "https://arxiv.org/search/?query=%s&searchtype=all"),
        .init(bang: "aw",       "Arch Wiki",        "https://wiki.archlinux.org/index.php?search=%s"),

        // Tools.
        .init(bang: "tr",       "Google Translate", "https://translate.google.com/?sl=auto&tl=en&op=translate&text=%s"),
        .init(bang: "maps",     "Google Maps",      "https://www.google.com/maps/search/%s"),
        .init(bang: "osm",      "OpenStreetMap",    "https://www.openstreetmap.org/search?query=%s"),
        .init(bang: "archive",  "Wayback Machine",  "https://web.archive.org/web/*/%s"),
        .init(bang: "gimg",     "Google Images",    "https://www.google.com/search?q=%s&udm=2"),
        .init(bang: "emoji",    "Emojipedia",       "https://emojipedia.org/search?q=%s"),
        .init(bang: "unicode",  "Unicode Explorer", "https://unicode-explorer.com/search/?q=%s"),

        // Media.
        .init(bang: "yt",       "YouTube",          "https://www.youtube.com/results?search_query=%s"),
        .init(bang: "steam",    "Steam",            "https://store.steampowered.com/search/?term=%s"),
        .init(bang: "spotify",  "Spotify",          "https://open.spotify.com/search/%s"),

        // Shopping.
        .init(bang: "a",        "Amazon",           "https://www.amazon.com/s?k=%s"),
        .init(bang: "ebay",     "eBay",             "https://www.ebay.com/sch/i.html?_nkw=%s"),

        // Social.
        .init(bang: "hn",       "Hacker News",      "https://hn.algolia.com/?q=%s"),
        .init(bang: "r",        "Reddit",           "https://www.reddit.com/search/?q=%s"),
        .init(bang: "x",        "X",                "https://x.com/search?q=%s"),
        .init(bang: "lobsters", "Lobsters",         "https://lobste.rs/search?q=%s"),
    ]

    // MARK: - User-defined bangs

    /// The same defaults object `Search` uses, so `check()` swapping one swaps both and a
    /// bang assertion can never touch the user's real list.
    static var defaults: UserDefaults {
        get { Search.defaults }
        set { Search.defaults = newValue }
    }

    /// Persisted as `[SearchEngine]` under its own key — a separate list from
    /// `customSearchEngines` precisely so a user's bang never appears in the Search Engine
    /// picker and can never become `Search.current` by accident.
    static var custom: [Bang] {
        get {
            guard let data = defaults.data(forKey: "customBangs") else { return [] }
            return (try? JSONDecoder().decode([Bang].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "customBangs") }
    }

    /// What `add` decided. `.accepted` still carries what happened, because "I replaced the
    /// one you already had" and "this now overrides a built-in" are both things a settings
    /// screen should be able to say out loud instead of silently doing.
    enum AddResult: Equatable {
        case accepted(replaced: Bool, shadows: Bool)
        case rejected(String)
    }

    /// Validates, normalises and stores. The keyword may be typed with or without its `!`
    /// and is stored without one, lowercased — otherwise `!GH` and `!gh` would be two rows
    /// and only one of them would ever fire.
    ///
    /// Rejection returns the reason as a sentence rather than a bool, because the caller is
    /// a text field and the user needs to know which of four things was wrong.
    @discardableResult
    static func add(_ bang: Bang) -> AddResult {
        let keyword = normalise(bang.keyword)
        guard !keyword.isEmpty else { return .rejected("A bang needs a keyword.") }
        guard !keyword.contains(where: \.isWhitespace) else {
            return .rejected("A bang keyword cannot contain spaces.")
        }
        let template = bang.queryTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.components(separatedBy: "%s").count == 2 else {
            return .rejected("The address needs exactly one %s where the search words go.")
        }
        // Substituting a probe is the only honest parse test: the raw template contains %s,
        // which is not a legal percent-escape, so URL(string:) rejects it before it is filled.
        guard let probe = URL(string: template.replacingOccurrences(of: "%s", with: "vane")),
              let scheme = probe.scheme?.lowercased(), probe.host != nil else {
            return .rejected("That address does not parse once the search words are filled in.")
        }
        // http/https only. A bang is a keystroke away from an address bar; a javascript: or
        // file: template with a %s in it is a hole, not a feature.
        guard scheme == "http" || scheme == "https" else {
            return .rejected("A bang address has to be http or https.")
        }
        let name = bang.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = custom
        let replaced = list.contains { $0.keyword == keyword }
        list.removeAll { $0.keyword == keyword }
        list.append(.init(bang: keyword, name.isEmpty ? "!" + keyword : name, template))
        custom = list
        return .accepted(replaced: replaced, shadows: builtIn.contains { $0.keyword == keyword })
    }

    /// Accepts `gh` or `!gh`, same as `add`.
    static func remove(_ keyword: String) {
        let k = normalise(keyword)
        custom = custom.filter { $0.keyword != k }
    }

    /// Back to the shipped table only. Deliberately not "restore defaults" — it never
    /// touches search engines, only the user's own bangs.
    static func reset() { defaults.removeObject(forKey: "customBangs") }

    private static func normalise(_ keyword: String) -> String {
        String(keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "!" }).lowercased()
    }

    // MARK: - Precedence

    /// Every bang that resolves, in the order they resolve. Precedence *is* this array, so
    /// there is one place to read it and one place to assert it:
    ///
    ///   1. the user's own bangs        — they typed it, it wins over everything
    ///   2. the user's custom engines   — also their data, same tier, exact id only
    ///   3. this file's table           — what Vane ships
    ///   4. the built-in engines        — `!kagi`, `!ecosia`, `!brave` and friends
    ///
    /// User data above shipped data is the whole rule. Within a tier the more specific
    /// entry wins, which is why an exact match anywhere in this list beats the loose
    /// engine-id *prefix* match in `lookup` — `!a` is Amazon, not a prefix of nothing.
    ///
    /// A settings screen can render this list directly and get the real answer to "what
    /// does `!g` do", including overrides, without recomputing precedence.
    static var all: [Bang] { custom + Search.custom + builtIn + Search.builtIn }

    /// Exact match by precedence, then the legacy loose engine-id prefix (`!goo` → Google)
    /// last, where it cannot shadow anything specific.
    static func lookup(_ keyword: String) -> Bang? {
        let k = normalise(keyword)
        guard !k.isEmpty else { return nil }
        return all.first { $0.keyword == k } ?? Search.all.first { $0.id.hasPrefix(k) }
    }

    // MARK: - Reading a bang out of what was typed

    /// The bang keyword and the rest of the query, or nil when there is no bang token.
    ///
    /// Start or end only, because that is how people type: `!gh swift concurrency` when
    /// they decided up front, `swift concurrency !gh` when they decided after. A `!` in the
    /// middle is punctuation far more often than it is a command — "wow! neat", "a!b" —
    /// and a browser that hijacks those is worse than one with no bangs at all.
    static func split(_ input: String) -> (keyword: String, query: String)? {
        let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, let last = parts.last else { return nil }
        let leading = first.hasPrefix("!")
        guard leading || (parts.count > 1 && last.hasPrefix("!")) else { return nil }
        let token = leading ? first : last
        let rest = leading ? parts.dropFirst() : parts.dropLast()
        let keyword = normalise(token)
        guard !keyword.isEmpty else { return nil }              // a bare "!" is not a bang
        return (keyword, rest.joined(separator: " "))
    }

    /// The url for a recognised bang, or nil — nil meaning "not mine", so `Search.url(for:)`
    /// carries on down its decision table exactly as if this function did not exist.
    ///
    /// A recognised bang with nothing after it lands on that site's home page, which is the
    /// only useful reading of `!gh` on its own.
    static func resolve(_ input: String) -> URL? {
        guard let (keyword, query) = split(input), let bang = lookup(keyword) else { return nil }
        return Search.search(query, using: bang) ?? bang.home
    }

    /// The keyword of a bang-shaped token this browser does not know, or nil.
    ///
    /// THE UNKNOWN-BANG POLICY, and why it is this one.
    ///
    /// `resolve` returns nil for an unknown bang, so `Search.url(for:)` falls through and
    /// searches the whole string — `!` and all — on the engine the user chose. Verified
    /// live: Google answers `!zzq swift concurrency` with an ordinary results page for
    /// "swift concurrency", and DuckDuckGo, if that is what the user picked, still resolves
    /// its own thousands of bangs server-side exactly as it did before this file existed.
    ///
    /// The alternative was to quietly re-route unknown bangs to DuckDuckGo so it could
    /// resolve them. That is rejected: it sends the user's query to a search engine they
    /// did not choose, for a feature they did not ask for, and it does so invisibly. For
    /// the kind of person who picks their own search engine that is a worse outcome than a
    /// search that did not do what they hoped. Silently *stripping* the unknown token is
    /// rejected for the same reason in miniature — it throws away something they typed and
    /// gives no clue why.
    ///
    /// The cost of the chosen policy is a query that does not do what the user meant, so it
    /// is made observable rather than mysterious: the `!gh` sits there in the engine's own
    /// search box, and this function hands the address bar the keyword so it can offer
    /// "add !gh…" without guessing. That is the honest failure mode — visible, local, and
    /// one click from being fixed for good.
    static func unknown(_ input: String) -> String? {
        guard let (keyword, _) = split(input), lookup(keyword) == nil else { return nil }
        return keyword
    }

    // MARK: - check

    /// Offline assertions. Runs against a throwaway defaults suite, so the user's engines
    /// and bangs are neither read nor written. Called by `Search.check()`, which is already
    /// registered in `SelfCheck.run`, so this needs no wiring of its own.
    static func check() -> [(String, Bool)] {
        let suite = "vane.bangs.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            scratch.removePersistentDomain(forName: suite)
        }
        func str(_ input: String) -> String { Search.url(for: input)?.absoluteString ?? "<nil>" }

        var results: [(String, Bool)] = [
            ("every shipped template holds exactly one %s",
             builtIn.allSatisfy { $0.queryTemplate.components(separatedBy: "%s").count == 2 }),
            ("every shipped bang keyword is lowercase and bare",
             builtIn.allSatisfy { $0.keyword == normalise($0.keyword) }),
            ("no shipped bang keyword is defined twice",
             Set(builtIn.map(\.keyword)).count == builtIn.count),
            ("the table is the promised size", builtIn.count >= 35),

            ("a bang at the start routes",
             str("!gh swift concurrency") == "https://github.com/search?q=swift%20concurrency"),
            ("a bang at the end routes to the same place",
             str("swift concurrency !gh") == "https://github.com/search?q=swift%20concurrency"),
            ("a bang in the middle is not a bang",
             str("swift !gh concurrency").hasPrefix("https://www.google.com/search?q=swift%20%21gh")),
            ("a ! glued to a word is punctuation, not a bang", str("wow! neat").contains("wow%21%20neat")),
            ("a ! inside a word is punctuation, not a bang", str("a!b c").contains("a%21b%20c")),

            ("a bare ! is not a bang and still searches", str("!") == "https://www.google.com/search?q=%21"),
            ("a lone ! at the end is not a bang", str("hello !").contains("q=hello")),
            ("a bang with no query lands on the site home", str("!gh") == "https://github.com"),
            ("a trailing-only bang with no query is still the start case", str("  !yt  ") == "https://www.youtube.com"),

            ("a bang keyword is case-insensitive",
             str("!GH swift") == "https://github.com/search?q=swift"),
            ("a bang template with its own parameters keeps them",
             str("!arxiv transformer")
                == "https://arxiv.org/search/?query=transformer&searchtype=all"),
            ("a bang whose %s sits in the path substitutes there",
             str("!cheat tar") == "https://cheat.sh/tar"),
        ]

        // Encoding through a bang template. Spaces, &, #, = and non-ASCII in one query:
        // none of them may reach the site as anything but an escape, or the query could
        // rewrite the template's own parameters.
        let nasty = "a b & c # d = e — ünicode"
        let escaped = "a%20b%20%26%20c%20%23%20d%20%3D%20e%20%E2%80%94%20%C3%BCnicode"
        results += [
            ("a query with spaces, &, # and non-ASCII is fully escaped through a bang",
             str("!gh " + nasty) == "https://github.com/search?q=" + escaped),
            ("the same is true for a trailing bang",
             str(nasty + " !gh") == "https://github.com/search?q=" + escaped),
            ("an escaped query cannot rewrite a template's own parameters",
             str("!arxiv " + nasty)
                == "https://arxiv.org/search/?query=" + escaped + "&searchtype=all"),
        ]

        // The unknown-bang policy, asserted rather than described.
        results += [
            ("an unknown bang is not resolved", resolve("!zzq swift") == nil),
            ("an unknown bang searches the current engine verbatim, ! included",
             str("!zzq swift") == "https://www.google.com/search?q=%21zzq%20swift"),
            ("an unknown bang is never re-routed to another engine",
             !str("!zzq swift").contains("duckduckgo")),
            ("an unknown bang is reported so it can be offered as an addition",
             unknown("!zzq swift") == "zzq"),
            ("a known bang reports nothing to add", unknown("!gh swift") == nil),
            ("ordinary text reports nothing to add", unknown("swift concurrency") == nil),
        ]

        // "claude …" must keep routing to the assistant. Bangs need a !, assistants must
        // not, so the two triggers cannot collide — but assert it rather than assume it.
        results += [
            ("an assistant prefix is untouched by bangs", resolve("claude how do actors work") == nil),
            ("the assistant matcher still claims it", AIChat.match("claude how do actors work") != nil),
            ("no shipped bang keyword collides with an assistant id",
             builtIn.allSatisfy { b in !AIChat.all.contains { $0.id == b.keyword } }),
        ]

        // User-defined bangs: CRUD, validation, precedence.
        let mine = Bang(bang: "mine", "Mine", "https://s.example/find/%s?ui=1")
        results += [
            ("a user bang is added", add(mine) == .accepted(replaced: false, shadows: false)),
            ("it is listed", custom == [mine]),
            ("it resolves", str("!mine x") == "https://s.example/find/x?ui=1"),
            ("it resolves at the end too", str("x !mine") == "https://s.example/find/x?ui=1"),
            ("re-adding the same keyword replaces rather than duplicates",
             add(Bang(bang: "mine", "Mine 2", "https://s.example/find/%s?ui=2"))
                == .accepted(replaced: true, shadows: false) && custom.count == 1),
            ("the replacement is what resolves", str("!mine x") == "https://s.example/find/x?ui=2"),
            ("a leading ! is accepted and stored without one",
             { add(Bang(bang: "!banged", "Banged", "https://s.example/b/%s"))
               return custom.contains { $0.keyword == "banged" } }()),
            ("a user bang decodes back identically across a defaults round-trip",
             custom == custom.map { $0 }),
            ("removing takes the ! too",
             { remove("!banged"); return !custom.contains { $0.keyword == "banged" } }()),
        ]

        // Validation, one assertion per reason.
        func rejected(_ b: Bang) -> Bool { if case .rejected = add(b) { return true }; return false }
        results += [
            ("an empty keyword is rejected", rejected(.init(bang: "  ", "X", "https://e.example/%s"))),
            ("a keyword with a space is rejected", rejected(.init(bang: "a b", "X", "https://e.example/%s"))),
            ("a template with no %s is rejected", rejected(.init(bang: "k", "X", "https://e.example/"))),
            ("a template with two %s is rejected", rejected(.init(bang: "k", "X", "https://e.example/%s/%s"))),
            ("a template that cannot parse is rejected", rejected(.init(bang: "k", "X", "not a url %s"))),
            ("a javascript: template is rejected", rejected(.init(bang: "k", "X", "javascript:alert(%s)"))),
            ("a rejected bang is not stored", !custom.contains { $0.keyword == "k" }),
            ("a rejection says why",
             { if case .rejected(let why) = add(Bang(bang: "k", "X", "https://e.example/")) {
                 return why.contains("%s") }
               return false }()),
        ]

        // Precedence: user bang > user engine > built-in bang > built-in engine.
        results += [
            ("overriding a built-in bang is allowed and reported",
             add(Bang(bang: "gh", "Not GitHub", "https://mine.example/?q=%s"))
                == .accepted(replaced: false, shadows: true)),
            ("a user bang beats the built-in table at resolution time",
             str("!gh swift") == "https://mine.example/?q=swift"),
            ("removing the override restores the built-in",
             { remove("gh"); return str("!gh swift") == "https://github.com/search?q=swift" }()),
            ("a user bang beats a custom engine of the same name",
             { Search.add(SearchEngine(id: "dup", name: "Engine", queryTemplate: "https://engine.example/?q=%s"))
               add(Bang(bang: "dup", "Bang", "https://bang.example/?q=%s"))
               return str("!dup x") == "https://bang.example/?q=x" }()),
            ("a custom engine beats the built-in table",
             { Search.add(SearchEngine(id: "yt", name: "My Tube", queryTemplate: "https://mytube.example/?q=%s"))
               return str("!yt x") == "https://mytube.example/?q=x" }()),
            ("a built-in bang beats a built-in engine id",
             // "b" is a prefix of both "bing" and "brave"; the table settles it.
             { Search.remove(SearchEngine(id: "yt", name: "", queryTemplate: ""))
               return str("!b x") == "https://www.bing.com/search?q=x" }()),
            ("a built-in engine id still resolves as a bang",
             str("!kagi x") == "https://kagi.com/search?q=x"),
            ("a loose engine-id prefix still resolves, last",
             str("!eco x") == "https://www.ecosia.org/search?q=x"),
            ("precedence order is the order of `all`",
             all.prefix(custom.count) == ArraySlice(custom)),
        ]

        // reset() restores the shipped table and nothing else.
        let engines = Search.custom.count
        reset()
        results += [
            ("reset drops every user bang", custom.isEmpty),
            ("reset restores the built-in resolution", str("!gh x") == "https://github.com/search?q=x"),
            ("reset leaves search engines alone", Search.custom.count == engines),
        ]
        return results
    }
}
