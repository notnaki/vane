import Foundation

/// A search engine. `queryTemplate` holds one `%s`, replaced by the percent-encoded query.
/// ponytail: `%s` rather than a URLComponents dance — every browser's custom-engine field
/// already works this way, so a user pasting one from Chrome gets what they expect.
struct SearchEngine: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var queryTemplate: String

    /// Scheme + host of the template, used as the default homepage and as the landing page
    /// for a bang with nothing after it. String surgery, not URLComponents — the raw
    /// template contains `%s`, which is not a legal percent-escape and parses as nil.
    var home: URL? {
        guard let r = queryTemplate.range(of: "://") else { return nil }
        let rest = queryTemplate[r.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        return URL(string: String(queryTemplate[..<r.upperBound] + rest[..<end]))
    }
}

/// Everything the address bar does with what was typed into it.
///
/// This replaces `Tab.go`'s two-line heuristic ("has a space or no dot → search"), which
/// sent `localhost:3000` and `192.168.1.1` to a search engine and turned any dotted phrase
/// into a navigation. The decision order below is the whole feature.
@MainActor enum Search {

    // MARK: - Engines

    /// Google first, because it is the default and the picker should open on it.
    static let builtIn: [SearchEngine] = [
        .init(id: "google",     name: "Google",     queryTemplate: "https://www.google.com/search?q=%s"),
        .init(id: "duckduckgo", name: "DuckDuckGo", queryTemplate: "https://duckduckgo.com/?q=%s"),
        .init(id: "bing",       name: "Bing",       queryTemplate: "https://www.bing.com/search?q=%s"),
        .init(id: "brave",      name: "Brave",      queryTemplate: "https://search.brave.com/search?q=%s"),
        .init(id: "kagi",       name: "Kagi",       queryTemplate: "https://kagi.com/search?q=%s"),
        .init(id: "ecosia",     name: "Ecosia",     queryTemplate: "https://www.ecosia.org/search?q=%s"),
    ]

    /// The engine a user who has never opened Settings gets.
    ///
    /// Named rather than spelled `builtIn[0]`, so that reordering the list above is a
    /// cosmetic change to the picker and nothing else. Everything that used to mean "the
    /// default" by writing `builtIn[0]` should say this instead — index 0 answering both
    /// questions is how "reorder the array" turns into "silently changed the default".
    static let defaultEngine: SearchEngine = builtIn.first { $0.id == "google" } ?? builtIn[0]

    /// Swapped out by `check()` so the assertions never touch the user's real preferences.
    static var defaults = UserDefaults.vane

    static var custom: [SearchEngine] {
        get {
            guard let data = defaults.data(forKey: "customSearchEngines") else { return [] }
            return (try? JSONDecoder().decode([SearchEngine].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "customSearchEngines") }
    }

    static var all: [SearchEngine] { builtIn + custom }

    /// Falls back to `defaultEngine` when nothing is stored, or when the stored id names an
    /// engine that was removed. Reading the stored id first is what guarantees that
    /// changing the default never moves a user who already chose one.
    static var current: SearchEngine {
        get {
            let id = defaults.string(forKey: "searchEngine")
            return all.first { $0.id == id } ?? defaultEngine
        }
        set { defaults.set(newValue.id, forKey: "searchEngine") }
    }

    /// Same id replaces rather than duplicates, so editing a custom engine is add-again.
    static func add(_ engine: SearchEngine) {
        guard !builtIn.contains(where: { $0.id == engine.id }) else { return }
        var list = custom
        list.removeAll { $0.id == engine.id }
        list.append(engine)
        custom = list
    }

    static func remove(_ engine: SearchEngine) {
        custom = custom.filter { $0.id != engine.id }
        if defaults.string(forKey: "searchEngine") == engine.id {
            defaults.removeObject(forKey: "searchEngine")
        }
    }

    // MARK: - The address bar decision

    /// nil only for an input with nothing in it — everything else is either a url or a
    /// search, and the point of this function is deciding which.
    static func url(for input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // A leading ? is the user overriding the guess: search this, verbatim. It is tested
        // before bangs on purpose — "?!g swift" means search for the string "!g swift".
        if s.hasPrefix("?") { return search(String(s.dropFirst())) }
        // `!gh swift` and `swift !gh` both route. An unknown bang returns nil here and
        // falls through to the plain search below — see `Bangs.unknown` for why.
        if let u = Bangs.resolve(s) { return u }
        if let u = explicitScheme(s) { return u }
        if let u = filePath(s) { return u }
        if looksLikeHost(s) { return URL(string: scheme(for: s) + s, encodingInvalidCharacters: true) }
        return search(s)
    }

    /// Bangs live in `Bangs.swift`. That file used to be a comment here reading "no bang
    /// table of our own, ever", and that decision was correct exactly as long as the
    /// default engine was DuckDuckGo, which resolves thousands of bangs itself. Google does
    /// not, so leaning on the engine stopped working the day the default changed.
    static func search(_ query: String, using engine: SearchEngine? = nil) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let template = (engine ?? current).queryTemplate
        return URL(string: template.replacingOccurrences(of: "%s", with: encode(q)))
    }

