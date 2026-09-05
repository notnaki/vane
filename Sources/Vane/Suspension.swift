import AppKit
import WebKit

/// Everything a tab needs to be drawn in the strip and later brought back exactly where it
/// was, without a WKWebView being alive in the meantime.
///
/// `state` is `WKWebView.interactionState`, which is an opaque archivable value (a `Data`
/// in practice, ~500–800 bytes) holding the whole session: the back/forward list, which
/// item is current, and its scroll offset. Assigning it to a fresh WKWebView restores all
/// of that, synchronously as far as `url` and `canGoBack` are concerned. It is the only
/// public API that captures a page without keeping its process.
struct Parked {
    var title: String
    var state: Data?

    init(title: String = "", state: Data? = nil) {
        self.title = title
        self.state = state
    }
}

extension Prefs {
    /// On by default. Thirty idle tabs are thirty WebContent processes and ~2 GB; every
    /// other browser made this call years ago.
    static var suspendTabs: Bool {
        get { UserDefaults.vane.object(forKey: "suspendTabs") as? Bool ?? true }
        set { UserDefaults.vane.set(newValue, forKey: "suspendTabs") }
    }

    /// How long a background tab has to sit untouched before it is torn down. 30 minutes:
    /// long enough that tab-flipping never trips it, short enough that a tab left open
    /// over lunch is gone. Zero or negative in defaults means "use the default".
    static var suspendAfter: TimeInterval {
        get {
            let v = UserDefaults.vane.double(forKey: "suspendAfter")
            return v > 0 ? v : 30 * 60
        }
        set { UserDefaults.vane.set(newValue, forKey: "suspendAfter") }
    }
}

/// Tab suspension: the policy, the timer and the memory-pressure source. The mechanism —
/// actually dropping and rebuilding the WKWebView — lives on `Tab` in Engine.swift, because
/// that is where the observers and delegates it has to re-wire are.
///
/// ponytail: one 60-second Timer over every tab in every window, no per-tab timers, no
/// scheduling. Thirty tabs is thirty struct comparisons a minute.
@MainActor enum Suspension {

    /// Everything the decision depends on, gathered in one place so the decision itself is
    /// a pure function that `check()` can drive without a browser in the room.
    struct Facts {
        /// The active tab of *any* window — a background window's selected tab is on screen
        /// too, and tearing it down would be visible the moment that window is raised.
        var active = false
        /// A favourite or a pinned tab: it stays in the sidebar, so the user expects it to
        /// be instant when they click it.
        var pinned = false
        /// A private tab's data store is `.nonPersistent()` and a fresh one is made per web
        /// view, so a suspended private tab would come back logged out of everything.
        var isPrivate = false
        /// Playing here, or detached into a picture-in-picture window. The second case is
        /// checked separately rather than trusted to requestMediaPlaybackState: the video
        /// is rendering in a window of its own, and a background tab whose video you are
        /// actively watching is the worst possible thing to tear down.
        var playing = false
        var loading = false
        /// Typed-in, unsubmitted form input. Suspending on top of it throws work away.
        var hasInput = false
        var suspended = false
        /// A tab with nothing loaded has nothing to reclaim.
        var loaded = true
        var idle: TimeInterval = 0
    }

    /// The whole decision table. Ordered so the cheap, certain "never" cases come first.
    ///
    /// Pinned tabs are excluded, as asked. I half disagree — pins are exactly the heavy
    /// long-lived apps (mail, chat, calendar) that cost the most to keep resident — but
    /// they are also the ones a user expects to be instant, and a pin that reloads on every
    /// click reads as a bug. ponytail: if this ever needs to change it is one more Prefs
    /// flag and one line here, not a redesign.
    static func shouldSuspend(_ f: Facts, after limit: TimeInterval) -> Bool {
        if f.suspended || !f.loaded { return false }
        if f.active || f.pinned || f.isPrivate { return false }
        if f.playing || f.loading || f.hasInput { return false }
        return f.idle >= limit
    }

