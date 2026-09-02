import Foundation

/// Arc's "Tidy Tab Titles". A pinned tab is a chip the width of a favicon, and
/// "Apollo program - Wikipedia, the free encyclopedia" is not a label — it is a paragraph.
///
/// Two paths, in this order, and the order is the whole design:
///
/// 1. `clean` — a pure string function. No model, no I/O, no await. On the twenty-odd real
///    titles in `check()` it alone gets nineteen right, in microseconds. Every browser title
///    is built by the same three or four templates ("page — site", "site | page", "(3) app")
///    and templates are exactly what a deterministic cleaner eats for breakfast.
/// 2. `AppleAI.shortTitle` — only when 1 came back still too long or saying nothing. That is
///    a ~3B model on the neural engine and it costs seconds, so it is the exception, not the
///    plan. Its answer is validated against the original before it is allowed anywhere near
///    a tab, and the deterministic answer is the fallback when validation says no.
///
/// Nothing here ever touches an unpinned tab, and nothing here can make a title longer.
@MainActor enum TidyTitles {

    /// Off means the raw `Tab.title` everywhere. Manual renames still apply — those are the
    /// user's own words, not ours, and a feature switch has no business deleting them.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "tidyTitles") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tidyTitles") }
    }

    /// What fits a pinned chip before it starts eating the strip. Also the line between
    /// "the cheap path was good enough" and "ask the model".
    static let pinnedLimit = 24

    /// The model is told "at most four words"; anything past this is it ignoring us.
    static let modelLimit = 32

    // MARK: - The deterministic cleaner
    //
    // Pure. Everything below this line up to `tidy` is a function of its arguments, which is
    // why `check()` can hammer it with real titles and no window server, no profile on disk
    // and no Apple Intelligence.

    /// Separators sites put between the page and their own name. Every one is *space
    /// delimited*, which is what keeps "Hyper-threading - Wikipedia" from losing its hyphen:
    /// the hyphen inside a word has no spaces around it, so it is not a separator here.
    static let separators = [" :: ", " — ", " – ", " - ", " | ", " · ", " • ", " » ", " › "]

    /// Segments that carry no information at all, whatever site they came from.
    static let boilerplate: Set<String> = [
        "home", "homepage", "home page", "start", "start page", "index", "welcome",
        "official site", "official website", "untitled", "untitled document",
    ]

    /// Words that start a tagline rather than a title. "The system for product development".
    private static let articles: Set<String> = ["the", "a", "an", "your", "our", "my"]

    static func squash(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func words(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).count
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Trimmed off both ends after every cut. `?` and `!` are deliberately absent — they are
    /// part of "How do I sort a dictionary by value?", not decoration.
    private static let junk = CharacterSet(charactersIn: " \t\"'“”‘’.,:;·•|–—-–")

    private static func trimmed(_ s: String) -> String {
        var t = s.trimmingCharacters(in: junk)
        // A site that already truncated its own title leaves the ellipsis behind.
        while t.hasSuffix("…") || t.hasSuffix("...") {
            t = String(t.dropLast(t.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: junk)
        }
        return t
    }

    /// "(3) Facebook", "Inbox (12) - ada@example.com - Gmail". One to three digits only, so
    /// the year in "Star Wars (1977) - IMDb" is not mistaken for an unread badge.
    ///
    /// ponytail: anywhere in the string, not just the front, because Gmail puts its badge in
    /// the middle and Gmail is on everybody's pinned strip. The cost is that a genuine
    /// "(12)" in a title disappears; that has not turned up in any real title I looked at.
    static func stripCounts(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "(", let close = s[i...].firstIndex(of: ")") {
                let inner = s[s.index(after: i)..<close]
                if (1...4).contains(inner.count), inner.contains(where: \.isNumber),
                   inner.allSatisfy({ $0.isNumber || $0 == "+" }), inner.filter(\.isNumber).count <= 3 {
                    i = s.index(after: close)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// The site's own name, as it might appear written out in the title. `en.wikipedia.org`
    /// gives "wikipedia"; `f-droid.org` gives both "fdroid" and "droid" so the segment
    /// "F-Droid" matches however the site chose to punctuate it.
    static func hostTokens(_ host: String?) -> Set<String> {
        guard var h = host?.lowercased(), !h.isEmpty else { return [] }
        for p in ["www.", "m.", "mobile."] where h.hasPrefix(p) { h.removeFirst(p.count) }
        var labels = h.split(separator: ".").map(String.init)
        if labels.count >= 2 { labels.removeLast() }                    // the TLD
        // co.uk, com.au, ac.jp — the second-level bit is not a name either.
        if labels.count >= 2, ["co", "com", "org", "net", "gov", "ac", "edu"].contains(labels.last!) {
            labels.removeLast()
        }
        var out = Set<String>()
        for l in labels {
            out.insert(l.replacingOccurrences(of: "-", with: ""))
            for piece in l.split(separator: "-") where piece.count >= 3 { out.insert(String(piece)) }
        }
        return out.filter { $0.count >= 2 }
    }

    /// Is this segment the site announcing itself? Exact wins outright. A loose substring
    /// match ("Apple Developer Documentation" against `developer.apple.com`) needs a token of
    /// four characters or more, because a three-letter token like `bbc` matches half the web.
    private static func isSite(_ segment: String, _ tokens: Set<String>) -> Bool {
        let s = squash(segment)
        guard !s.isEmpty else { return false }
        if tokens.contains(s) { return true }
        return tokens.contains { $0.count >= 4 && s.contains($0) }
    }

    /// A strapline, not a title: "A fast all-in-one JavaScript runtime". Long, or wordy, or
    /// opening with an article — real page titles almost never open with "The system for".
    private static func isTagline(_ s: String) -> Bool {
        let w = words(s)
        if w >= 6 || s.count >= 40 { return true }
        let first = s.split(whereSeparator: \.isWhitespace).first.map { squash(String($0)) } ?? ""
        return articles.contains(first) && w >= 4
    }

    /// Split on the separators, remembering which one followed each segment so the survivors
    /// can be put back together with the punctuation the site actually used.
    static func segments(_ s: String) -> [(text: String, after: String)] {
        var parts: [(text: String, after: String)] = []
        var rest = Substring(s)
        while true {
            var hit: (Range<Substring.Index>, String)?
            for sep in separators {
                if let r = rest.range(of: sep), hit == nil || r.lowerBound < hit!.0.lowerBound {
                    hit = (r, sep)
                }
            }
            guard let (r, sep) = hit else {
                parts.append((trimmed(String(rest)), ""))
                break
            }
            parts.append((trimmed(String(rest[rest.startIndex..<r.lowerBound])), sep))
            rest = rest[r.upperBound...]
        }
        return parts.filter { !$0.text.isEmpty }
    }

    private static func joined(_ parts: [(text: String, after: String)]) -> String {
        guard !parts.isEmpty else { return "" }
        var s = parts[0].text
        for i in 1..<parts.count { s += parts[i - 1].after + parts[i].text }
        return s
    }

    /// The whole cheap path. nil only when there is nothing left worth showing.
    ///
    /// Only ever *removes*, which is what makes "never longer than the original" a property
    /// of the code rather than a check bolted on afterwards.
    static func clean(_ title: String, host: String?) -> String? {
        let normalized = trimmed(collapse(stripCounts(title)))
        guard !normalized.isEmpty else { return nil }
        var parts = segments(normalized)
        guard parts.count > 1 else { return normalized }
        let tokens = hostTokens(host)

        // 1. Taglines, from the tail. Before the host pass, and that ordering is load
        //    bearing: "Ars Technica - Serving the Technologist since 1998. …" matches the
        //    host at the *front*, so a host pass first would keep the strapline and throw
        //    away the name. The guard is that the head still looks like a label.
        while parts.count > 1, parts[0].text.count <= 30, isTagline(parts[parts.count - 1].text) {
            parts.removeLast()
        }

        // 2. Segments that say nothing: "Home - BBC News".
        while parts.count > 1, boilerplate.contains(parts[0].text.lowercased()) { parts.removeFirst() }
        while parts.count > 1, boilerplate.contains(parts[parts.count - 1].text.lowercased()) { parts.removeLast() }

        // 3. The site's name, and everything after it — once the site has introduced itself
        //    the rest is its strapline. "… | F-Droid - Free and Open Source Android App
        //    Repository" loses both halves in one cut. A leading one goes too, but only on an
        //    exact match, or "BBC Sport - …" would lose the "BBC Sport".
        if let last = parts.indices.last(where: { isSite(parts[$0].text, tokens) }), last > 0 {
            parts.removeSubrange(last...)
        }
        if parts.count > 1, tokens.contains(squash(parts[0].text)) { parts.removeFirst() }

        // 4. Last resort: a short trailing qualifier. Runs once unconditionally, because
        //    "中國 - 维基百科，自由的百科全书" is already inside the width budget and still
        //    mostly boilerplate, then keeps going only while the chip would overflow.
        //
        // ponytail: this is the one rule that can lose real information — "Bug 12345 - crash
        // on launch" becomes "Bug 12345". Accepted, because a 40pt chip cannot show the tail
        // either, and a user who disagrees double-clicks and renames it.
        var forced = true
        while parts.count > 1, forced || joined(parts).count > pinnedLimit {
            let tail = parts[parts.count - 1].text
            guard words(tail) <= 4, tail.count <= pinnedLimit else { break }
            parts.removeLast()
            forced = false
        }

        let out = trimmed(joined(parts))
        // Belt and braces: a cleaner that grew the title is a bug, and the raw title is
        // always a safe answer.
        guard !out.isEmpty, out.count <= title.count else { return normalized.isEmpty ? nil : normalized }
        return out
    }

    /// Would this still be a bad chip label? The only reason to spend seconds on the model.
    static func uninformative(_ s: String, host: String?) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.count > pinnedLimit { return true }
        if squash(t).isEmpty { return true }                                  // all punctuation
        if t.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) { return true }  // a bare number
        if boilerplate.contains(t.lowercased()) { return true }
        // Literally the domain — WebKit's own fallback when a page has no <title> at all.
        //
        // Whole-string equality, never a prefix: measured, an earlier version compared
        // "Ars Technica" against arstechnica.com by suffix and declared the site's own
        // correct name uninformative, which sent a finished title off to spend seven
        // seconds coming back worse.
        if let host {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if squash(bare) == squash(t) { return true }
        }
        return false
    }

    // MARK: - The model, and the net under it

    /// The model has a token budget, so it stops mid-phrase: measured, "Installing Tailwind
    /// CSS with Vite - Tailwind CSS" came back as "Installing Tailwind CSS with". A trailing
    /// preposition is always the cut showing, never the title.
    private static let dangling: Set<String> = [
        "with", "and", "or", "the", "a", "an", "of", "for", "to", "in", "on", "by", "from", "at", "as",
    ]

    /// Whatever the model said, treated as text a hostile page influenced — see the long
    /// note in AppleAI about why. A shortened title is a *selection* from the original, so
    /// every real word in the answer has to be a word of the original.
    ///
    /// Whole words, not substrings, and that is measured too: with substring matching the
    /// model turned "Ars Technica - Serving the Technologist since 1998…" into "Tech News",
    /// which passed because "tech" hides inside "Technica" and "Technologist". It is a new
    /// name for the site, not a shortening of the title, and a shortener that renames things
    /// is the one failure mode worth being strict about. The cost of being strict is a
    /// rejected inflection ("Programs" for "program"), and a rejection just falls back to
    /// the deterministic answer.
    static func validate(_ answer: String, original: String) -> String? {
        var a = trimmed(collapse(answer))
        while let last = a.split(whereSeparator: \.isWhitespace).last,
              a.split(whereSeparator: \.isWhitespace).count > 1,
              dangling.contains(squash(String(last))) {
            a = trimmed(String(a.dropLast(last.count)))
        }
        guard !a.isEmpty, a.count <= original.count, a.count <= modelLimit else { return nil }
        let vocabulary = Set(original.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let all = a.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // Short words carry no evidence, so they are dropped — unless that leaves nothing,
        // which is what happens on CJK where a whole title is two characters.
        var terms = all.filter { $0.count >= 3 }
        if terms.isEmpty { terms = all }
        guard !terms.isEmpty, terms.allSatisfy(vocabulary.contains) else { return nil }
        return a
    }

    /// The public entry point. Cheap path first, always; the model only when the cheap path
    /// came back too long or saying nothing.
    static func tidy(title: String, url: URL) async -> String? {
        let host = url.host()
        let cleaned = clean(title, host: host)
        if let c = cleaned, !uninformative(c, host: host) { return c }
        // AppleAI returns nil for every kind of "no answer" — unavailable, off, refused,
        // timed out — and every one of them means the same thing here: keep the cheap one.
        guard let raw = await AppleAI.shortTitle(for: title, url: url),
              let checked = validate(raw, original: title) else { return cleaned }
        return checked
    }

    // MARK: - Storage
    //
    // Two dictionaries per profile, both url → string, and they are separate because their
    // lifetimes are: the cache is disposable and the rename is the user's own data.

    private static let cacheKey = "tidyTitleCache"
    private static let overrideKey = "tidyTitleOverrides"

    private static func dict(_ base: String, _ profileID: UUID) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: ProfileManager.defaultsKey(base, profileID))
            as? [String: String] ?? [:]
    }

    private static func put(_ base: String, _ profileID: UUID, _ url: String, _ value: String?) {
        var d = dict(base, profileID)
        d[url] = value
        let key = ProfileManager.defaultsKey(base, profileID)
        if d.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(d, forKey: key) }
    }

    /// The user's own name for this tab, from a double-click on the chip.
    static func override(for url: URL, in profileID: UUID) -> String? {
        let name = dict(overrideKey, profileID)[url.absoluteString]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// nil clears it and hands the tab back to the tidier.
    static func rename(_ url: URL, in profileID: UUID, to name: String?) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        put(overrideKey, profileID, url.absoluteString,
            (trimmedName?.isEmpty ?? true) ? nil : trimmedName)
    }

    static func rename(_ tab: Tab, to name: String?) {
        guard let url = tab.currentURL else { return }
        rename(url, in: tab.profileID, to: name)
        tab.objectWillChange.send()      // the chip re-reads `title(for:)`
    }

    // MARK: - What the UI shows

    /// The one thing the chrome should call. Sync, because SwiftUI's `body` is.
    ///
    /// ponytail: the rename wins even for an unpinned tab. "Never retitle an unpinned tab"
    /// is a rule about *us* inventing a name behind the user's back; a name the user typed
    /// is not us, and Arc keeps it across an unpin too.
    static func title(for tab: Tab) -> String {
        guard let url = tab.currentURL else { return tab.title }
        if let name = override(for: url, in: tab.profileID) { return name }
        guard enabled, tab.pinned else { return tab.title }
        if let hit = dict(cacheKey, tab.profileID)[url.absoluteString] { return hit }
        // Nothing cached yet: the deterministic answer is available *now*, so show it rather
        // than flashing the long title while `refresh` decides whether to ask the model.
        return clean(tab.title, host: url.host()) ?? tab.title
    }

    /// Fill the cache for a pinned tab, asking the model only if it has to. Fire and forget:
    /// call it when a tab is pinned and when a pinned tab finishes retitling.
    ///
    /// The cache is what keeps a pinned tab from re-running a multi-second inference on every
    /// reload, and it is persisted per profile so a relaunch does not pay for it again.
    ///
    /// ponytail: keyed by url, so a single-page app that swaps its title without navigating
    /// keeps the first name it was tidied under. Ceiling: refreshing it would need a
    /// title-versus-cache comparison on every KVO tick, which is a lot of machinery to fix
    /// the label on a chip.
    static func refresh(_ tab: Tab) {
        guard enabled, tab.pinned, !tab.isPrivate,
              let url = tab.currentURL, url.scheme?.hasPrefix("http") == true else { return }
        let key = url.absoluteString
        guard dict(cacheKey, tab.profileID)[key] == nil else { return }
        let raw = tab.title
        guard !raw.isEmpty, raw != "New Tab" else { return }
        let profileID = tab.profileID
        Task { @MainActor [weak tab] in
            guard let out = await tidy(title: raw, url: url) else { return }
            var cache = dict(cacheKey, profileID)
            // ponytail: no LRU. A pinned strip is a handful of urls; if it ever gets absurd,
            // throwing the whole cache away costs one re-run per pin and zero code.
            if cache.count > 200 {
                UserDefaults.standard.removeObject(forKey: ProfileManager.defaultsKey(cacheKey, profileID))
                cache = [:]
            }
            put(cacheKey, profileID, key, out)
            tab?.objectWillChange.send()
        }
    }

    /// Drop everything remembered for a profile. For profile deletion and for a settings
    /// toggle that should not leave stale names behind.
    static func forget(_ profileID: UUID) {
        for base in [cacheKey, overrideKey] {
            UserDefaults.standard.removeObject(forKey: ProfileManager.defaultsKey(base, profileID))
        }
    }

    // MARK: - check

    /// Offline only. Nothing here reaches Apple Intelligence, a window server, a profile on
    /// disk or the network — the model half is exercised by pinning a tab.
    ///
    /// Every title below was fetched from the live site with curl before it was written down,
    /// not remembered. That matters: a cleaner tuned against invented titles is tuned against
    /// nothing. The one exception is the Gmail row, whose format is real but whose address is
    /// anonymised, and it is labelled as such.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        // host, real title, what a pinned chip should say
        let real: [(String, String, String)] = [
            // The canonical case, and the one that names the feature.
            ("en.wikipedia.org", "Apollo program - Wikipedia", "Apollo program"),
            // A hyphen inside the *title*. It has no spaces round it, so it is not a separator.
            ("en.wikipedia.org", "Hyper-threading - Wikipedia", "Hyper-threading"),
            // Separator twice, and the site names itself at both ends.
            ("github.com", "GitHub - swiftlang/swift: The Swift Programming Language · GitHub",
             "swiftlang/swift: The Swift Programming Language"),
            // A site name that legitimately contains a hyphen, plus a strapline behind it.
            ("f-droid.org", "404 Page Not Found | F-Droid - Free and Open Source Android App Repository",
             "404 Page Not Found"),
            // Every segment is the site. Must not come back empty.
            ("f-droid.org", "F-Droid | F-Droid - Free and Open Source Android App Repository", "F-Droid"),
            // The other hyphenated site name, lowercase this time.
            ("www.e-flux.com", "Journal - e-flux", "Journal"),
            // Site first, strapline second — dropping the site here would be exactly wrong.
            ("arstechnica.com",
             "Ars Technica - Serving the Technologist since 1998. News, reviews, and analysis.",
             "Ars Technica"),
            ("www.nytimes.com",
             "The New York Times - Breaking News, US News, World News and Videos",
             "The New York Times"),
            ("linear.app", "Linear – The system for product development", "Linear"),   // en dash
            ("bun.sh", "Bun — A fast all-in-one JavaScript runtime", "Bun"),           // em dash
            ("svelte.dev", "Svelte • Web development for the rest of us", "Svelte"),   // bullet
            // CJK: no spaces, so word counts are useless and only the separator helps.
            ("zh.wikipedia.org", "中國 - 维基百科，自由的百科全书", "中國"),
            ("ko.wikipedia.org", "서울특별시 - 위키백과, 우리 모두의 백과사전", "서울특별시"),
            // Emoji prefix survives — at chip width a leading glyph is the most legible part.
            ("emojipedia.org", "🚀 Rocket Emoji | Meaning, Copy And Paste", "🚀 Rocket Emoji"),
            // Boilerplate head, and a three-letter host token that must not match loosely.
            ("www.bbc.co.uk", "Home - BBC News", "BBC News"),
            ("www.bbc.co.uk", "BBC Sport - Scores, Fixtures, News - Live Sport", "BBC Sport"),
            // Already short enough. Left exactly alone, both of them.
            ("news.ycombinator.com", "Hacker News", "Hacker News"),
            ("mail.proton.me", "Proton Mail", "Proton Mail"),
            ("developer.apple.com", "View | Apple Developer Documentation", "View"),
            ("www.youtube.com", "Me at the zoo - YouTube", "Me at the zoo"),
            ("vercel.com", "Agentic Infrastructure - Vercel", "Agentic Infrastructure"),
            // Gmail's real title format; the address is anonymised. Unread badge in the middle.
            ("mail.google.com", "Inbox (12) - ada@example.com - Gmail", "Inbox"),
        ]

        for (host, title, want) in real {
            assert("\"\(title)\" → \"\(want)\"", clean(title, host: host) == want)
        }

        // The invariant, over every real title above: removal only, never growth.
        assert("no real title is ever made longer",
               real.allSatisfy { (clean($0.1, host: $0.0)?.count ?? 0) <= $0.1.count })
        assert("no real title is ever cleaned to nothing",
               real.allSatisfy { clean($0.1, host: $0.0)?.isEmpty == false })

        // Two real titles the cheap path shortens but cannot finish. This is the *only*
        // reason the model exists here, and the handoff has to be visible in the check.
        let so = "python - How do I sort a dictionary by value? - Stack Overflow"
        let pr = "GenericSpecializer: support specializing typed throws by eeckstein "
            + "· Pull Request #70000 · swiftlang/swift · GitHub"
        assert("stack overflow loses its site name but is still too long for a chip",
               clean(so, host: "stackoverflow.com") == "python - How do I sort a dictionary by value?"
               && uninformative(clean(so, host: "stackoverflow.com")!, host: "stackoverflow.com"))
        assert("a github pull request is trimmed twice and still handed to the model",
               clean(pr, host: "github.com")
                   == "GenericSpecializer: support specializing typed throws by eeckstein"
               && uninformative(clean(pr, host: "github.com")!, host: "github.com"))
        assert("a title the cheap path finished is never handed to the model",
               !uninformative("Apollo program", host: "en.wikipedia.org")
               && !uninformative("Hacker News", host: "news.ycombinator.com"))
        // Regression: this used to be flagged, because "arstechnicacom" ends with
        // "arstechnica" + "com". The model was then asked, and answered "Tech News".
        assert("a site's own name is not mistaken for its bare domain",
               !uninformative("Ars Technica", host: "arstechnica.com")
               && !uninformative("Proton Mail", host: "mail.proton.me"))

        // --- Uninformative ---
        assert("a page with no title, showing its own domain, is uninformative",
               uninformative("example.com", host: "example.com"))
        assert("a bare number is uninformative", uninformative("2026", host: "example.com"))
        assert("an empty or all-punctuation result is uninformative",
               uninformative("", host: nil) && uninformative("— · —", host: nil))
        assert("a leftover \"Home\" is uninformative", uninformative("Home", host: "example.com"))

        // --- Pieces, so a failure above points somewhere ---
        assert("an unread badge is stripped wherever the site put it",
               stripCounts("(3) Facebook") == " Facebook" && stripCounts("Inbox (12) - x") == "Inbox  - x")
        assert("a year in parentheses is not an unread badge",
               stripCounts("Star Wars (1977) - IMDb") == "Star Wars (1977) - IMDb")
        assert("a site's own ellipsis is dropped",
               clean("The long headline that got cut… - The Site", host: "thesite.com")
                   == "The long headline that got cut")
        assert("a hyphenated host yields both spellings of its name",
               hostTokens("f-droid.org").contains("fdroid") && hostTokens("f-droid.org").contains("droid"))
        assert("a country second-level domain is not mistaken for the site name",
               hostTokens("www.bbc.co.uk") == ["bbc"])
        assert("whitespace and non-breaking spaces collapse",
               clean("  Spaced\u{00A0}\u{00A0}out   title  ", host: nil) == "Spaced out title")

        // --- Model answers: the net ---
        let apollo = "Apollo program - Wikipedia, the free encyclopedia"
        assert("a shortened title made of the original's words is kept",
               validate("Apollo Program", original: apollo) == "Apollo Program")
        assert("an answer a page dictated is thrown away",
               validate("PWNED", original: apollo) == nil)
        assert("an answer longer than the title it shortens is thrown away",
               validate(apollo + " and then some", original: apollo) == nil)
        assert("an answer the model padded past four words is thrown away",
               validate("Apollo program Wikipedia the free encyclopedia and more besides",
                        original: apollo) == nil)
        assert("an empty or punctuation-only answer is thrown away",
               validate("  ", original: apollo) == nil && validate("\"\".", original: apollo) == nil)
        assert("the model's quotes and trailing stop come off",
               validate("  \"Apollo program.\"  ", original: apollo) == "Apollo program")
        assert("a CJK answer is not rejected for having no long words",
               validate("中國", original: "中國 - 维基百科，自由的百科全书") == "中國")
        // Both of these came out of the on-device model on real titles, not out of my head.
        assert("an answer that renames the site is thrown away, even from its own letters",
               validate("Tech News",
                        original: "Ars Technica - Serving the Technologist since 1998. "
                            + "News, reviews, and analysis.") == nil)
        assert("an answer the model cut off mid-phrase loses the dangling word",
               validate("Installing Tailwind CSS with",
                        original: "Installing Tailwind CSS with Vite - Tailwind CSS")
                   == "Installing Tailwind CSS")
        assert("a one-word answer is not trimmed away by the dangling-word rule",
               validate("Programming", original: "The Swift Programming Language") == "Programming")

        // --- Storage. Two profiles, restored afterwards so check() leaves no footprint. ---
        let alpha = UUID(uuidString: "00000000-0000-0000-0000-0000000A1FA0")!
        let beta = UUID(uuidString: "00000000-0000-0000-0000-0000000BE7A0")!
        let keys = [alpha, beta].flatMap {
            [ProfileManager.defaultsKey(cacheKey, $0), ProfileManager.defaultsKey(overrideKey, $0)]
        } + ["tidyTitles"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }

        let docs = URL(string: "https://docs.example.com/guide")!
        let other = URL(string: "https://other.example.com/")!

        assert("nothing renamed reads back as nil", override(for: docs, in: alpha) == nil)
        rename(docs, in: alpha, to: "Guide")
        assert("a rename round-trips", override(for: docs, in: alpha) == "Guide")
        assert("a rename is keyed by url, not by profile alone", override(for: other, in: alpha) == nil)
        assert("a rename in one profile is invisible in another", override(for: docs, in: beta) == nil)
        rename(docs, in: beta, to: "Handbook")
        assert("the two profiles hold different names",
               override(for: docs, in: alpha) == "Guide" && override(for: docs, in: beta) == "Handbook")
        rename(docs, in: alpha, to: nil)
        assert("nil clears the rename", override(for: docs, in: alpha) == nil)
        assert("clearing one profile leaves the other alone", override(for: docs, in: beta) == "Handbook")
        rename(docs, in: beta, to: "   ")
        assert("an all-whitespace rename clears rather than blanking the tab",
               override(for: docs, in: beta) == nil)

        UserDefaults.standard.removeObject(forKey: "tidyTitles")
        let byDefault = enabled
        enabled = false
        let offRoundTrip = enabled
        enabled = true
        assert("tidying is on unless it was turned off", byDefault == true)
        assert("the switch round-trips through UserDefaults", offRoundTrip == false && enabled == true)

        return out
    }
}
