import Foundation

/// An AI assistant's website. `template` holds one `%s`, replaced by the percent-encoded
/// question — deliberately the same shape as `SearchEngine.queryTemplate`, so the two
/// tables read alike and a future settings row can be copy-pasted between them.
struct AIAssistant: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var template: String
}

/// Arc's "ChatGPT in the Command Bar": type a question, and instead of searching for it,
/// open the assistant's own site with the question already in the box.
///
/// ponytail: this never calls an AI API. No key, no account, no HTTP client, no streaming
/// — it builds a url and hands it to the same `web.load` every other navigation uses. The
/// assistant's own site does the work, with the user's own session and their own plan.
///
/// The deep links below were verified by loading each one in a WKWebView wearing `safariUA`
/// and reading the DOM afterwards. What each one actually does, logged out:
///
///   ChatGPT     `https://chatgpt.com/?q=…`            auto-submits. Redirects to
///                                                     `/uc/<id>` and streams an answer
///                                                     with no login at all.
///   Perplexity  `https://www.perplexity.ai/search?q=…` auto-submits. Redirects to
///                                                     `/search/<uuid>` with the answer.
///   Grok        `https://grok.com/?q=…`               auto-submits: the question renders
///                                                     as a real `data-testid=user-message`
///                                                     bubble. The *answer* is behind a
///                                                     "sign up to continue" wall.
///   Claude      `https://claude.ai/new?q=…`           login wall when logged out, but the
///                                                     bounce is
///                                                     `/login?returnTo=/new%3Fq%3D…`, so
///                                                     the question survives signing in.
///                                                     `q` is the param claude.ai's own
///                                                     client uses; its seeding code only
///                                                     calls setPrompt, so it pre-fills the
///                                                     composer and the user presses Return.
///
/// ponytail: Gemini is deliberately absent. `https://gemini.google.com/app?q=…` loads, then
/// drops the question on the floor — no login wall, no pre-fill, nothing in the DOM. There
/// is no url to ship, so there is no row. Same for Copilot, which redirects to a bare
/// `copilot.microsoft.com` and loses it. Ceiling: recheck if either ever publishes one.
@MainActor enum AIChat {

    typealias Assistant = AIAssistant

    /// ponytail: a `var` for the same reason `PaletteCommand.all` is one — later code can
    /// append without this file learning about it. There is no custom-assistant editor and
    /// no need for one: an assistant that took a `%s` template would just be a search engine.
    static var all: [Assistant] = [
        .init(id: "claude",     name: "Claude",     template: "https://claude.ai/new?q=%s"),
        .init(id: "chatgpt",    name: "ChatGPT",    template: "https://chatgpt.com/?q=%s"),
        .init(id: "perplexity", name: "Perplexity", template: "https://www.perplexity.ai/search?q=%s"),
        .init(id: "grok",       name: "Grok",       template: "https://grok.com/?q=%s"),
    ]

    /// Extra words that route to an assistant, beyond its id and its name. Only the ones a
    /// person would actually type — this is not a synonym table.
    private static let shortcuts: [String: String] = ["gpt": "chatgpt", "pplx": "perplexity"]

    /// Swapped out by `check()` so the assertions never touch the user's real preference.
    /// Same trick, same reason, as `Search.defaults`.
    static var defaults = UserDefaults.standard

    /// Falls back to the first entry when the stored id names an assistant that was removed.
    static var preferred: Assistant {
        get {
            let id = defaults.string(forKey: "aiAssistant")
            return all.first { $0.id == id } ?? all[0]
        }
        set { defaults.set(newValue.id, forKey: "aiAssistant") }
    }

