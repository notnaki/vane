import Foundation

/// Arc's "Tidy Tabs": once a window has more open tabs than anyone is actually reading,
/// offer to shuffle them into named, contiguous runs.
///
/// The whole action is a **reorder**. Nothing is closed, nothing is moved to a space,
/// nothing is renamed. That is deliberate: a reorder is the only tab operation that is
/// cheap to undo exactly, and a feature whose first move is "let me reorganise your
/// windows" has to be trivially reversible or nobody dares press it twice.
///
/// Two ways to get a grouping, in this order:
///
/// 1. `AppleAI.group` — the on-device model, which actually reads the titles and can tell
///    that "Swift Concurrency" and "Sendable, explained" are the same piece of work even
///    though one is on apple.com and the other is on a blog. Costs 3–10s.
/// 2. `plan(candidates:)`'s pure fallback — registrable domain first, then shared title
///    tokens. No model, no availability check, no latency. A Mac that cannot run Apple
///    Intelligence (or a user who switched it off) still gets a real grouping, because
///    "six tabs on github.com belong together" needs no language model to notice.
///
/// The fallback is not a stub: it is what runs whenever the model is off, times out,
/// refuses, or hands back something absurd. So it is a pure function over a plain struct
/// and `check()` drives all of it with no browser, no window server and no model.
@MainActor enum TidyTabs {

    // MARK: - Types

    /// A named run of tabs. Ids, not tabs — so every ordering rule below is testable
    /// without constructing a `Tab`, which would mean a WKWebView and a WebContent process.
    struct Group: Equatable {
        var name: String
        var tabIDs: [Tab.ID]

        init(name: String, tabIDs: [Tab.ID]) {
            self.name = name
            self.tabIDs = tabIDs
        }
    }

    /// Everything grouping needs to know about one tab. Same trick `Suspension.Facts`
    /// plays: gather the browser-shaped inputs in one place so the decision itself is pure.
    struct Candidate: Equatable {
        var id: Tab.ID
        var title: String
        /// `URL.host`, or "" for about:blank and friends. Not the registrable domain —
        /// folding to that is `registrableDomain`'s job and is asserted separately.
        var host: String

        init(id: Tab.ID, title: String = "", host: String = "") {
            self.id = id
            self.title = title
            self.host = host
        }
    }

    // MARK: - Settings

    /// Six is Arc's number and it is a good one: five tabs fit in a strip and you can still
    /// point at the one you want; past six you start hunting. Clamped, because a junk value
    /// in defaults should not be able to offer at every second tab or never offer at all.
    static var threshold: Int {
        get {
            let v = UserDefaults.standard.object(forKey: "tidyTabsThreshold") as? Int ?? 6
            return min(max(v, 2), 50)
        }
        set { UserDefaults.standard.set(min(max(newValue, 2), 50), forKey: "tidyTabsThreshold") }
    }