    /// RFC 3986 unreserved set: everything else escapes, so a query holding &, =, # or +
    /// cannot rewrite the engine's own url.
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    // MARK: - The individual tests

    private static let schemesWithoutSlashes: Set<String> =
        ["mailto", "about", "data", "javascript", "tel", "sms", "view-source", "file"]

    /// `//` after the colon settles it. Without it the scheme has to be one we know, or
    /// `localhost:3000` and `swift:generics` would both parse as a scheme.
    private static func explicitScheme(_ s: String) -> URL? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = s[..<colon].lowercased()
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) })
        else { return nil }
        guard s[s.index(after: colon)...].hasPrefix("//")
                || schemesWithoutSlashes.contains(scheme) else { return nil }
        // encodingInvalidCharacters is what saves "https://x.com/a b" — the strict RFC 3986
        // parser rejects the raw space outright.
        return URL(string: s, encodingInvalidCharacters: true)
    }

    /// ponytail: a leading / or ~/ is only a file if the file is actually there. Otherwise
    /// "/r/swift" would open a file url that cannot load instead of searching for it.
    private static func filePath(_ s: String) -> URL? {
        guard s.hasPrefix("/") || s.hasPrefix("~/") else { return nil }
        let path = (s as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// http for loopback, LAN devices and dev servers; https for everything else. A bare IP
    /// or `localhost` typed into an address bar is nearly always something with no
    /// certificate, and https there fails in a way the user cannot act on.
    /// ponytail: ceiling is that a public IP typed bare also gets http.
    private static func scheme(for s: String) -> String {
        let host = authority(s).split(separator: ":").first.map(String.init) ?? ""
        let local = host.lowercased() == "localhost" || host.hasSuffix(".localhost")
            || isIPv4(host) || s.hasPrefix("[")
        return local ? "http://" : "https://"
    }

    private static func authority(_ s: String) -> String {
        let head = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard let at = head.lastIndex(of: "@") else { return String(head) }
        return String(head[head.index(after: at)...])       // strip user:pass@
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { 0...255 ~= $0 } ?? false }
    }

    /// The branchy one. True for `example.com`, `localhost:3000`, `192.168.1.1`, `[::1]:80`,
    /// `example.com:8080/path`; false for `swift 6.2 concurrency`, `6.2`, `3000`, `hello`.
    private static func looksLikeHost(_ s: String) -> Bool {
        let auth = authority(s)
        guard !auth.isEmpty else { return false }
        if auth.hasPrefix("[") { return auth.contains("]") }        // ipv6 literal
        var host = Substring(auth)
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.count <= 5, port.allSatisfy(\.isNumber) else { return false }
            host = host[..<colon]
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, labels.allSatisfy({ label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }) else { return false }
        if isIPv4(String(host)) { return true }
        if host.lowercased() == "localhost" || host.lowercased().hasSuffix(".localhost") { return true }
        // An all-letters last label is the only thing separating a bare host from a phrase
        // with a dot in it: "swift 6.2 concurrency" dies on the space, "6.2" on the digit.
        // ponytail: no IANA TLD list, so "notes.txt" navigates. Ceiling: ship the list.
        guard labels.count > 1, let tld = labels.last else { return false }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }

    // MARK: - check

    /// Offline assertions for the decision table above. Runs against a throwaway defaults
    /// suite, so the user's engine and custom engines are neither read nor written.
    static func check() -> [(String, Bool)] {
        let suite = "vane.search.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            scratch.removePersistentDomain(forName: suite)
        }
        func str(_ input: String) -> String { url(for: input)?.absoluteString ?? "<nil>" }
        func isSearch(_ input: String) -> Bool { str(input).hasPrefix("https://www.google.com/search?q=") }

        // The default, and the promise that changing it never moves anyone who chose.
        var results: [(String, Bool)] = [
            ("with nothing stored the default engine is Google", current.id == "google"),
            ("the default is not merely whatever is first in the list",
             defaultEngine.id == "google"),
            ("an engine the user already chose survives the default changing",
             { defaults.set("duckduckgo", forKey: "searchEngine"); return current.id == "duckduckgo" }()),
            ("a stored engine is what a search actually uses",
             str("hello") == "https://duckduckgo.com/?q=hello"),
        ]
        defaults.removeObject(forKey: "searchEngine")          // back to the default for the rest
        results.append(("clearing the stored engine returns to the default", current == defaultEngine))

        results += [
            ("a bare host becomes https", str("example.com") == "https://example.com"),
            ("a host with a path keeps the path", str("example.com/a?b=1") == "https://example.com/a?b=1"),
            ("localhost:3000 is a url over http, not a search", str("localhost:3000") == "http://localhost:3000"),
            ("an ipv4 literal is a url", str("192.168.1.1") == "http://192.168.1.1"),
            ("an ipv4 literal with a port is a url", str("127.0.0.1:8080") == "http://127.0.0.1:8080"),
            ("an ipv6 literal is a url", str("[::1]:8080") == "http://[::1]:8080"),
            ("an explicit scheme is left alone", str("http://example.com") == "http://example.com"),
            ("a url with a space is encoded, not searched", str("https://x.com/a b") == "https://x.com/a%20b"),
            ("mailto: survives without slashes", str("mailto:ada@example.com") == "mailto:ada@example.com"),
            ("about:blank survives without slashes", str("about:blank") == "about:blank"),
            ("a phrase containing a dot searches", isSearch("swift 6.2 concurrency")),
            ("that phrase is percent-encoded", str("swift 6.2 concurrency").hasSuffix("swift%206.2%20concurrency")),
            ("a single word searches", isSearch("hello")),
            ("a bare number searches", isSearch("3000")),
            ("a dotted version number searches", isSearch("6.2")),
            ("a leading ? forces a search", isSearch("?example.com")),
            ("the ? is not part of the query", str("?example.com").hasSuffix("q=example.com")),
            ("an empty input is nil", url(for: "") == nil),
            ("a whitespace-only input is nil", url(for: "   \n ") == nil),
            ("query characters cannot rewrite the engine url",
             str("a&b=c#d").hasSuffix("q=a%26b%3Dc%23d")),
            ("an existing file path opens as a file url",
             str(NSTemporaryDirectory()).hasPrefix("file:///")),
            ("a path that is not a file searches", isSearch("/r/swift")),
            ("!g routes to google", str("!g swift").hasPrefix("https://www.google.com/search?q=swift")),
            ("!kagi routes by full id", str("!kagi swift").hasPrefix("https://kagi.com/search?q=swift")),
            ("a bang with no query lands on the engine home", str("!g") == "https://www.google.com"),
            // Was "an unknown bang goes to the current engine intact" and only worked
            // because the engine was DuckDuckGo. Same behaviour, now a stated policy — see
            // `Bangs.unknown`. !gh is no longer unknown, so this uses a keyword nothing owns.
            ("an unknown bang goes to the current engine intact",
             str("!zzq swift").hasSuffix("q=%21zzq%20swift")),
        ]

        // Custom engine round-trip.
        let mine = SearchEngine(id: "mine", name: "Mine", queryTemplate: "https://s.example/find/%s?ui=1")
        add(mine)
        results.append(("a custom engine is added once", custom.count == 1))
        results.append(("a custom engine decodes back identically", custom.first == mine))
        results.append(("re-adding the same id replaces rather than duplicates",
                        { add(mine); return custom.count == 1 }()))
        results.append(("a custom engine appears in all", all.contains(mine)))
        current = mine
        results.append(("the chosen engine persists by id", current == mine))
        results.append(("%s is substituted mid-template",
                        str("a b") == "https://s.example/find/a%20b?ui=1"))
        results.append(("a bang can name a custom engine",
                        str("!mine x") == "https://s.example/find/x?ui=1"))
        remove(mine)
        results.append(("removing a custom engine drops it", custom.isEmpty))
        results.append(("removing the chosen engine falls back to the default",
                        current == defaultEngine))
        return results + Bangs.check()
    }
}