    /// nil for a question with nothing in it, so an empty address bar cannot open a chat.
    static func url(for question: String, using assistant: Assistant? = nil) -> URL? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let template = (assistant ?? preferred).template
        return URL(string: template.replacingOccurrences(of: "%s", with: encode(q)))
    }

    /// "claude how do actors work" → (Claude, "how do actors work").
    ///
    /// Only the *leading* word counts, and only when something follows it. That is what
    /// keeps "what did claude say" a search: the head word is "what", so this returns nil
    /// and the address bar's normal path takes over.
    ///
    /// Deliberately stricter than `Search.keywordSearch`, which prefix-matches its bangs.
    /// A bang is opt-in — you typed `!` — so a loose match there is harmless. Here the
    /// trigger is an ordinary English word at the start of an ordinary sentence, and a
    /// prefix match would turn "cl" or "gro" into a hijack. Exact alias or nothing.
    static func match(_ input: String) -> (Assistant, String)? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(s.prefix { !$0.isWhitespace }).lowercased()
        let rest = String(s.drop { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !rest.isEmpty else { return nil }
        let id = shortcuts[head] ?? head
        guard let a = all.first(where: {
            $0.id == id || $0.name.lowercased() == id
        }) else { return nil }
        return (a, rest)
    }

    /// RFC 3986 unreserved set — the same encoder `Search` uses privately, spelled again
    /// rather than shared because reaching into it would mean opening it up. Everything
    /// else escapes, so a question holding &, #, = or a quote cannot rewrite the site's
    /// own url, and non-ASCII goes out as percent-encoded UTF-8.
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? s
    }

    // MARK: - check

    /// Offline assertions. No network: these prove url construction, encoding and routing,
    /// which is all that can be proved without an account. Whether a given site auto-submits
    /// is the site's business and is documented above from a live run, not asserted here.
    static func check() -> [(String, Bool)] {
        let suite = "vane.aichat.check.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: suite) else {
            return [("scratch defaults suite is available", false)]
        }
        let real = defaults
        defaults = scratch
        defer {
            defaults = real
            scratch.removePersistentDomain(forName: suite)
        }

        func of(_ id: String) -> Assistant { all.first { $0.id == id }! }
        func str(_ q: String, _ id: String) -> String {
            url(for: q, using: of(id))?.absoluteString ?? "<nil>"
        }

        // Spaces, a quote pair, &, # and two non-ASCII characters in one question.
        let nasty = "swift \"actors\" & #concurrency — ünicode"
        let escaped = "swift%20%22actors%22%20%26%20%23concurrency%20%E2%80%94%20%C3%BCnicode"

        var results: [(String, Bool)] = [
            ("claude builds a /new?q= url", str("hello", "claude") == "https://claude.ai/new?q=hello"),
            ("chatgpt builds a root ?q= url", str("hello", "chatgpt") == "https://chatgpt.com/?q=hello"),
            ("perplexity builds a /search?q= url",
             str("hello", "perplexity") == "https://www.perplexity.ai/search?q=hello"),
            ("grok builds a root ?q= url", str("hello", "grok") == "https://grok.com/?q=hello"),
            ("every assistant parses as a url with a nasty question",
             all.allSatisfy { url(for: nasty, using: $0) != nil }),
        ]
        for a in all {
            results.append(("\(a.name) percent-encodes quotes, &, # and non-ASCII",
                            str(nasty, a.id).hasSuffix("q=" + escaped)))
            results.append(("\(a.name) leaves nothing unencoded that could rewrite its url",
                            str(nasty, a.id).dropFirst("https://".count)
                                .allSatisfy { !" \"<>\\^`{|}".contains($0) }))
        }

        results += [
            ("a space becomes %20, not +", str("a b", "claude").hasSuffix("q=a%20b")),
            ("an empty question is nil", url(for: "", using: of("claude")) == nil),
            ("a whitespace-only question is nil", url(for: "  \n ", using: of("claude")) == nil),

            ("match takes the assistant name off the front",
             match("claude how do actors work")?.1 == "how do actors work"),
            ("match routes claude to Claude", match("claude x")?.0 == of("claude")),
            ("match routes chatgpt to ChatGPT", match("chatgpt x")?.0 == of("chatgpt")),
            ("match routes perplexity to Perplexity", match("perplexity x")?.0 == of("perplexity")),
            ("match routes grok to Grok", match("grok x")?.0 == of("grok")),
            ("match routes the gpt shortcut", match("gpt x")?.0 == of("chatgpt")),
            ("match routes the pplx shortcut", match("pplx x")?.0 == of("perplexity")),
            ("match is case-insensitive", match("ChatGPT x")?.0 == of("chatgpt")),
            ("match collapses the space after the name", match("claude    x")?.1 == "x"),

            ("match ignores claude mid-sentence", match("what did claude say") == nil),
            ("match ignores chatgpt mid-sentence", match("is chatgpt down") == nil),
            ("match does not fire on the name alone", match("claude") == nil),
            ("match does not fire on a name with only spaces after it", match("claude   ") == nil),
            ("match does not prefix-match a shorter word", match("cl x") == nil),
            ("match does not fire on a hostname", match("claude.ai/new") == nil),
            ("match does not fire on an unrelated word", match("swift actors") == nil),
            ("match on empty input is nil", match("") == nil),
        ]

        // Preferred round-trip, against the scratch suite.
        results.append(("preferred defaults to the first assistant", preferred == all[0]))
        preferred = of("chatgpt")
        results.append(("the chosen assistant persists by id", preferred == of("chatgpt")))
        results.append(("url with no assistant uses the preferred one",
                        url(for: "hello")?.absoluteString == "https://chatgpt.com/?q=hello"))
        defaults.set("gone", forKey: "aiAssistant")
        results.append(("an unknown stored id falls back to the first assistant",
                        preferred == all[0]))
        return results
    }
}