    /// Defaults on. Unlike the AI features this one has no hardware or privacy story to gate
    /// on — the fallback works everywhere — and it never acts on its own: `shouldOffer` only
    /// says "there is something to offer", the user still has to say yes.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "tidyTabs") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tidyTabs") }
    }

    /// A name longer than this is not a group name, it is a sentence. Deliberately tighter
    /// than `AppleAI.titleLimit` (28) because this lands on a strip header, not in a tab.
    static let nameLimit = 24
    /// More than this and the "grouping" is just the tab list with extra steps.
    static let maxGroups = 8

    // MARK: - Offering

    /// The tabs this feature is allowed to touch. Pinned tabs are excluded because
    /// `TabStore` enforces "every pinned tab ahead of every unpinned one" as a hard
    /// invariant, so a pinned tab literally cannot join a group in the middle of the strip.
    static func candidates(in store: TabStore) -> [Candidate] {
        store.tabs.filter { $0.kind == .today }.map {
            Candidate(id: $0.id, title: $0.title, host: $0.currentURL?.host ?? "")
        }
    }

    /// Pure half of `shouldOffer`, so the threshold rule is provable offline.
    static func shouldOffer(ordinary: Int, threshold: Int, enabled: Bool) -> Bool {
        enabled && ordinary > threshold
    }

    /// Does this window have enough of a pile to be worth offering?
    ///
    /// Two exclusions, for two different reasons:
    ///
    /// - **Pinned tabs** do not count because they are not tidyable at all (see
    ///   `candidates`). Counting tabs the feature cannot move would mean offering to tidy
    ///   a window whose only mess is a row of pins the user arranged on purpose.
    /// - **The active tab** does not count because it is the one tab that is never lost.
    ///   The problem Tidy Tabs solves is "I cannot find anything *behind* what I am looking
    ///   at", so the pile is what is behind it. This is off-by-one against Arc and that is
    ///   the point: a window of exactly seven where one is the tab you are reading is six
    ///   tabs of mess, not seven, and does not get nagged.
    ///
    /// Note that the active tab is still a *candidate* — it gets grouped, it just does not
    /// count. Grouping cannot dethrone it: `TabStore.current` is an id, and reordering an
    /// array does not change which id is in it.
    static func shouldOffer(_ store: TabStore) -> Bool {
        let ordinary = store.tabs.filter { $0.kind == .today && $0.id != store.current }.count
        return shouldOffer(ordinary: ordinary, threshold: threshold, enabled: enabled)
    }

    // MARK: - Planning

    /// Ask the model, fall back to arithmetic. Returns nil only when there is genuinely
    /// nothing to say — fewer than two tabs, or the caller cancelled.
    ///
    /// **Latency: measured at 11.7–11.8s** for ten tabs on an M-series Mac, three runs, cold
    /// each time (`AppleAI.prewarm` had not run). That is slower than the 3–10s this was
    /// budgeted for and it is under `AppleAI.group`'s own 30s timeout, so it completes — but
    /// whatever calls this needs a spinner and a Cancel, not an hourglass cursor. It is
    /// acceptable because this only ever runs from an explicit "Tidy Tabs" click, but the
    /// caller owns the `Task` and must be able to cancel it — hence the cancellation check
    /// before the fallback, so a cancelled tidy does not quietly deliver a different answer
    /// half a second later. Nothing blocks the main actor: the awaits release it, and the
    /// fallback is a few hundred string comparisons.
    static func plan(for store: TabStore) async -> [Group]? {
        let tabs = candidates(in: store)
        guard tabs.count >= 2 else { return nil }

        if AppleAI.ready,
           let raw = await AppleAI.group(tabs.map { (id: $0.id.uuidString, title: $0.title, host: $0.host) }) {
            // AppleAI.group already dropped invented ids and tidied the names. This is the
            // second gate: shape, not hygiene — see `sanitize`.
            let byString = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id.uuidString, $0.id) })
            let mapped = raw.map { Group(name: $0.name, tabIDs: $0.ids.compactMap { byString[$0] }) }
            if let ok = sanitize(mapped, candidates: tabs) { return ok }
        }
        // A cancelled tidy delivers nothing, not a consolation grouping.
        guard !Task.isCancelled else { return nil }
        return plan(candidates: tabs)
    }

    // MARK: - The deterministic fallback

    /// Group by registrable domain, then by shared title tokens, then sweep up.
    ///
    /// Pure, total, and the same input always gives the same output — which is what makes
    /// `apply` idempotent and makes every assertion in `check()` possible.
    ///
    /// ponytail: domain before tokens, and the cost of that order is measured rather than
    /// guessed. Ten realistic tabs — three Swift, three Lisbon, two cooking, plus a Google
    /// Docs spreadsheet and Gmail — the model returned Programming / Travel / Cooking /
    /// Finance. This returned `Google: flights, payroll, inbox`, because google.com is a
    /// portal, not a topic: it swallowed the flight search away from the two other Lisbon
    /// tabs. Running tokens first fixes exactly that case and breaks a more common one —
    /// six github.com tabs, two of which happen to share the word "issues", split into two
    /// groups. Neither order is right, a portal-domain blocklist rots the week it is
    /// written, and the honest fix is the model, which is already the first choice here.
    /// Domain-first stays because it fails *legibly*: three google.com tabs sitting next to
    /// each other is a dull grouping, not a wrong one.
    static func plan(candidates tabs: [Candidate]) -> [Group] {
        var groups: [Group] = []

        // --- Pass 1: registrable domain. The strongest signal there is, and free. ---
        var order: [String] = []
        var byDomain: [String: [Candidate]] = [:]
        for t in tabs {
            let d = registrableDomain(t.host)
            guard !d.isEmpty else { continue }
            if byDomain[d] == nil { order.append(d) }
            byDomain[d, default: []].append(t)
        }
        var claimed = Set<Tab.ID>()
        for d in order where (byDomain[d]?.count ?? 0) >= 2 && groups.count < maxGroups {
            let members = byDomain[d]!
            groups.append(Group(name: name(forDomain: d), tabIDs: members.map(\.id)))
            claimed.formUnion(members.map(\.id))
        }

        // --- Pass 2: shared title tokens, for what is left. ---
        // Greedy on the most common surviving token. Greedy rather than any real clustering
        // because the input is at most a few dozen four-word strings; a proper similarity
        // matrix here would be a lot of code to make the same call.
        var pool = tabs.filter { !claimed.contains($0.id) }
        while groups.count < maxGroups {
            var counts: [String: Int] = [:]
            for t in pool { for tok in Set(tokens(t.title)) { counts[tok, default: 0] += 1 } }
            // Ties broken alphabetically so the output is a function of the input, not of
            // dictionary iteration order.
            let best = counts.filter { $0.value >= 2 }
                .max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }
            guard let token = best?.key else { break }
            let members = pool.filter { tokens($0.title).contains(token) }
            groups.append(Group(name: token.capitalized, tabIDs: members.map(\.id)))
            let taken = Set(members.map(\.id))
            pool.removeAll { taken.contains($0.id) }
        }

        // --- Pass 3: the leftovers. ---
        // A group of one is not a group, so singletons go into "Other" — but only if there
        // are at least two of them, because an "Other" holding one tab is a label on a tab.
        // A single leftover stays ungrouped and `order(_:pinned:groups:)` parks it at the
        // tail, which is the honest place for "this one belongs with nothing".
        //
        // ponytail: Other only gets made if there is room under the cap. Ceiling: a window
        // of forty tabs on nineteen different domains fills the eight groups and leaves the
        // rest loose at the tail. That is a worse tidy than a real clustering pass would
        // give, and it is still better than the pile it started as.
        if pool.count >= 2, groups.count < maxGroups {
            groups.append(Group(name: "Other", tabIDs: pool.map(\.id)))
        }
        return groups
    }

    /// eTLD+1, approximately.
    ///
    /// ponytail: no public suffix list. Last two labels, unless the second-to-last is one of
    /// the handful of registry labels the world actually uses under a ccTLD, in which case
    /// three. Ceiling, stated plainly: this gets `bbc.co.uk` and `example.com.au` right and
    /// gets `foo.github.io` wrong — it says `github.io`, so two unrelated GitHub Pages sites
    /// would be grouped together. The cost of that error is two tabs sitting next to each
    /// other in a group the user can ignore. The cost of shipping and updating a 10,000-line
    /// suffix list for tab grouping is not worth paying.
    static func registrableDomain(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return parts.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "or", "ne"]
        let take = secondLevel.contains(parts[parts.count - 2]) ? 3 : 2
        return parts.suffix(take).joined(separator: ".")
    }

    /// "news.ycombinator.com" → "Ycombinator". The apex label is the name people say out
    /// loud; the suffix is noise. Capitalisation is naive on purpose — "Github" rather than
    /// "GitHub" — because the alternative is a table of brand spellings that is wrong the
    /// day after it is written.
    static func name(forDomain domain: String) -> String {
        let label = domain.split(separator: ".").first.map(String.init) ?? domain
        return String(label.prefix(nameLimit)).capitalized
    }

    /// Words in a title that could plausibly name a group. Four characters minimum, because
    /// "for"/"the"/"vs" cluster everything with everything, and a stoplist for the words
    /// that survive the length filter but still mean nothing.
    static func tokens(_ title: String) -> [String] {
        let stop: Set<String> = [
            "with", "from", "that", "this", "your", "yours", "what", "when", "then", "than",
            "into", "onto", "over", "about", "using", "have", "here", "there", "will",
            "home", "page", "index", "untitled", "search", "results", "official", "site",
            "best", "free", "online", "login", "sign", "http", "https", "html", "www",
            "welcome", "more", "just", "make", "made", "does", "been", "very", "some",
        ]
        return title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0) && $0.contains(where: \.isLetter) }
    }

    // MARK: - Validating what the model handed back

    /// The model's answer is untrusted text, same as everywhere else in this codebase, and
    /// the failure modes here are *shape* failures rather than injection ones.
    ///
    /// Rejected outright (nil, so the caller falls back):
    /// - a group holding every candidate — "I grouped your tabs into: all of them"
    /// - fewer than two surviving groups, which is the same non-answer said differently
    /// - more than `maxGroups` groups, which is the tab list wearing a hat
    ///
    /// Repaired quietly:
    /// - unknown or repeated ids dropped (first group to claim a tab keeps it)
    /// - empty, whitespace, or enormous names — trimmed, capped, and the group dropped if
    ///   nothing readable is left
    /// - singleton groups folded into "Other", by the same rule the fallback uses
    static func sanitize(_ raw: [Group], candidates tabs: [Candidate]) -> [Group]? {
        let known = Set(tabs.map(\.id))
        guard !known.isEmpty else { return nil }

        var seen = Set<Tab.ID>()
        var kept: [Group] = []
        for g in raw {
            let ids = g.tabIDs.filter { known.contains($0) && seen.insert($0).inserted }
            guard !ids.isEmpty else { continue }
            // The absurd case, checked before singletons are folded away: a single group
            // that swallowed the window is not a grouping.
            if ids.count == known.count { return nil }
            guard let n = tidy(g.name) else { continue }
            kept.append(Group(name: n, tabIDs: ids))
        }
        guard kept.count <= maxGroups else { return nil }

        // Fold singletons together, preserving the order they were first mentioned in.
        var groups = kept.filter { $0.tabIDs.count >= 2 }
        let orphans = kept.filter { $0.tabIDs.count == 1 }.flatMap(\.tabIDs)
        if orphans.count >= 2 { groups.append(Group(name: "Other", tabIDs: orphans)) }
        return groups.count >= 2 ? groups : nil
    }

    /// One line, collapsed whitespace, no wrapping punctuation, capped at `nameLimit`.
    /// nil when there is nothing readable left.
    static func tidy(_ name: String) -> String? {
        let line = name.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var s = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.,:;-–—()[]{}"))
        if s.count > nameLimit {
            s = String(s.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - Applying, and taking it back

    /// The new strip order.
    ///
    /// Pure, and the reason every ordering assertion in `check()` needs no `Tab`:
    /// - pinned tabs come first, in exactly the order they were already in (the `TabStore`
    ///   invariant, which this must not be the thing that breaks)
    /// - then each group as one contiguous run, in group order
    /// - **within** a group, tabs keep their current relative order, not the order the model
    ///   listed them in. That is what makes this idempotent: re-running on an already-tidy
    ///   strip reproduces it exactly.
    /// - anything no group claimed keeps its relative order and settles at the tail
    ///
    /// Total in both directions: ids the groups invented are ignored, tabs the groups forgot
    /// are kept. The output is always a permutation of the input.
    static func order(_ ids: [Tab.ID], pinned: Set<Tab.ID>, groups: [Group]) -> [Tab.ID] {
        let rest = ids.filter { !pinned.contains($0) }
        var placed = Set<Tab.ID>()
        var out = ids.filter { pinned.contains($0) }
        for g in groups {
            let members = Set(g.tabIDs)
            for id in rest where members.contains(id) && placed.insert(id).inserted {
                out.append(id)
            }
        }
        out.append(contentsOf: rest.filter { !placed.contains($0) })
        return out
    }

    /// One saved order per window. ponytail: a dictionary keyed on object identity rather
    /// than a property on `TabStore` — I do not own that file, and a single-entry undo is
    /// not worth a stack. Stale entries for closed windows are pruned on the next apply.
    private static var saved: [ObjectIdentifier: [Tab.ID]] = [:]

    /// Reorder the strip. Records the previous order first, so `undo` is exact.
    ///
    /// A no-op when the strip is already in that order — including the undo record, so
    /// pressing Tidy twice still undoes back to the original mess rather than to the tidy
    /// version of it.
    static func apply(_ groups: [Group], to store: TabStore) {
        let before = store.tabs.map(\.id)
        let next = order(before, pinned: Set(store.tabs.filter(\.stays).map(\.id)), groups: groups)
        guard next != before else { return }
        let live = Set(TabStore.all.map(ObjectIdentifier.init))
        saved = saved.filter { live.contains($0.key) }
        saved[ObjectIdentifier(store)] = before
        let byID = Dictionary(uniqueKeysWithValues: store.tabs.map { ($0.id, $0) })
        store.tabs = next.compactMap { byID[$0] }
        // `store.current` is untouched on purpose: it is an id, so the active tab is still
        // the active tab, and assigning it would re-fire the didSet that resumes tabs.
    }

    static func canUndo(_ store: TabStore) -> Bool { saved[ObjectIdentifier(store)] != nil }

    /// Put the saved order back, allowing for tabs opened or closed in the meantime: what is
    /// still there goes back exactly where it was, anything new keeps its relative order at
    /// the tail. Pure, so `check()` can prove "exactly" means exactly.
    static func restore(saved order: [Tab.ID], current: [Tab.ID]) -> [Tab.ID] {
        let live = Set(current)
        let known = Set(order)
        return order.filter { live.contains($0) } + current.filter { !known.contains($0) }
    }

    /// One level, and it is consumed: undo is for "that was not what I wanted", not a
    /// history. Silently does nothing when there is nothing to undo.
    static func undo(_ store: TabStore) {
        guard let before = saved.removeValue(forKey: ObjectIdentifier(store)) else { return }
        let next = restore(saved: before, current: store.tabs.map(\.id))
        guard next != store.tabs.map(\.id) else { return }
        let byID = Dictionary(uniqueKeysWithValues: store.tabs.map { ($0.id, $0) })
        store.tabs = next.compactMap { byID[$0] }
    }

    // MARK: - check

    /// Offline only. Not one assertion here needs Apple Intelligence, a window server, or a
    /// `Tab` — every rule that matters is a pure function over ids, and that is by design
    /// rather than by luck. The model half is exercised by using the browser.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        func id(_ n: Int) -> Tab.ID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
        }

        // --- Registrable domain ---
        assert("a plain host is its own registrable domain",
               registrableDomain("github.com") == "github.com")
        assert("a subdomain folds onto its apex",
               registrableDomain("news.ycombinator.com") == "ycombinator.com")
        assert("www is not a subdomain", registrableDomain("www.apple.com") == "apple.com")
        assert("a two-part suffix keeps three labels",
               registrableDomain("www.bbc.co.uk") == "bbc.co.uk")
        assert("host case is folded", registrableDomain("GitHub.COM") == "github.com")
        assert("about:blank has no domain", registrableDomain("") == "")

        // --- Fallback: same domain ---
        let sameDomain = [
            Candidate(id: id(1), title: "swiftlang/swift", host: "github.com"),
            Candidate(id: id(2), title: "Pull requests", host: "www.github.com"),
            Candidate(id: id(3), title: "Issues · vane", host: "gist.github.com"),
        ]
        let dg = plan(candidates: sameDomain)
        assert("tabs on one domain become one group",
               dg.count == 1 && Set(dg[0].tabIDs) == Set([id(1), id(2), id(3)]))
        assert("a domain group is named after the apex label", dg.first?.name == "Github")

        // --- Fallback: shared title tokens across different domains ---
        let tokenish = [
            Candidate(id: id(1), title: "Swift Concurrency, explained", host: "a.example"),
            Candidate(id: id(2), title: "Understanding concurrency in Swift", host: "b.example"),
            Candidate(id: id(3), title: "Wirecutter: the best kettle", host: "c.example"),
            Candidate(id: id(4), title: "Kettle reviews 2026", host: "d.example"),
        ]
        let tg = plan(candidates: tokenish)
        assert("titles sharing a word group across domains",
               tg.contains { Set($0.tabIDs) == Set([id(1), id(2)]) })
        assert("a second shared word makes a second group",
               tg.contains { Set($0.tabIDs) == Set([id(3), id(4)]) })
        assert("token group names are short and readable",
               tg.allSatisfy { !$0.name.isEmpty && $0.name.count <= nameLimit })
        assert("nothing is grouped twice",
               Set(tg.flatMap(\.tabIDs)).count == tg.flatMap(\.tabIDs).count)

        // --- Fallback: singletons ---
        let strays = [
            Candidate(id: id(1), title: "swiftlang/swift", host: "github.com"),
            Candidate(id: id(2), title: "Pull requests", host: "github.com"),
            Candidate(id: id(3), title: "Weather", host: "weather.example"),
            Candidate(id: id(4), title: "Payroll", host: "hr.example"),
        ]
        let sg = plan(candidates: strays)
        assert("two tabs that fit nowhere become Other",
               sg.contains { $0.name == "Other" && Set($0.tabIDs) == Set([id(3), id(4)]) })
        let oneStray = [
            Candidate(id: id(1), title: "swiftlang/swift", host: "github.com"),
            Candidate(id: id(2), title: "Pull requests", host: "github.com"),
            Candidate(id: id(3), title: "Weather", host: "weather.example"),
        ]
        let og = plan(candidates: oneStray)
        assert("a single leftover is not given a group of its own",
               og.count == 1 && !og.flatMap(\.tabIDs).contains(id(3)))
        assert("no fallback group ever holds one tab",
               (dg + tg + sg + og).allSatisfy { $0.tabIDs.count >= 2 })
        // Forty tabs across nineteen domains: far more natural groups than the cap allows.
        let crowd = (1...40).map {
            Candidate(id: id($0), title: "Doc \($0)", host: "site\($0 / 2).example")
        }
        let cg = plan(candidates: crowd)
        assert("the fallback never exceeds the group cap", cg.count <= maxGroups)
        assert("over the cap, tabs are left loose rather than crammed in",
               cg.flatMap(\.tabIDs).count < crowd.count)
        assert("the fallback is a function of its input, not of hash order",
               plan(candidates: tokenish) == tg)
        assert("an empty window plans nothing", plan(candidates: []).isEmpty)

        // --- Threshold, including the exclusions ---
        let stored = (UserDefaults.standard.object(forKey: "tidyTabs"),
                      UserDefaults.standard.object(forKey: "tidyTabsThreshold"))
        defer {
            UserDefaults.standard.set(stored.0, forKey: "tidyTabs")
            UserDefaults.standard.set(stored.1, forKey: "tidyTabsThreshold")
        }
        UserDefaults.standard.removeObject(forKey: "tidyTabs")
        UserDefaults.standard.removeObject(forKey: "tidyTabsThreshold")
        assert("the threshold defaults to six", threshold == 6)
        assert("tidying is on by default", enabled)
        threshold = 9
        let roundTrip = threshold
        threshold = 1
        let clampedLow = threshold
        threshold = 9_000
        let clampedHigh = threshold
        enabled = false
        let offRoundTrip = enabled
        let offeredWhenOff = shouldOffer(ordinary: 50, threshold: 6, enabled: enabled)
        enabled = true
        assert("the threshold round-trips through UserDefaults", roundTrip == 9)
        assert("a junk threshold is clamped, not honoured",
               clampedLow == 2 && clampedHigh == 50)
        assert("the switch round-trips and off means never offer",
               offRoundTrip == false && offeredWhenOff == false)
        assert("exactly the threshold is not enough to offer",
               !shouldOffer(ordinary: 6, threshold: 6, enabled: true))
        assert("one past the threshold offers",
               shouldOffer(ordinary: 7, threshold: 6, enabled: true))
        // The exclusions, expressed the way shouldOffer(_:) computes them: 9 tabs, 2 pinned
        // and 1 active leaves 6 ordinary — a window that is exactly not messy enough.
        let strip = (1...9).map(id)
        let pinnedIDs: Set<Tab.ID> = [id(1), id(2)]
        let active = id(3)
        let ordinary = strip.filter { !pinnedIDs.contains($0) && $0 != active }.count
        assert("pinned tabs and the active tab do not count toward the threshold",
               ordinary == 6 && !shouldOffer(ordinary: ordinary, threshold: 6, enabled: true))
        assert("one more ordinary tab tips it over",
               shouldOffer(ordinary: ordinary + 1, threshold: 6, enabled: true))

        // --- Ordering: pinned first, active preserved, contiguous groups ---
        let groups = [Group(name: "Work", tabIDs: [id(7), id(4)]),
                      Group(name: "Reading", tabIDs: [id(9), id(5), id(3)])]
        let tidied = order(strip, pinned: pinnedIDs, groups: groups)
        assert("reordering loses and invents nothing",
               Set(tidied) == Set(strip) && tidied.count == strip.count)
        assert("pinned tabs stay first and in their original order",
               Array(tidied.prefix(2)) == [id(1), id(2)])
        assert("no pinned tab ends up behind an unpinned one",
               tidied.firstIndex(where: { !pinnedIDs.contains($0) })! == 2)
        assert("the active tab is still in the strip exactly once",
               tidied.filter { $0 == active }.count == 1)
        assert("each group lands as one contiguous run",
               groups.allSatisfy { g in
                   let idx = g.tabIDs.compactMap { tidied.firstIndex(of: $0) }.sorted()
                   return idx.count == g.tabIDs.count && idx.last! - idx.first! == idx.count - 1
               })
        assert("groups are laid out in the order they were given",
               tidied.firstIndex(of: id(4))! < tidied.firstIndex(of: id(3))!)
        assert("within a group tabs keep their current relative order",
               tidied.firstIndex(of: id(4))! < tidied.firstIndex(of: id(7))!)
        assert("ungrouped tabs settle at the tail, in their original order",
               Array(tidied.suffix(2)) == [id(6), id(8)])
        assert("applying the same plan twice changes nothing",
               order(tidied, pinned: pinnedIDs, groups: groups) == tidied)
        assert("a plan naming tabs that are gone still orders the rest",
               order(strip, pinned: pinnedIDs,
                     groups: [Group(name: "Ghosts", tabIDs: [id(99), id(4), id(5)])])
                   .count == strip.count)
        assert("a plan that forgets a tab keeps it rather than dropping it",
               Set(order(strip, pinned: [], groups: [Group(name: "Some", tabIDs: [id(4)])]))
                   == Set(strip))
        assert("with no groups at all the strip is untouched",
               order(strip, pinned: pinnedIDs, groups: []) == strip)

        // --- Undo ---
        assert("undo restores the exact original order",
               restore(saved: strip, current: tidied) == strip)
        assert("undo is order-exact, not just set-exact",
               restore(saved: strip, current: tidied).elementsEqual(strip))
        let closed = tidied.filter { $0 != id(5) }
        assert("a tab closed since the tidy does not break undo",
               restore(saved: strip, current: closed) == strip.filter { $0 != id(5) })
        assert("a tab opened since the tidy survives undo, at the tail",
               restore(saved: strip, current: tidied + [id(20)]) == strip + [id(20)])

        // --- Validating the model's answer ---
        let eight = (1...8).map { Candidate(id: id($0), title: "T\($0)", host: "h\($0).example") }
        assert("one group holding every tab is rejected",
               sanitize([Group(name: "Tabs", tabIDs: eight.map(\.id))], candidates: eight) == nil)
        assert("a single group is rejected however it is named",
               sanitize([Group(name: "Work", tabIDs: [id(1), id(2)])], candidates: eight) == nil)
        assert("an empty answer is rejected", sanitize([], candidates: eight) == nil)
        let twenty = (1...20).map { Candidate(id: id($0), title: "T\($0)", host: "h\($0).example") }
        assert("an answer with more groups than the cap is rejected",
               sanitize((0..<9).map { Group(name: "G\($0)", tabIDs: [id($0 * 2 + 1), id($0 * 2 + 2)]) },
                        candidates: twenty) == nil)
        assert("the same answer inside the cap is accepted",
               sanitize((0..<8).map { Group(name: "G\($0)", tabIDs: [id($0 * 2 + 1), id($0 * 2 + 2)]) },
                        candidates: twenty)?.count == 8)
        let good = [Group(name: "  Work   stuff \n and a whole second line ", tabIDs: [id(1), id(2), id(1)]),
                    Group(name: String(repeating: "Reading ", count: 20), tabIDs: [id(3), id(4), id(99)]),
                    Group(name: "   ", tabIDs: [id(5), id(6)]),
                    Group(name: "Stray", tabIDs: [id(7)]),
                    Group(name: "Also stray", tabIDs: [id(8)])]
        let clean = sanitize(good, candidates: eight)
        assert("a workable answer survives validation", clean != nil)
        assert("a name that runs onto a second line is cut back to the first",
               clean?.first?.name == "Work stuff")
        assert("an enormous name is capped, not accepted",
               clean?.allSatisfy { $0.name.count <= nameLimit } == true)
        assert("a group whose name is only whitespace is dropped",
               clean?.contains { $0.tabIDs.contains(id(5)) } == false)
        assert("a repeated id is only placed once",
               clean?.first?.tabIDs == [id(1), id(2)])
        assert("an id the caller never passed in is dropped",
               clean?.flatMap(\.tabIDs).contains(id(99)) == false)
        assert("singleton groups are folded into Other",
               clean?.last?.name == "Other" && clean?.last?.tabIDs == [id(7), id(8)])

        return out
    }
}
