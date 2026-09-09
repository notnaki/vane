import Foundation

/// Arc's "Tidy Tabs": once a window has more open tabs than anyone is actually reading,
/// offer to sort them into named folders.
///
/// **Nothing is closed and nothing is renamed**, and every move is undone exactly by one
/// press of Undo — a feature whose first move is "let me reorganise your windows" has to be
/// trivially reversible or nobody dares press it twice. What it does do is make a folder per
/// group and put the group's tabs in it. It used to only *reorder*, and that was the bug:
/// on a window whose tabs already sat beside their siblings the reorder was a no-op, so the
/// user pressed Tidy, waited out a twelve-second model call and saw nothing at all. A folder
/// carries the group's name, which is the only part of a grouping worth showing.
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
    ///
    /// One number, for one question — **Tidy's** question, both halves of it. It used to be
    /// two: this decided whether Tidy was *enabled* and `Look.tidyThreshold` decided whether
    /// it was *drawn*, with different counts behind each, so the sidebar showed a greyed-out
    /// Tidy from the sixth tab to the ninth and the user could see the feature and not use
    /// it. Now Tidy is shown and pressable on this one count, which defaults to
    /// `Look.tidyThreshold`.
    ///
    /// Clear is not on this number. It is not an AI feature, it has no setting of its own,
    /// and it appears on the fixed `Look.tidyThreshold` — see `offersHousekeeping(_:)`.
    static var threshold: Int {
        get {
            let v = UserDefaults.vane.object(forKey: "tidyTabsThreshold") as? Int ?? Look.tidyThreshold
            return min(max(v, 2), 50)
        }
        set { UserDefaults.vane.set(min(max(newValue, 2), 50), forKey: "tidyTabsThreshold") }
    }

    /// Defaults on. Unlike the AI features this one has no hardware or privacy story to gate
    /// on — the fallback works everywhere — and it never acts on its own: `shouldOffer` only
    /// says "there is something to offer", the user still has to say yes.
    static var enabled: Bool {
        get { UserDefaults.vane.object(forKey: "tidyTabs") as? Bool ?? true }
        set { UserDefaults.vane.set(newValue, forKey: "tidyTabs") }
    }

    /// A name longer than this is not a group name, it is a sentence. Deliberately tighter
    /// than `AppleAI.titleLimit` (28) because this lands on a strip header, not in a tab.
    static let nameLimit = 24
    /// More than this and the "grouping" is just the tab list with extra steps.
    static let maxGroups = 8

    // MARK: - Offering

    /// The tabs this feature is allowed to touch: the loose ones in Today.
    ///
    /// Pinned tabs are excluded because a pinned tab is one the user has already put away by
    /// hand, in whatever folder they chose; regrouping it would take a row out of that
    /// folder. Favourites are out for the same reason and one more: a favourite is a tile in
    /// a grid, not a row in a list, and there is nowhere in a grid for a folder to go.
    ///
    /// A tab already inside a *Today* folder is out for that first reason exactly: it is
    /// filed, so it is already tidy. That is also what keeps a folder the user made by hand
    /// out of a tidy's way — no group names the tabs in it, so `Pins.relay` never empties it,
    /// and the undo, which takes back only `Done.folders`, has nothing of the user's to
    /// restore.
    static func candidates(in store: TabStore) -> [Candidate] {
        let filed = store.todayShape.filed
        return store.tabs.filter { $0.kind == .today && !filed.contains($0.id.uuidString) }.map {
            Candidate(id: $0.id, title: $0.title, host: $0.currentURL?.host ?? "")
        }
    }

    /// **The one rule.** Whether this window's Today section is a pile: enough tabs in it
    /// that two housekeeping actions over them are worth the room they take.
    ///
    /// It counts the Today section and nothing else, because that is the section the actions
    /// act on. Pinned tabs and favourites are not counted — they are not tidyable at all
    /// (see `candidates`), and a window whose only mess is a row of pins the user arranged
    /// on purpose is not messy. Nor is the tab being read discounted: it used to be, and the
    /// result was a sidebar that showed Tidy from the sixth Today tab and only let you press
    /// it at the ninth. A control that is on screen and refuses to work reads as broken,
    /// and there is no reading of "tidy my tabs" under which the one on screen is exempt.
    /// It is grouped like any other — grouping cannot dethrone it, because `TabStore.current`
    /// is an id and reordering an array does not change which id is in it.
    nonisolated static func offersHousekeeping(today: Int, threshold: Int) -> Bool {
        today >= threshold
    }

    /// The same, asked of a window — which in practice is asking it about **Clear**, the
    /// only control left that this alone decides.
    ///
    /// `Look.tidyThreshold`, deliberately, and not `TidyTabs.threshold`: that one is Tidy's
    /// setting, and Clear is not an AI feature and has no setting. Reading it here meant a
    /// stray `tidyTabsThreshold` in defaults — a number the user set for Tidy, or one left
    /// behind by a Tidy they have since switched off — quietly moved or hid a control that
    /// has nothing to do with tidying.
    static func offersHousekeeping(_ store: TabStore) -> Bool {
        offersHousekeeping(today: todayCount(store), threshold: Look.tidyThreshold)
    }

    /// Tidy specifically: the pile, plus the preference being on. Clear does not ask the
    /// second question — it is not an AI feature and has nothing to switch off.
    nonisolated static func shouldOffer(today: Int, threshold: Int, enabled: Bool) -> Bool {
        enabled && offersHousekeeping(today: today, threshold: threshold)
    }

    static func shouldOffer(_ store: TabStore) -> Bool {
        // The same windows `apply` refuses: a private window writes nothing down, so a
        // folder made in one would be a control that only ever says "Nothing to tidy".
        !store.isPrivate && !store.isLittle
            && shouldOffer(today: todayCount(store), threshold: threshold, enabled: enabled)
    }

    static func todayCount(_ store: TabStore) -> Int {
        store.tabs.filter { $0.kind == .today }.count
    }

    /// What the sidebar's Tidy control is, at this moment. Pure, so the row, the command bar
    /// and `check()` cannot disagree about when a spinner is showing.
    enum Control: Equatable, Sendable {
        /// Not drawn at all: no pile, or the preference is off.
        case hidden
        /// Drawn, pressable.
        case tidy
        /// Drawn as a spinner and not pressable: a tidy is in flight for this window.
        case tidying
    }

    nonisolated static func control(today: Int, threshold: Int, enabled: Bool,
                                    running: Bool) -> Control {
        // A tidy that is already running keeps its spinner even as its own work empties the
        // Today section past the threshold — otherwise the control vanishes mid-run and the
        // click looks like it did nothing, which is the whole complaint this is fixing.
        if running { return .tidying }
        return shouldOffer(today: today, threshold: threshold, enabled: enabled) ? .tidy : .hidden
    }

    static func control(_ store: TabStore) -> Control {
        control(today: todayCount(store), threshold: threshold, enabled: enabled,
                running: TidyProgress.shared.isRunning(store))
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
        // A single leftover stays ungrouped, and `order(_:pinned:groups:filed:)` leaves it
        // loose under the folders in the order it was already in, which is the honest place
        // for "this one belongs with nothing".
        //
        // ponytail: Other only gets made if there is room under the cap. Ceiling: a window
        // of forty tabs on nineteen different domains fills the eight groups and leaves the
        // rest loose where they were. That is a worse tidy than a real clustering pass would
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
    ///
    /// `nonisolated` because it is arithmetic on a string and because the sidebar's favicon
    /// slot asks it the same question: `Favicons.letter` takes a site's initial off the
    /// label this returns, so a tab with no icon and a group of tabs with one agree about
    /// what the site is called. One rule, one ceiling, one place to fix it.
    nonisolated static func registrableDomain(_ host: String) -> String {
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
    /// - then the tabs that were **already filed** when the tidy started, in their own
    ///   relative order, so a folder the user made by hand stays exactly where it was
    /// - then each group as one contiguous run, in group order
    /// - then the leftovers — claimed by nothing, filed nowhere — in their own relative
    ///   order, underneath the folders
    /// - **within** a group, tabs keep their current relative order, not the order the model
    ///   listed them in. That is what makes this idempotent: re-running on an already-tidy
    ///   strip reproduces it exactly.
    ///
    /// **The tidy's folders land at the head of Today, under anything the user filed there
    /// themselves.** With no hand-made folder that is the head outright, which is where
    /// Arc's Tidy puts them; with one, it stays put and the new folders queue under it. Both
    /// halves matter. Sweeping *everything* unclaimed to the tail sank a "Research" folder
    /// the user made to the bottom of the sidebar on every single tidy — a filed tab is
    /// unclaimed by definition (see `candidates`) — and keeping everything unclaimed where
    /// it was buried the tidy's own folders under every loose tab instead.
    ///
    /// Total in both directions: ids the groups invented are ignored, tabs the groups forgot
    /// are kept. The output is always a permutation of the input.
    static func order(_ ids: [Tab.ID], pinned: Set<Tab.ID>, groups: [Group],
                      filed: Set<String> = []) -> [Tab.ID] {
        let rest = ids.filter { !pinned.contains($0) }
        var placed = Set<Tab.ID>()
        var runs: [Tab.ID] = []
        for g in groups {
            let members = Set(g.tabIDs)
            for id in rest where members.contains(id) && placed.insert(id).inserted {
                runs.append(id)
            }
        }
        let loose = rest.filter { !placed.contains($0) }
        return ids.filter { pinned.contains($0) }
            + loose.filter { filed.contains($0.uuidString) }
            + runs
            + loose.filter { !filed.contains($0.uuidString) }
    }

    /// Which groups become a folder, and in what order their tabs go into it.
    ///
    /// A group of one is not a folder, it is a label on a tab: singletons stay loose. Within
    /// a folder the tabs are laid down in `placement` order — the order `order(_:pinned:
    /// groups:)` decided — rather than the order the model listed them in, which is what
    /// makes tidying an already-tidy window reproduce exactly what is there.
    ///
    /// Pure, over ids, so `check()` can prove the whole shape of a tidy without a window,
    /// a folder or a `Tab`.
    static func folders(for groups: [Group], placement: [Tab.ID],
                        live: Set<Tab.ID>) -> [(name: String, tabIDs: [Tab.ID])] {
        let rank = Dictionary(placement.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: { a, _ in a })
        var claimed = Set<Tab.ID>()
        var out: [(name: String, tabIDs: [Tab.ID])] = []
        for g in groups {
            let members = g.tabIDs
                .filter { live.contains($0) && claimed.insert($0).inserted }
                .sorted { rank[$0, default: .max] < rank[$1, default: .max] }
            guard members.count >= 2 else {
                claimed.subtract(members)          // a singleton stays loose and unclaimed
                continue
            }
            out.append((name: g.name, tabIDs: members))
        }
        return out
    }

    /// What one tidy did, so undo can take all of it back. ponytail: a dictionary keyed on
    /// object identity rather than a property on `TabStore`, and stale entries for closed
    /// windows are pruned on the next apply.
    private struct Done {
        /// The whole strip's order before the tidy.
        var order: [Tab.ID]
        /// The folders this tidy made, in the order it made them.
        var folders: [UUID]
    }
    // ponytail: no `kinds` any more. A tidy moves nothing between sections, so there is no
    // section to put back — the whole of what it did is the folders and the order.

    /// A stack per window, undone last-in-first-out. It used to be one record, and a second
    /// tidy silently wrote over it — so the first one's folders and moves became permanent
    /// without anybody being told. Each record holds the whole strip's order as it was, so
    /// unwinding them newest-first lands exactly where the window started.
    private static var saved: [ObjectIdentifier: [Done]] = [:]

    /// Do it: each group of two or more becomes a named folder holding its tabs, and
    /// anything no group claimed is left exactly where it is.
    ///
    /// **This used to be a reorder and nothing else**, which is why "Tidy does nothing" was
    /// the honest report: on a window whose tabs already sat beside their siblings — which
    /// is most windows, most of the time, because tabs are opened from the page next to
    /// them — the new order equalled the old one and the whole thing was a no-op with no
    /// name, no folder and no toast to say so. Arc's Tidy Tabs makes folders, and a folder
    /// is the only outcome a user can actually see: it has the group's *name* on it.
    ///
    /// **The folders go in Today, where the tabs already are.** They used to go in Pinned,
    /// which meant a tidy quietly stopped every tab it touched from auto-archiving and made
    /// Clear skip them — a housekeeping feature whose side effect was to cancel the other
    /// housekeeping. Nothing here changes a tab's section any more: a tidied tab is an
    /// ordinary Today tab that happens to sit under a named row, so the sweep still takes it
    /// at twelve hours, ⌘W still archives it, and Clear still clears it. See
    /// `TabStore.todayShape`, which is the same `Pins` value the Pinned section uses.
    ///
    /// Returns how many folders it made. Zero means nothing happened and the caller should
    /// say so out loud rather than leaving the click in silence.
    @discardableResult
    static func apply(_ groups: [Group], to store: TabStore) -> Int {
        // A private window and a Little Vane have no Today shape written down and no tidy
        // offered; neither may be given folders that would vanish on the next relaunch.
        guard !store.isPrivate, !store.isLittle else { return 0 }
        let before = store.tabs.map(\.id)
        // `filed` is read before a thing has been filed, so it holds only what the *user* put
        // in a folder: those are the rows that keep their places, the new folders under them.
        let placement = order(before, pinned: Set(store.tabs.filter(\.stays).map(\.id)),
                              groups: groups, filed: store.todayShape.filed)
        // Only Today tabs are tidyable, and only ones that are still open.
        let live = Set(store.tabs.filter { $0.kind == .today }.map(\.id))
        let named = deduped(groups,
                            existing: store.todayShape.entries.compactMap(\.folder).map(\.name))
        let plan = folders(for: named, placement: placement, live: live)
        guard !plan.isEmpty else { return 0 }

        var done = Done(order: before, folders: [])
        store.syncShapes()      // every Today tab has a row before anything is put in a folder

        // `Pins.newFolder` rather than `TabStore.newFolder`: the store's one is ⌘⇧N — it
        // opens the name field on the folder it just made and announces it — which is right
        // for one folder the user asked for and wrong for eight arriving at once, already
        // named by the plan.
        for group in plan {
            guard let folder = store.todayShape.newFolder(named: group.name) else { continue }
            done.folders.append(folder.id)
            for id in group.tabIDs { store.todayShape.move(id.uuidString, into: folder.id) }
        }
        Motion.list {
            // The order `order(_:pinned:groups:filed:)` decided, said to the shape: whatever
            // the user had already filed left where it was — the folder they made by hand
            // included, since `relay` writes a folder down at its first tab — then each new
            // group as one run under it, then the tabs no group could take. Then the strip
            // is put in the order the sidebar now draws.
            store.todayShape.relay(placement.map(\.uuidString))
            store.applyOrder(.today)
        }
        store.savePins()
        // And the rows' names, once each and only for the tabs that have not got one — being
        // filed in a folder is not a navigation, so a tab that already has a tidy title for
        // the page it is on needs nothing asked about it. See `TidyTitles.refresh`.
        let tidied = Set(plan.flatMap(\.tabIDs))
        for tab in store.tabs where tidied.contains(tab.id) { TidyTitles.refresh(tab) }
        // `store.current` is untouched on purpose: it is an id, so the active tab is still
        // the active tab even if it has just moved into a folder, and assigning it would
        // re-fire the didSet that resumes tabs.
        let liveWindows = Set(TabStore.all.map(ObjectIdentifier.init))
        saved = saved.filter { liveWindows.contains($0.key) }
        saved[ObjectIdentifier(store), default: []].append(done)
        axAnnounce("Tidied into \(done.folders.count) folder"
                   + (done.folders.count == 1 ? "" : "s") + ".")
        return done.folders.count
    }

    /// Group names, made unique against the folders Today already has — and against each
    /// other. "GitHub" beside an existing "GitHub" becomes "GitHub 2", then "GitHub 3": two
    /// folders with the same name on the same list are two folders you cannot tell apart,
    /// and the second tidy of a morning hits it every time.
    ///
    /// Suffixed rather than refused, and capped at `nameLimit` like every other name here —
    /// the counter is what has to survive the cap, so it is the head that is trimmed.
    ///
    /// Pure, over strings, so `check()` can drive it with no folder and no window.
    static func deduped(_ groups: [Group], existing: [String]) -> [Group] {
        var taken = Set(existing.map { $0.lowercased() })
        return groups.map { g in
            guard taken.contains(g.name.lowercased()) else {
                taken.insert(g.name.lowercased())
                return g
            }
            var n = 2
            var candidate = g.name
            repeat {
                let suffix = " \(n)"
                candidate = String(g.name.prefix(nameLimit - suffix.count))
                    .trimmingCharacters(in: .whitespaces) + suffix
                n += 1
            } while taken.contains(candidate.lowercased()) && n < 100
            taken.insert(candidate.lowercased())
            return Group(name: candidate, tabIDs: g.tabIDs)
        }
    }

    static func canUndo(_ store: TabStore) -> Bool {
        saved[ObjectIdentifier(store)]?.isEmpty == false
    }

    /// Put the saved order back, allowing for tabs opened or closed in the meantime: what is
    /// still there goes back exactly where it was, anything new keeps its relative order at
    /// the tail. Pure, so `check()` can prove "exactly" means exactly.
    static func restore(saved order: [Tab.ID], current: [Tab.ID]) -> [Tab.ID] {
        let live = Set(current)
        let known = Set(order)
        return order.filter { live.contains($0) } + current.filter { !known.contains($0) }
    }

    /// The last tidy, taken back — and pressed again, the one before it. Silently does
    /// nothing when there is nothing left to undo.
    ///
    /// Exactly reversed: the folders this tidy made are dissolved — their tabs stay exactly
    /// where they are, because nothing ever left Today — and then the strip is put back in
    /// the order it had. Only the folders *this tidy* made: a folder the user made during
    /// the tidy, or before it, is not the tidy's to delete.
    static func undo(_ store: TabStore) {
        let key = ObjectIdentifier(store)
        guard let done = saved[key]?.popLast() else { return }
        if saved[key]?.isEmpty == true { saved[key] = nil }
        for folder in done.folders {
            // Not `TabStore.deleteFolder`: that announces a deletion and mirrors it into
            // every other window showing this Space. These folders were made in this window
            // and have never been anywhere else.
            store.todayShape.remove(folder: folder)
        }
        let next = restore(saved: done.order, current: store.tabs.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: store.tabs.map { ($0.id, $0) })
        Motion.list {
            store.tabs = next.compactMap { byID[$0] }
            // A tab the user pinned by hand while the model was thinking keeps the section it
            // now has, and the saved order puts it back among the Today tabs it was sitting
            // in. That breaks the one strip invariant, so the sections are settled again
            // before anything reads the strip.
            store.normaliseSections()
            store.syncShapes()
            store.applyOrder(.pinned)
            // The strip has just been handed a whole order at once, so here Today's shape
            // follows it rather than the other way round. See `Pins.relay`.
            store.todayShape.relay(store.tabs.map(\.id.uuidString))
        }
        store.savePins()
        axAnnounce("Undid the tidy.")
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

        // --- Names, made unique against the folders the Space already has ---
        let two = [Group(name: "Github", tabIDs: [id(1), id(2)]),
                   Group(name: "Kettles", tabIDs: [id(3), id(4)])]
        assert("a name nothing else uses is left exactly as it is",
               deduped(two, existing: ["Travel"]).map(\.name) == ["Github", "Kettles"])
        assert("a name a folder already has is numbered",
               deduped(two, existing: ["Github"]).map(\.name) == ["Github 2", "Kettles"])
        assert("…and numbered past the numbers already taken",
               deduped(two, existing: ["Github", "Github 2"]).map(\.name)
                   == ["Github 3", "Kettles"])
        assert("the match ignores case, because two lists cannot tell it apart either",
               deduped(two, existing: ["GITHUB"]).first?.name == "Github 2")
        assert("one tidy's own groups are made unique against each other",
               deduped([Group(name: "Github", tabIDs: [id(1), id(2)]),
                        Group(name: "Github", tabIDs: [id(3), id(4)])], existing: [])
                   .map(\.name) == ["Github", "Github 2"])
        assert("a numbered name still fits a strip header",
               deduped([Group(name: String(repeating: "n", count: nameLimit),
                              tabIDs: [id(1), id(2)])],
                       existing: [String(repeating: "n", count: nameLimit)])
                   .allSatisfy { $0.name.count <= nameLimit })
        assert("renaming never loses or reorders a group's tabs",
               deduped(two, existing: ["Github", "Kettles"]).map(\.tabIDs) == two.map(\.tabIDs))
        assert("nothing to name is nothing to do", deduped([], existing: ["Github"]).isEmpty)

        // --- The one rule: what the sidebar shows, and what it lets you press ---
        let stored = (UserDefaults.vane.object(forKey: "tidyTabs"),
                      UserDefaults.vane.object(forKey: "tidyTabsThreshold"))
        defer {
            UserDefaults.vane.set(stored.0, forKey: "tidyTabs")
            UserDefaults.vane.set(stored.1, forKey: "tidyTabsThreshold")
        }
        UserDefaults.vane.removeObject(forKey: "tidyTabs")
        UserDefaults.vane.removeObject(forKey: "tidyTabsThreshold")
        assert("the threshold defaults to the number the sidebar draws on",
               threshold == Look.tidyThreshold && threshold == 6)
        assert("tidying is on by default", enabled)
        threshold = 9
        let roundTrip = threshold
        threshold = 1
        let clampedLow = threshold
        threshold = 9_000
        let clampedHigh = threshold
        enabled = false
        let offRoundTrip = enabled
        let offeredWhenOff = shouldOffer(today: 50, threshold: 6, enabled: enabled)
        enabled = true
        assert("the threshold round-trips through UserDefaults", roundTrip == 9)
        assert("a junk threshold is clamped, not honoured",
               clampedLow == 2 && clampedHigh == 50)
        assert("the switch round-trips and off means never offer",
               offRoundTrip == false && offeredWhenOff == false)
        assert("an empty Space offers no housekeeping",
               !offersHousekeeping(today: 0, threshold: 6))
        assert("nor does one holding a handful of tabs you can already see",
               (1..<6).allSatisfy { !offersHousekeeping(today: $0, threshold: 6) })
        assert("the sixth Today tab is what brings Tidy and Clear out",
               offersHousekeeping(today: 6, threshold: 6))
        assert("…and they stay out as the pile grows",
               (6...50).allSatisfy { offersHousekeeping(today: $0, threshold: 6) })
        // Two controls, two numbers, and only one of them is a setting. Tidy is the AI
        // feature and moves with `TidyTabs.threshold`; Clear has no setting to move with, so
        // it appears on the fixed `Look.tidyThreshold` — a number in defaults meant for Tidy
        // used to hide Clear too.
        threshold = 12
        let clearFollowsLook = (0...50).allSatisfy {
            offersHousekeeping(today: $0, threshold: Look.tidyThreshold)
                == ($0 >= Look.tidyThreshold)
        }
        let tidyFollowsSetting = shouldOffer(today: 6, threshold: threshold, enabled: true) == false
            && shouldOffer(today: 12, threshold: threshold, enabled: true)
        threshold = 6
        assert("Clear's count is the fixed one, whatever the Tidy setting says",
               clearFollowsLook)
        assert("Tidy's count is the setting, and moves when the user moves it",
               tidyFollowsSetting)
        // The bug this replaces: Tidy used to be *drawn* at six and only *enabled* past
        // eight, so three counts of Today tabs showed a control that refused to work.
        assert("Tidy is shown and pressable on the same count, at every count",
               (0...50).allSatisfy {
                   shouldOffer(today: $0, threshold: 6, enabled: true)
                       == offersHousekeeping(today: $0, threshold: 6)
               })
        assert("the threshold left where it was found", threshold == Look.tidyThreshold)
        assert("switching tidying off takes Tidy away rather than greying it out",
               (0...50).allSatisfy { !shouldOffer(today: $0, threshold: 6, enabled: false) })
        assert("Clear does not care whether tidying is switched on",
               offersHousekeeping(today: 6, threshold: 6))
        assert("nothing is discounted: six Today tabs is six, whichever one is on screen",
               shouldOffer(today: 6, threshold: 6, enabled: true))
        assert("a lowered threshold shows Tidy and lets it be pressed on the same count",
               shouldOffer(today: 3, threshold: 2, enabled: true)
                   && offersHousekeeping(today: 3, threshold: 2))

        // --- What the Tidy control is, at a given moment ---
        assert("under the threshold there is no Tidy to press",
               control(today: 5, threshold: 6, enabled: true, running: false) == .hidden)
        assert("at the threshold it is there and pressable",
               control(today: 6, threshold: 6, enabled: true, running: false) == .tidy)
        assert("with tidying switched off it is not drawn at all",
               control(today: 20, threshold: 6, enabled: false, running: false) == .hidden)
        assert("while a tidy runs the control is a spinner",
               control(today: 20, threshold: 6, enabled: true, running: true) == .tidying)
        assert("and it stays a spinner even as the tidy empties the section under it",
               control(today: 0, threshold: 6, enabled: true, running: true) == .tidying)

        let strip = (1...9).map(id)
        let pinnedIDs: Set<Tab.ID> = [id(1), id(2)]
        let active = id(3)

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
        assert("tabs no group claimed sit under the folders, in their original order",
               Array(tidied.suffix(2)) == [id(6), id(8)])
        assert("…and with nothing filed by hand the tidy's own groups start Today, as "
               + "Arc's Tidy does",
               tidied.firstIndex(of: id(4))! == 2)
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
        assert("a tab that was already filed keeps its place, above everything the tidy made",
               order(strip, pinned: pinnedIDs, groups: groups, filed: [id(8).uuidString])
                   == [id(1), id(2), id(8), id(4), id(7), id(3), id(5), id(9), id(6)])
        assert("a second tidy moves nothing: the first one's tabs are filed now, so they "
               + "anchor where they are",
               order(tidied, pinned: pinnedIDs, groups: [],
                     filed: Set(groups.flatMap(\.tabIDs).map(\.uuidString))) == tidied)

        // --- Folders: which groups get one, what goes in it, and in what order ---
        //
        // Driven through `Pins` itself, which is a plain Codable value — so this is the real
        // folder model, laid out the way `apply` lays it out, with no window and no `Tab`.
        let todayIDs = Set(strip.filter { !pinnedIDs.contains($0) })
        let made = folders(for: groups, placement: tidied, live: todayIDs)
        assert("every group of two or more becomes a folder", made.count == groups.count)
        assert("a folder is named after its group",
               made.map(\.name) == ["Work", "Reading"])
        assert("a group's tabs go in in the order the tidy laid them out, not the order "
               + "the model listed them",
               made.first?.tabIDs == [id(4), id(7)])
        assert("no tab is put in two folders",
               Set(made.flatMap(\.tabIDs)).count == made.flatMap(\.tabIDs).count)
        assert("a pinned tab is never swept into a folder",
               made.flatMap(\.tabIDs).allSatisfy { !pinnedIDs.contains($0) })
        assert("a group of one is a label on a tab, not a folder",
               folders(for: [Group(name: "Lonely", tabIDs: [id(4)])],
                       placement: tidied, live: todayIDs).isEmpty)
        assert("…and its tab is left loose for a later group to claim",
               folders(for: [Group(name: "Lonely", tabIDs: [id(4)]),
                             Group(name: "Real", tabIDs: [id(4), id(5)])],
                       placement: tidied, live: todayIDs)
                   .first?.tabIDs == [id(4), id(5)])
        assert("a plan naming a tab that has been closed makes no folder for it alone",
               folders(for: [Group(name: "Ghosts", tabIDs: [id(98), id(99)])],
                       placement: tidied, live: todayIDs).isEmpty)
        assert("all singletons means no folders at all — nothing to tidy",
               folders(for: [Group(name: "A", tabIDs: [id(4)]), Group(name: "B", tabIDs: [id(5)])],
                       placement: tidied, live: todayIDs).isEmpty)
        // --- Which section a folder can live in ---
        //
        // Two shapes, one value: the folder row, its menu and its drop target are written
        // once and told which of the two they are on. A tidy's folders are Today's, which is
        // the whole of this change — the tabs in them go on auto-archiving.
        assert("Today has a shape of its own for a tidy to put its folders in",
               TabStore.shape(of: .today) == \TabStore.todayShape)
        assert("Pinned's is the one it always had",
               TabStore.shape(of: .pinned) == \TabStore.pins)
        assert("a favourite is a tile in a grid, with nowhere for a folder row to go",
               TabStore.shape(of: .favourite) == nil)
        assert("the two are different instances, so neither tidy touches the other",
               TabStore.shape(of: .today) != TabStore.shape(of: .pinned))

        // The same plan, laid into the real Pins model.
        var section = Pins()
        var folderIDs: [UUID] = []
        for group in made {
            guard let folder = section.newFolder(named: group.name) else { continue }
            folderIDs.append(folder.id)
            for tab in group.tabIDs {
                section.entries.append(Pins.Entry(row: .tab(tab.uuidString), parent: nil))
                section.move(tab.uuidString, into: folder.id)
            }
        }
        assert("the section holds one folder per group",
               section.entries.compactMap(\.folder).map(\.name) == ["Work", "Reading"])
        assert("each folder holds exactly its own group's tabs, in order",
               folderIDs.map { section.children(of: $0) }
                   == made.map { $0.tabIDs.map(\.uuidString) })
        assert("nothing is left loose at the top of the section",
               section.entries.filter { $0.tab != nil && $0.parent == nil }.isEmpty)
        assert("dissolving the tidy's folders leaves every tab behind",
               { var s = section
                 folderIDs.forEach { s.remove(folder: $0) }
                 return s.tabs.count == made.flatMap(\.tabIDs).count
                     && s.entries.compactMap(\.folder).isEmpty }())

        // --- A folder the user made by hand ---
        //
        // Its tabs are filed, so `candidates` never offers them; no group names them; so the
        // relay keeps the folder they are in, and the undo — which takes back only the
        // folders the tidy made — leaves it exactly as it was.
        //
        // And *where* it is matters as much as that it survives: rows the user had already
        // filed keep their places, so "Mine" is still the first thing in Today afterwards,
        // with the tidy's own folder under it. It used to be swept to the bottom on every
        // tidy, since a filed tab is unclaimed by definition.
        var mine = Pins(entries: (1...4).map { Pins.Entry(row: .tab(id($0).uuidString),
                                                          parent: nil) })
        let hand = mine.newFolder(named: "Mine")!
        mine.move(id(1).uuidString, into: hand.id)
        assert("a tab the user filed in a Today folder is not a tidy candidate",
               mine.filed == [id(1).uuidString])
        let work = [Group(name: "Work", tabIDs: [id(2), id(3)])]
        let untouched = order([id(1), id(2), id(3), id(4)], pinned: [],
                              groups: work, filed: mine.filed)
        assert("with no folder of the user's to sit under, the tidy's own starts Today",
               order([id(1), id(2), id(3), id(4)], pinned: [], groups: work)
                   == [id(2), id(3), id(1), id(4)])
        let fromTidy = mine.newFolder(named: "Work")!
        for tab in [id(2), id(3)] { mine.move(tab.uuidString, into: fromTidy.id) }
        mine.relay(untouched.map(\.uuidString))
        assert("a tidy leaves the folder the user made standing",
               mine.folder(fromTidy.id) != nil && mine.children(of: hand.id) == [id(1).uuidString])
        assert("…and standing where it was, rather than sinking under the tidy's own folder",
               mine.index(of: hand.id)! < mine.index(of: fromTidy.id)!)
        assert("…with the rows of Today in the order the tidy laid them out: what was filed, "
               + "then the new folder, then the tab it could not place",
               mine.tabs == [id(1), id(2), id(3), id(4)].map(\.uuidString))
        assert("…and a second tidy over that leaves every row of it alone",
               order(untouched, pinned: [], groups: [], filed: mine.filed) == untouched)
        mine.remove(folder: fromTidy.id)
        mine.relay([id(1), id(2), id(3), id(4)].map(\.uuidString))
        assert("…and so does its undo, which has only its own folders to take back",
               mine.children(of: hand.id) == [id(1).uuidString]
                   && mine.tabs == [id(1), id(2), id(3), id(4)].map(\.uuidString))

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

/// Whether a tidy is in flight, and for which window. The sidebar's Tidy row and the command
/// bar both observe it: the label becomes a spinner, the row stops answering clicks, and the
/// command bar's row reads "Tidying…".
///
/// It exists because the work takes twelve seconds. `TidyTabs.plan` calls the on-device model
/// and that call is measured at 11.7–11.8s for ten tabs; a control that looks idle for twelve
/// seconds after being pressed has told the user it did nothing, which is exactly what was
/// reported. One tidy at a time, app-wide, because `AppleAI` admits one grouping request at a
/// time anyway.
///
/// ponytail: a stamp rather than a token type. Every start bumps it, and a finish that names
/// an older stamp is a run that was cancelled and replaced — it does not get to put the
/// spinner away for the run that is still going.
@MainActor final class TidyProgress: ObservableObject {
    static let shared = TidyProgress()

    /// The window whose tidy is running, or nil.
    @Published private(set) var running: ObjectIdentifier?
    private var stamp = 0
    private var watchdog: Task<Void, Never>?

    /// The longest the spinner may stay up, whatever happens behind it. `AppleAI.group`
    /// already races its own 30s sleep and loses gracefully, so this only catches an await
    /// that never returns at all — and its job is not to be right, it is to make sure a
    /// hung model session can never leave a control disabled for the life of the window.
    static let deadline: Duration = .seconds(35)

    /// Say a tidy has started, and get the stamp to hand back to `ended`. `onDeadline` is
    /// called if the run outlives `deadline`, so the caller can cancel its own task.
    @discardableResult
    func began(_ store: TabStore, onDeadline: @escaping @MainActor () -> Void) -> Int {
        stamp += 1
        let mine = stamp
        running = ObjectIdentifier(store)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.deadline)
            guard !Task.isCancelled else { return }
            onDeadline()
            self?.ended(mine)
        }
        return mine
    }

    /// A run finished or timed out. Ignored when a newer run has started since — see the
    /// note on the type.
    func ended(_ mine: Int) {
        guard mine == stamp else { return }
        stop()
    }

    /// The user pressed Tidy again to cancel. The spinner goes **now**, rather than whenever
    /// the model call it was waiting on finally returns: `AppleAI.group` is not cancellation
    /// aware, so `Task.cancel()` only sets a flag the run reads on the way out and its
    /// `ended` can be twelve seconds away. Until it arrived the row stayed a spinner, and
    /// every press in the meantime was read as another cancel and swallowed.
    ///
    /// Bumping the stamp is what makes that safe: the cancelled run's own `ended` names a
    /// stamp that is no longer current and is ignored, so it cannot put away the spinner of
    /// whatever the user starts next.
    func cancelled() {
        stamp += 1
        stop()
    }

    private func stop() {
        watchdog?.cancel()
        watchdog = nil
        running = nil
    }

    func isRunning(_ store: TabStore) -> Bool { running == ObjectIdentifier(store) }
}