    /// Least-recently-active first. Ties broken on id so the order is total and the check
    /// can assert it.
    static func lru(_ tabs: [(id: UUID, lastActive: Date)]) -> [UUID] {
        tabs.sorted {
            $0.lastActive == $1.lastActive ? $0.id.uuidString < $1.id.uuidString
                                           : $0.lastActive < $1.lastActive
        }.map(\.id)
    }

    /// Who gets suspended under memory pressure, given an LRU-ordered (oldest first) list of
    /// tabs that are otherwise eligible. Critical takes everything; warning takes the older
    /// half, so a warning that arrives while the user is working does not blow the whole
    /// window away.
    static func victims<T>(_ lruOldestFirst: [T], critical: Bool) -> [T] {
        if critical { return lruOldestFirst }
        return Array(lruOldestFirst.prefix(max(1, lruOldestFirst.count / 2)))
    }

    // MARK: Running

    /// Coarse on purpose: the interval is a floor on how late a suspension can be, and
    /// nobody can tell 30 minutes from 31.
    static let sweepInterval: TimeInterval = 60

    private static var timer: Timer?
    private static var pressure: DispatchSourceMemoryPressure?

    /// Idempotent, and called from `TabStore.init` so there is nothing to wire in main.swift.
    static func begin() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: sweepInterval, repeats: true) { _ in
            // One timer for both sweeps. Auto-archive's shortest interval is twelve hours,
            // so a minute of slop on it is beneath noticing, and a second Timer to say the
            // same thing is a second Timer.
            MainActor.assumeIsolated { sweep(); Archive.sweep() }
        }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        // The source is read back off the stored property rather than captured, so nothing
        // non-Sendable crosses into the handler.
        src.setEventHandler {
            MainActor.assumeIsolated {
                relieve(critical: pressure?.data.contains(.critical) ?? false)
            }
        }
        src.resume()
        pressure = src
    }

    static var allTabs: [Tab] { TabStore.all.flatMap(\.tabs) }

    /// On screen in some window — which for a split view is every one of its panes, not just
    /// the one the keyboard is in. Tearing down the pane beside the one being read is exactly
    /// the blank half of a split nobody would file a bug about twice.
    private static func isActive(_ tab: Tab) -> Bool {
        TabStore.all.contains { $0.current == tab.id || $0.activeSplit?.contains(tab.id) == true }
    }

    /// The cheap facts: everything that can be read without talking to the web content
    /// process. `playing` and `hasInput` are filled in later, only for tabs that got this
    /// far, because both cost a round trip into WebKit.
    private static func facts(_ tab: Tab, now: Date) -> Facts {
        Facts(active: isActive(tab), pinned: tab.stays, isPrivate: tab.isPrivate,
              loading: tab.loading, suspended: tab.suspended, loaded: tab.web.url != nil,
              idle: now.timeIntervalSince(tab.lastActive))
    }

    /// The periodic pass. Two phases: reject on the cheap facts, then ask WebKit about the
    /// expensive ones for the handful of tabs still standing.
    static func sweep(now: Date = .now) {
        guard Prefs.suspendTabs else { return }
        let limit = Prefs.suspendAfter
        for tab in allTabs {
            var f = facts(tab, now: now)
            guard shouldSuspend(f, after: limit) else { continue }
            Task { @MainActor in
                if tab.pictureInPicture {
                    f.playing = true          // detached and being watched; do not ask further
                } else {
                    // requestMediaPlaybackState reports .playing for a page-muted tab, so
                    // without the mute check, muting a tab would make it permanently
                    // unsuspendable — backwards. Everything that could still want a muted
                    // tab is excluded earlier: selected in any window, pinned, or detached
                    // into PiP. What is left is a muted video in a background tab of a
                    // background window, untouched for the idle limit.
                    // ponytail: interactionState restores scroll and history, not playback
                    // position, so a resumed tab restarts its player.
                    f.playing = await tab.isPlayingMedia() && !TabAudio.isMuted(tab)
                }
                f.hasInput = await tab.hasUnsubmittedInput()
                // Re-read the cheap facts too: the awaits above gave the user time to click.
                let fresh = facts(tab, now: .now)
                f.active = fresh.active
                f.suspended = fresh.suspended
                f.loading = fresh.loading
                f.loaded = fresh.loaded
                if shouldSuspend(f, after: limit) { tab.suspend() }
            }
        }
    }

    /// Real memory pressure. Ignores the idle clock — the system is asking now — but keeps
    /// every other exclusion, so the tab in front of the user never vanishes.
    static func relieve(critical: Bool) {
        guard Prefs.suspendTabs else { return }
        let now = Date.now
        let eligible = allTabs.filter { shouldSuspend(facts($0, now: now), after: 0) }
        let ordered = lru(eligible.map { (id: $0.id, lastActive: $0.lastActive) })
        let doomed = Set(victims(ordered, critical: critical))
        for tab in eligible where doomed.contains(tab.id) {
            Task { @MainActor in
                // Media still wins under pressure: a video that stops because memory got
                // tight is a bug the user watches happen. Unsubmitted input is *not*
                // re-checked — the alternative here is the kernel taking a whole process,
                // which loses strictly more than a half-typed comment.
                var f = facts(tab, now: .now)
                if tab.pictureInPicture {
                    f.playing = true          // detached and being watched; do not ask further
                } else {
                    // requestMediaPlaybackState reports .playing for a page-muted tab, so
                    // without the mute check, muting a tab would make it permanently
                    // unsuspendable — backwards. Everything that could still want a muted
                    // tab is excluded earlier: selected in any window, pinned, or detached
                    // into PiP. What is left is a muted video in a background tab of a
                    // background window, untouched for the idle limit.
                    // ponytail: interactionState restores scroll and history, not playback
                    // position, so a resumed tab restarts its player.
                    f.playing = await tab.isPlayingMedia() && !TabAudio.isMuted(tab)
                }
                if shouldSuspend(f, after: 0) { tab.suspend() }
            }
        }
    }

    // MARK: Per-space tab state

    /// Space switching parks tabs rather than reloading them, and a `Space` has nowhere to
    /// put an interactionState — it is a Codable struct owned by Profiles.swift, and
    /// changing its shape would rewrite everyone's spaces.json.
    ///
    /// ponytail: a sidecar file per profile, keyed space id → url → base64 state. It is
    /// pure cache: delete it and spaces still switch, just without the scroll position.
    /// Ceiling: nothing prunes it, so a space that has had a thousand urls in it keeps a
    /// thousand rows (~600 bytes each).
    enum SpaceState {
        private struct Row: Codable {
            var t: String?
            var s: String?
        }

        nonisolated static func url(for profileID: UUID, in dir: URL) -> URL {
            dir.appendingPathComponent("spacestate\(ProfileManager.suffix(profileID)).json")
        }

        private nonisolated static func read(_ profileID: UUID, in dir: URL) -> [String: [String: Row]] {
            guard let data = try? Data(contentsOf: url(for: profileID, in: dir)),
                  let all = try? JSONDecoder().decode([String: [String: Row]].self, from: data)
            else { return [:] }
            return all
        }

        /// `dir` is always `Store.directory` outside `check()`; it cannot be a default
        /// argument because reading it is main-actor work and default values are evaluated
        /// in a nonisolated context.
        static func load(space: UUID, profileID: UUID, in dir: URL) -> [String: Parked] {
            (read(profileID, in: dir)[space.uuidString] ?? [:]).mapValues {
                Parked(title: $0.t ?? "", state: $0.s.flatMap { Data(base64Encoded: $0) })
            }
        }

        static func save(_ parked: [String: Parked], space: UUID,
                         profileID: UUID, in dir: URL) {
            var all = read(profileID, in: dir)
            all[space.uuidString] = parked.mapValues { Row(t: $0.title, s: $0.state?.base64EncodedString()) }
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? data.write(to: url(for: profileID, in: dir))
        }
    }

    // MARK: Offline check

    /// Pure: a decision table, a sort, JSON round-trips in memory, and UserDefaults keys
    /// that are put back exactly as they were found. No window server, no network, no
    /// WKWebView.
    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }

        // MARK: the decision table
        let hour: TimeInterval = 3600
        let idle = Facts(idle: hour)
        assert("an idle background tab suspends", shouldSuspend(idle, after: 30 * 60))
        assert("a tab idle for less than the interval does not",
               !shouldSuspend(Facts(idle: 60), after: 30 * 60))
        assert("a tab idle for exactly the interval does",
               shouldSuspend(Facts(idle: 30 * 60), after: 30 * 60))
        var active = idle; active.active = true
        assert("the active tab of a window never suspends", !shouldSuspend(active, after: 0))
        var pinned = idle; pinned.pinned = true
        assert("a pinned tab never suspends", !shouldSuspend(pinned, after: 0))
        var priv = idle; priv.isPrivate = true
        assert("a private tab never suspends", !shouldSuspend(priv, after: 0))
        var playing = idle; playing.playing = true
        assert("a tab playing media never suspends", !shouldSuspend(playing, after: 0))
        var typing = idle; typing.hasInput = true
        assert("a tab with unsubmitted form input never suspends", !shouldSuspend(typing, after: 0))
        var loading = idle; loading.loading = true
        assert("a loading tab is left alone", !shouldSuspend(loading, after: 0))
        var already = idle; already.suspended = true
        assert("an already suspended tab is not suspended twice", !shouldSuspend(already, after: 0))
        var blank = idle; blank.loaded = false
        assert("a tab with nothing loaded has nothing to reclaim", !shouldSuspend(blank, after: 0))
        assert("a zero interval suspends every eligible tab immediately",
               shouldSuspend(Facts(idle: 0), after: 0))
        // Every "never" reason beats the timer, even at an hour idle.
        assert("no single exclusion is overridden by a long idle time",
               [active, pinned, priv, playing, typing, loading, already, blank]
                   .allSatisfy { !shouldSuspend($0, after: 0) })

        // MARK: LRU under memory pressure
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
        let d = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
        let order = lru([(id: b, lastActive: t0 + 300), (id: a, lastActive: t0),
                         (id: d, lastActive: t0 + 900), (id: c, lastActive: t0 + 600)])
        assert("lru puts the least recently used first", order == [a, b, c, d])
        assert("equal timestamps still give a stable total order",
               lru([(id: c, lastActive: t0), (id: a, lastActive: t0), (id: b, lastActive: t0)]) == [a, b, c])
        assert("a warning takes the older half, oldest first",
               victims(order, critical: false) == [a, b])
        assert("a warning with one candidate still takes it",
               victims([a], critical: false) == [a])
        assert("a warning with nothing eligible takes nothing",
               victims([UUID](), critical: false).isEmpty)
        assert("critical takes everything eligible", victims(order, critical: true) == [a, b, c, d])

        // MARK: session format round-trip
        let state = Data("interaction-state-bytes".utf8)
        let entries = [[Session.Entry(url: "https://a.example/", title: "Alpha",
                                      state: state.base64EncodedString()),
                        Session.Entry(url: "https://b.example/", title: "Beta", state: nil)],
                       [Session.Entry(url: "https://c.example/", title: "Gamma", state: nil)]]
        let encoded = Session.encode(entries) ?? Data()
        let decoded = Session.decode(encoded)
        assert("a session round-trips through the new format", decoded == entries)
        assert("the interaction state survives the round-trip",
               decoded.first?.first?.state.flatMap { Data(base64Encoded: $0) } == state)
        assert("window grouping survives the round-trip",
               decoded.count == 2 && decoded[0].count == 2 && decoded[1].count == 1)

        // The exact bytes the current build writes: an array of arrays of url strings.
        let legacy = Data(#"[["https://a.example/","https://b.example/"],["https://c.example/"]]"#.utf8)
        let old = Session.decode(legacy)
        assert("an old url-only session file still reads",
               old.map { $0.map(\.url) } == [["https://a.example/", "https://b.example/"],
                                             ["https://c.example/"]])
        assert("an old session file simply has no extra fidelity",
               old.allSatisfy { $0.allSatisfy { $0.title == nil && $0.state == nil } })
        assert("an old session file parks nothing, so those tabs load as they always did",
               Session.parked(old[0]).isEmpty)
        assert("a new session file parks what it knows",
               Session.parked(entries[0]).count == 2
               && Session.parked(entries[0])["https://a.example/"]?.title == "Alpha"
               && Session.parked(entries[0])["https://a.example/"]?.state == state)
        assert("garbage in the session file decodes to nothing, not a crash",
               Session.decode(Data("not json at all".utf8)).isEmpty)
        assert("an empty session file decodes to nothing", Session.decode(Data()).isEmpty)

        // MARK: the per-space sidecar
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vane-suspend-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let profile = ProfileManager.defaultID
        let spaceA = UUID(), spaceB = UUID()
        assert("a space with no sidecar loads empty",
               SpaceState.load(space: spaceA, profileID: profile, in: root).isEmpty)
        SpaceState.save(["https://a.example/": Parked(title: "Alpha", state: state)],
                        space: spaceA, profileID: profile, in: root)
        SpaceState.save(["https://z.example/": Parked(title: "Zulu", state: nil)],
                        space: spaceB, profileID: profile, in: root)
        let backA = SpaceState.load(space: spaceA, profileID: profile, in: root)
        assert("a space's tab state round-trips",
               backA["https://a.example/"]?.state == state && backA["https://a.example/"]?.title == "Alpha")
        assert("writing one space leaves the other alone",
               SpaceState.load(space: spaceB, profileID: profile, in: root)["https://z.example/"]?.title == "Zulu")
        assert("the sidecar is per profile",
               SpaceState.load(space: spaceA, profileID: UUID(), in: root).isEmpty)
        assert("the sidecar file lands under the profile's own name",
               SpaceState.url(for: profile, in: root).lastPathComponent == "spacestate.json")

        // MARK: defaults
        let defaults = UserDefaults.vane
        let hadToggle = defaults.object(forKey: "suspendTabs")
        let hadInterval = defaults.object(forKey: "suspendAfter")
        defer {
            defaults.set(hadToggle, forKey: "suspendTabs")
            defaults.set(hadInterval, forKey: "suspendAfter")
        }
        defaults.removeObject(forKey: "suspendTabs")
        defaults.removeObject(forKey: "suspendAfter")
        assert("suspension is on out of the box", Prefs.suspendTabs)
        assert("the default interval is 30 minutes", Prefs.suspendAfter == 30 * 60)
        Prefs.suspendTabs = false
        assert("the toggle round-trips off", Prefs.suspendTabs == false)
        Prefs.suspendTabs = true
        assert("the toggle round-trips on", Prefs.suspendTabs == true)
        Prefs.suspendAfter = 90
        assert("the interval round-trips", Prefs.suspendAfter == 90)
        defaults.set(0, forKey: "suspendAfter")
        assert("a zero interval in defaults falls back to the default, not to instant",
               Prefs.suspendAfter == 30 * 60)
        defaults.set(-5, forKey: "suspendAfter")
        assert("a negative interval in defaults falls back too", Prefs.suspendAfter == 30 * 60)

        return out
    }
}
