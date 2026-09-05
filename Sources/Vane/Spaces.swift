import AppKit
import Foundation

/// Everything Arc's Spaces do that is not a view.
///
/// The one idea the rest of the file falls out of: in Arc **the only thing Spaces share is
/// Favourites**. A Space owns its Pinned rows, its Today tabs, its name, icon, theme colour
/// and appearance; the Favourites grid belongs to the *profile* and shows in every Space of
/// it. Vane wrote Favourites into each Space (`Space.pinnedURLs`), so switching Space swapped
/// the grid out — `migrate` is what un-does that on the first read, once, in place.
enum Spaces {
    /// What a Space's icon can be. ponytail: a fixed list, not a symbol browser — 24 covers
    /// what a Space is ever named after, and the alternative is shipping a search field over
    /// an API that cannot enumerate itself. (Arc offers the emoji picker; an SF Symbol grid
    /// is the same idea in the toolkit Vane is actually built on.)
    static let icons = [
        "cloud", "star", "bolt", "book", "briefcase", "gamecontroller",
        "music.note", "heart", "leaf", "flame", "house", "cart",
        "graduationcap", "hammer", "paintbrush", "globe", "camera", "film",
        "airplane", "car", "cup.and.saucer", "sparkles", "moon", "sun.max",
    ]

    // MARK: - Every tab lives in a Space

    /// Arc's rule, and the one this half of the file exists for: a browser window always
    /// shows a Space, so a profile always has one to show. Vane used to let both be nil —
    /// a window opened with no Space kept its pinned rows in a profile-level `pinnedRows`
    /// key and its Today tabs in the session file, which is a second, invisible Space that
    /// nothing could name, switch to or move a tab out of.
    ///
    /// This is the Space such a profile is folded into, once. Named after the profile (the
    /// default profile is already called "Personal", which is Arc's name for the first
    /// Space) and wearing its colour, so the migration is invisible rather than a Space
    /// called "New Space" appearing out of nowhere.
    ///
    /// Pure, because it is the one function that can lose somebody's pinned tabs: `pinned`
    /// is what the old profile-level key held and `today` is what the session file held,
    /// and everything web-shaped in either has to come out the other side exactly once.
    static func firstSpace(id: UUID = UUID(), profileID: UUID, name: String, colorHex: String?,
                           pinned: [URL], today: [URL]) -> Space {
        func web(_ list: [URL], skipping seen: inout Set<String>) -> [URL] {
            list.filter { $0.scheme?.hasPrefix("http") == true && seen.insert($0.absoluteString).inserted }
        }
        var seen = Set<String>()
        // Pinned first, so a url that was both a pinned row and an open tab stays pinned:
        // the tab it also was comes back as that pinned row.
        let rows = web(pinned, skipping: &seen)
        let tabs = web(today, skipping: &seen)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return Space(id: id, name: trimmed.isEmpty ? "Personal" : trimmed, profileID: profileID,
                     tabURLs: tabs, pinnedURLs: [], pinnedTabURLs: rows,
                     colorHex: colorHex, icon: "cloud")
    }

    /// Rows that were stranded at profile level, appended to a Space's Pinned section: web
    /// pages only, never a second copy of one already there, and the Space's own order kept
    /// in front. Pure — this is the other function that can silently lose somebody's pinned
    /// tabs.
    static func mergedPins(_ existing: [URL], _ stranded: [URL]) -> [URL] {
        var seen = Set(existing.map(\.absoluteString))
        return existing + stranded.filter {
            $0.scheme?.hasPrefix("http") == true && seen.insert($0.absoluteString).inserted
        }
    }

    /// Which Space an ordinary window opens in: the one it was asked for, else the profile's
    /// last-used one, else its first. Nil only for a profile with no Spaces at all, which
    /// `ProfileManager.ensureSpaces` is what makes impossible.
    ///
    /// A Space that is not in `all` is not a Space this profile can show — it was deleted,
    /// or belongs to somebody else — so the request is answered with a real one rather than
    /// with a window pointing at a Space that is not on disk.
    ///
    /// Pure so the rule can be proved without a window server; `resolve` is the one line of
    /// I/O around it.
    static func pick(asked: Space?, last: UUID?, from all: [Space]) -> Space? {
        if let asked, all.contains(where: { $0.id == asked.id }) { return asked }
        return all.first { $0.id == last } ?? all.first
    }

    /// `pick`, against the profile's real Spaces — creating and migrating its first one if
    /// it has none. Private windows never come through here: Arc's incognito has no Spaces
    /// either, and a window that writes nothing down must not create a Space as a side
    /// effect of being opened.
    ///
    /// Deliberately no session tabs: opening a window is not restoring a session, and
    /// folding session.json in here would resurrect the pages a user refused with "Start
    /// Fresh" — permanently, because the Space is then what holds them. `Session.restore` is
    /// the one caller that passes them.
    @MainActor static func resolve(_ asked: Space?, for profile: Profile) -> Space? {
        let all = ProfileManager.shared.ensureSpaces(for: profile)
        return pick(asked: asked, last: TabStore.lastSpaceID(for: profile.id), from: all)
    }

    // MARK: - Favourites are global

    /// Arc caps the grid at twelve tiles.
    static let favouritesCap = 12

    /// The union of the profile's Favourites and every Space's old per-space grid, in order:
    /// what the profile already had first (it is the newest list, written by the last window
    /// to save), then each Space's, in the Space order the sidebar shows. Deduped on the
    /// absolute string, capped, and never reordered — a user's grid is muscle memory.
    ///
    /// Pure so the migration can be proved without a disk: this is the one function that can
    /// silently lose somebody's favourites.
    static func mergedFavourites(existing: [URL], perSpace: [[URL]],
                                 cap: Int = favouritesCap) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in existing + perSpace.flatMap({ $0 }) {
            guard out.count < cap, seen.insert(url.absoluteString).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// The profile's Favourites, migrating any per-space grids into them the first time. The
    /// migration is idempotent because it clears `pinnedURLs` as it goes: a second call sees
    /// nothing left to merge.
    @MainActor static func favourites(for profileID: UUID) -> [URL] {
        let key = TabStore.defaultsKey(.favourite, profileID)
        let existing = (UserDefaults.vane.stringArray(forKey: key) ?? [])
            .compactMap(URL.init(string:))
        let spaces = ProfileManager.shared.spaces(for: profileID)
        guard spaces.contains(where: { !$0.pinnedURLs.isEmpty }) else {
            return Array(existing.prefix(favouritesCap))
        }
        let merged = mergedFavourites(existing: existing, perSpace: spaces.map(\.pinnedURLs))
        UserDefaults.vane.set(merged.map(\.absoluteString), forKey: key)
        var cleared = spaces
        for i in cleared.indices { cleared[i].pinnedURLs = [] }
        ProfileManager.shared.saveSpaces(cleared, for: profileID)
        return merged
    }

    // MARK: - Moving a tab to another Space

    /// A url appended to a Space's list, without ever landing there twice. Arc drops a moved
    /// tab at the end of the section it was moved into.
    static func appending(_ url: URL, to list: [URL]) -> [URL] {
        list.contains(url) ? list : list + [url]
    }

    /// "Move to Space ▸ Work ▸ Pinned". The tab's page is written into the target Space on
    /// disk and the tab is closed here.
    ///
    /// ponytail: the url moves, not the `WKWebView`. A Space that is not on screen has no
    /// window, no web view and no strip to insert into — handing it a live tab would mean
    /// keeping every Space's tabs alive at once, which is the opposite of what a Space is
    /// for. Ceiling: the moved tab loses its scroll position and back/forward list.
    @MainActor static func move(_ id: Tab.ID, to spaceID: UUID, as kind: TabKind,
                                from store: TabStore) {
        // A private window has no Space and writes nothing down; moving one of its tabs into
        // a Space would put a page the user asked not to be remembered into spaces.json.
        guard !store.isPrivate,
              let tab = store.tabs.first(where: { $0.id == id }),
              let url = tab.currentURL, url.scheme?.hasPrefix("http") == true,
              var space = store.spaces.first(where: { $0.id == spaceID }),
              space.id != store.currentSpaceID
        else { return }
        switch kind {
        case .pinned: space.pinnedTabURLs = appending(url, to: space.pinnedTabURLs ?? [])
        default:      space.tabURLs = appending(url, to: space.tabURLs)
        }
        // The state sidecar too, so the tab comes up where it was left rather than reloading
        // from the top.
        var parked = Suspension.SpaceState.load(space: spaceID, profileID: store.profileID,
                                                in: Store.directory)
        parked[url.absoluteString] = tab.snapshot
        Suspension.SpaceState.save(parked, space: spaceID, profileID: store.profileID,
                                   in: Store.directory)
        ProfileManager.shared.updateSpace(space)
        // A favourite is global, so moving one to a Space would take it out of every other
        // Space's grid — send it down to Today first, then close it like any other tab.
        if tab.kind != .today { store.move(id, to: .today) }
        store.close(id)
        store.spacesChanged()
    }

    // MARK: - Reordering

    /// A list with the item at `from` put back at `to`, clamped. Used by dragging the footer
    /// dots; `to` is an index into the list *before* the move, the way a drop reports it.
    static func reordered<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard list.indices.contains(from), from != to else { return list }
        var out = list
        let item = out.remove(at: from)
        out.insert(item, at: min(max(to > from ? to - 1 : to, 0), out.count))
        return out
    }

    // MARK: - Deleting

    /// Deleting a Space, everything except the asking: its pages to the Archive, the folder
    /// shape forgotten, the Space gone. One function so the sidebar's "Delete Space" and
    /// Settings' minus button cannot disagree about what deleting means — Settings used to
    /// drop the pages and leave the folders behind.
    ///
    /// Refused on a profile's last Space, which is the model's half of Arc greying the item
    /// out: a profile with no Space is the state this file exists to prevent. Returns
    /// whether it happened, so the caller knows whether to switch the window somewhere.
    @discardableResult
    @MainActor static func delete(_ id: UUID, in profileID: UUID) -> Bool {
        let all = ProfileManager.shared.spaces(for: profileID)
        // Read the Space back rather than trusting the caller's copy: what is on disk is
        // what is about to be deleted, and it is newer than the copy a menu was built from.
        guard all.count > 1, let space = all.first(where: { $0.id == id }) else { return false }
        archiveContents(of: space)
        ProfileManager.shared.deleteSpace(id, in: profileID)
        TabStore.forgetShape(space: id, profileID: profileID)
        return true
    }

    /// Arc puts a deleted Space's tabs in the Archive rather than dropping them: the Space is
    /// gone, the pages are still findable in the Library.
    @MainActor static func archiveContents(of space: Space) {
        let archive = Archive.shared(for: space.profileID)
        for url in space.tabURLs + (space.pinnedTabURLs ?? []) {
            guard url.scheme?.hasPrefix("http") == true else { continue }
            archive.add(url: url, title: url.host ?? url.absoluteString)
        }
    }

    // MARK: - Two-finger swipe

    /// The horizontal swipe on the sidebar, as a state machine over scroll deltas so the
    /// tracking, the rubber band and the commit can all be proved without a trackpad.
    ///
    /// The switch happens on fingers-up, not mid-gesture: while the fingers are down the
    /// strip only *moves*, and the user can carry it back and change their mind. That is the
    /// whole difference between this and the old 40pt trip-wire, which fired under the
    /// fingers and then had to spend the rest of the gesture ignoring them.
    struct Swipe {
        /// Which part of a trackpad gesture an event belongs to. Momentum is its own case
        /// because it must be *ignored*: the fingers have already left the trackpad and the
        /// commit has already been decided, so feeding the coast back in would carry the
        /// strip through the next Space and the one after it.
        enum Phase { case began, changed, ended, momentum }

        /// How far across the sidebar the fingers have to have carried the strip for
        /// fingers-up to commit. Arc's is a bit over a third; below ~0.25 a diagonal scroll
        /// down a long tab list changes Space by accident.
        static let commitFraction: CGFloat = 0.35
        /// …or this fast, in points per second, so a flick that barely moves still switches.
        static let flickSpeed: CGFloat = 600
        /// How much of the travel past the first or last Space actually shows: the strip
        /// gives, so the gesture is answered, but it plainly does not want to go.
        static let bandGive: CGFloat = 0.3
        /// …and never further than this share of the sidebar, so the band has an end.
        static let bandCap: CGFloat = 0.12
        /// How much of the new reading each velocity sample carries; the rest is the old
        /// one. Low enough that the near-zero straggler before fingers-up cannot read as a
        /// dead stop, high enough that the flick still feels like the last few frames.
        static let speedSmoothing: CGFloat = 0.6
        /// The shortest interval a velocity sample is allowed to be measured over, in
        /// seconds. AppKit coalesces scroll events under load, and two frames' worth of
        /// travel arriving with a 1ms timestamp gap would otherwise read as ten times the
        /// speed the fingers were actually going and commit a swipe nobody asked for.
        static let minInterval: Double = 1.0 / 240

        /// Raw finger travel, signed the way `scrollingDeltaX` is: negative means the fingers
        /// went left, which brings on the *next* Space.
        private(set) var travel: CGFloat = 0
        /// Smoothed points per second, for the flick commit. Smoothed because the last event
        /// before fingers-up is often a near-zero straggler that would read as a dead stop.
        private(set) var speed: CGFloat = 0
        /// False once this gesture has committed, so one swipe is one Space. A gesture can
        /// end twice (`.ended` after `.cancelled`), and both would otherwise commit.
        private(set) var armed = true

        /// Feeds one scroll event. `offset` is where the strip should sit right now, or nil
        /// for "leave it where it is" — an event that is not the fingers moving must never
        /// stomp on a spring that is already running. `commit` is +1 for "next Space", -1
        /// for "previous", nil for "spring back".
        mutating func feed(dx: CGFloat, dt: Double, phase: Phase,
                           width: CGFloat, count: Int, index: Int) -> (offset: CGFloat?, commit: Int?) {
            switch phase {
            case .momentum:
                return (nil, nil)
            case .began:
                travel = 0
                speed = 0
                armed = true
                return (0, nil)
            case .changed:
                guard armed else { return (nil, nil) }
                travel += dx
                if dt > 0 {
                    let step = CGFloat(max(dt, Self.minInterval))
                    speed = Self.speedSmoothing * (dx / step) + (1 - Self.speedSmoothing) * speed
                }
                return (Self.offset(travel, width: width, count: count, index: index), nil)
            case .ended:
                defer { travel = 0; speed = 0 }
                guard armed, let direction = Self.commit(travel: travel, speed: speed, width: width,
                                                         count: count, index: index)
                else { return (nil, nil) }
                armed = false
                return (nil, direction)
            }
        }

        /// Where the strip sits for a given travel: 1:1 with the fingers, up to the one
        /// sidebar width that lands the neighbour exactly where the current Space is, and
        /// only `bandGive` of it when there is no Space that way to bring on.
        static func offset(_ travel: CGFloat, width: CGFloat, count: Int, index: Int) -> CGFloat {
            let stuck = count < 2
                || (travel > 0 && index <= 0)                // nothing before the first Space
                || (travel < 0 && index >= count - 1)        // nor after the last
            if stuck {
                let cap = width * bandCap
                return max(-cap, min(cap, travel * bandGive))
            }
            return max(-width, min(width, travel))
        }

        /// Fingers up: which way the strip should land, or nil to spring back. Far enough or
        /// fast enough, and the flick has to still be going the way the strip already is —
        /// a fast swipe back to where it started is a cancellation, not a commit.
        static func commit(travel: CGFloat, speed: CGFloat, width: CGFloat,
                           count: Int, index: Int) -> Int? {
            guard count > 1, travel != 0 else { return nil }
            let direction = travel < 0 ? 1 : -1
            // The swipe does not wrap, unlike ⌥⌘←/→: the rubber band has just spent the whole
            // gesture saying there is nothing over there.
            guard (0..<count).contains(index + direction) else { return nil }
            let far = abs(travel) >= width * commitFraction
            let flick = abs(speed) >= flickSpeed && (speed < 0) == (travel < 0)
            return far || flick ? direction : nil
        }
    }

    // MARK: - Offline check

    static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func assert(_ name: String, _ ok: Bool) { out.append((name, ok)) }
        func u(_ s: String) -> URL { URL(string: "https://example.com/\(s)")! }

        // Every tab lives in a Space: the Space a spaceless profile is folded into.
        let pid = UUID()
        let first = firstSpace(profileID: pid, name: "Personal", colorHex: "#6E7DD2",
                               pinned: [u("p1"), u("p2")], today: [u("t1"), u("t2")])
        assert("a migrated profile's first space is named after the profile",
               first.name == "Personal" && first.profileID == pid)
        assert("it wears the profile's colour and Arc's default icon",
               first.colorHex == "#6E7DD2" && first.icon == "cloud")
        assert("the profile-level pinned rows become the space's Pinned section",
               first.pinnedTabURLs?.map(\.lastPathComponent) == ["p1", "p2"])
        assert("the spaceless session tabs become the space's Today tabs",
               first.tabURLs.map(\.lastPathComponent) == ["t1", "t2"])
        assert("favourites are not migrated in — they are the profile's, in every space",
               first.pinnedURLs.isEmpty)
        assert("a url that was both pinned and open stays pinned, and is not also a tab",
               firstSpace(profileID: pid, name: "P", colorHex: nil,
                          pinned: [u("a")], today: [u("a"), u("b")]).tabURLs
                   .map(\.lastPathComponent) == ["b"])
        assert("the same page twice in the session comes back once",
               firstSpace(profileID: pid, name: "P", colorHex: nil,
                          pinned: [], today: [u("a"), u("a")]).tabURLs.count == 1)
        assert("a blank or non-web tab is not a page to migrate",
               firstSpace(profileID: pid, name: "P", colorHex: nil, pinned: [],
                          today: [URL(string: "about:blank")!, u("a")]).tabURLs.count == 1)
        assert("a profile with nothing to migrate still gets its space",
               firstSpace(profileID: pid, name: "Work", colorHex: nil, pinned: [], today: [])
                   .name == "Work")
        assert("a profile whose name is blank falls back to Arc's \u{201C}Personal\u{201D}",
               firstSpace(profileID: pid, name: "  ", colorHex: nil, pinned: [], today: []).name
                   == "Personal")

        // …and which Space an ordinary window resolves to.
        let a = Space(name: "A", profileID: pid), b = Space(name: "B", profileID: pid)
        assert("a window asked for a space opens in it",
               pick(asked: b, last: a.id, from: [a, b])?.id == b.id)
        assert("a window asked for none opens in the profile's last-used space",
               pick(asked: nil, last: b.id, from: [a, b])?.id == b.id)
        assert("with no last-used space it opens in the first",
               pick(asked: nil, last: nil, from: [a, b])?.id == a.id)
        assert("a last-used space that has since been deleted falls back to the first",
               pick(asked: nil, last: UUID(), from: [a, b])?.id == a.id)
        assert("only a profile with no spaces at all resolves to nothing",
               pick(asked: nil, last: nil, from: []) == nil)
        assert("a space that is not this profile's is not opened just because it was asked for",
               pick(asked: Space(name: "Gone", profileID: pid), last: b.id, from: [a, b])?.id == b.id)

        // Pinned rows stranded at profile level, merged into a Space that already exists.
        assert("stranded rows go after the space's own, in their own order",
               mergedPins([u("a")], [u("b"), u("c")]).map(\.lastPathComponent) == ["a", "b", "c"])
        assert("a stranded row the space already pins is not pinned twice",
               mergedPins([u("a"), u("b")], [u("b")]).map(\.lastPathComponent) == ["a", "b"])
        assert("the same stranded row listed twice lands once",
               mergedPins([], [u("a"), u("a")]).count == 1)
        assert("a blank or non-web stranded row is not a page to pin",
               mergedPins([], [URL(string: "about:blank")!, u("a")]).map(\.lastPathComponent) == ["a"])
        assert("nothing stranded leaves the space's rows exactly as they are",
               mergedPins([u("a"), u("b")], []).map(\.lastPathComponent) == ["a", "b"])

        // Favourites migration: the union, in space order, deduped, capped.
        assert("the profile's own favourites come first",
               mergedFavourites(existing: [u("a")], perSpace: [[u("b")]]).map(\.lastPathComponent)
                   == ["a", "b"])
        assert("every space's grid is merged in, in space order",
               mergedFavourites(existing: [], perSpace: [[u("a"), u("b")], [u("c")]])
                   .map(\.lastPathComponent) == ["a", "b", "c"])
        assert("a favourite in two spaces is kept once, at its first position",
               mergedFavourites(existing: [], perSpace: [[u("a"), u("b")], [u("b"), u("c")]])
                   .map(\.lastPathComponent) == ["a", "b", "c"])
        assert("the merged grid keeps Arc's cap of twelve",
               mergedFavourites(existing: (0..<9).map { u("e\($0)") },
                                perSpace: [(0..<9).map { u("s\($0)") }]).count == favouritesCap)
        assert("the cap keeps the profile's own favourites, not the spaces'",
               mergedFavourites(existing: (0..<12).map { u("e\($0)") }, perSpace: [[u("s")]])
                   .allSatisfy { $0.lastPathComponent.hasPrefix("e") })
        assert("nothing to merge leaves the list alone",
               mergedFavourites(existing: [u("a"), u("b")], perSpace: [[], []])
                   .map(\.lastPathComponent) == ["a", "b"])
        assert("an empty everything merges to nothing",
               mergedFavourites(existing: [], perSpace: []).isEmpty)

        // Moving a tab into a Space: appended, and never twice.
        assert("a moved tab lands at the end of the target section",
               appending(u("c"), to: [u("a"), u("b")]).map(\.lastPathComponent) == ["a", "b", "c"])
        assert("moving a tab to a space it is already in changes nothing",
               appending(u("a"), to: [u("a"), u("b")]).count == 2)
        assert("a moved tab is the only thing in an empty space",
               appending(u("a"), to: []).map(\.lastPathComponent) == ["a"])

        // Reordering the footer dots.
        assert("a dot dragged right lands after the dot it was dropped on",
               reordered([1, 2, 3, 4], from: 0, to: 3) == [2, 3, 1, 4])
        assert("a dot dragged left lands before it",
               reordered([1, 2, 3, 4], from: 3, to: 1) == [1, 4, 2, 3])
        assert("a dot dropped on itself does nothing", reordered([1, 2, 3], from: 1, to: 1) == [1, 2, 3])
        assert("a dot dragged to the end goes to the end",
               reordered([1, 2, 3], from: 0, to: 3) == [2, 3, 1])
        assert("an out-of-range drag is refused rather than crashing",
               reordered([1, 2, 3], from: 9, to: 0) == [1, 2, 3])

        // The swipe. A 300pt sidebar with three Spaces, standing in the middle one, unless
        // an assertion says otherwise.
        let w: CGFloat = 300
        func swipe(_ steps: [(CGFloat, Swipe.Phase)], dt: Double = 1.0 / 60,
                   count: Int = 3, index: Int = 1) -> (last: CGFloat?, commits: [Int]) {
            var s = Swipe(), last: CGFloat?, commits: [Int] = []
            for (dx, phase) in steps {
                let r = s.feed(dx: dx, dt: dt, phase: phase, width: w, count: count, index: index)
                last = r.offset
                if let c = r.commit { commits.append(c) }
            }
            return (last, commits)
        }
        // Slow, so the flick rule never fires and the distance rule is what is being tested.
        func slow(_ total: CGFloat, steps: Int = 20) -> [(CGFloat, Swipe.Phase)] {
            [(0, .began)] + (0..<steps).map { _ in (total / CGFloat(steps), Swipe.Phase.changed) }
                + [(0, .ended)]
        }

        assert("the strip tracks the fingers one for one",
               swipe([(0, .began), (-30, .changed), (-30, .changed)]).last == -60)
        assert("nothing is committed while the fingers are still down",
               swipe([(0, .began), (-200, .changed)]).commits.isEmpty)
        assert("a short slow drag springs back rather than switching",
               swipe(slow(-w * 0.3, steps: 60), dt: 0.05).commits.isEmpty)
        assert("past a third of the sidebar, fingers up switches to the next space",
               swipe(slow(-w * 0.4, steps: 60), dt: 0.05).commits == [1])
        assert("dragging the other way goes to the previous space",
               swipe(slow(w * 0.4, steps: 60), dt: 0.05).commits == [-1])
        assert("a short fast flick commits on velocity alone",
               swipe([(0, .began), (-20, .changed), (-20, .changed), (0, .ended)],
                     dt: 1.0 / 120).commits == [1])
        assert("a flick back the way it came is a cancellation, not a commit",
               swipe([(0, .began), (-200, .changed), (150, .changed), (0, .ended)],
                     dt: 1.0 / 120).commits.isEmpty)
        assert("the strip never travels further than one sidebar width",
               swipe([(0, .began), (-2000, .changed)]).last == -w)

        // Rubber band at the ends.
        assert("the first space gives only a fraction of the travel rightwards",
               swipe([(0, .began), (100, .changed)], index: 0).last == 30)
        assert("and never past the cap",
               swipe([(0, .began), (1000, .changed)], index: 0).last == w * Swipe.bandCap)
        assert("the first space still tracks fully leftwards, where there is a space to go to",
               swipe([(0, .began), (-100, .changed)], index: 0).last == -100)
        assert("the last space rubber-bands leftwards",
               swipe([(0, .began), (-100, .changed)], index: 2).last == -30)
        assert("a rubber-banded gesture commits nothing, however far it went",
               swipe(slow(1000, steps: 60), dt: 0.05, index: 0).commits.isEmpty)
        assert("a lone space has nowhere to go and only ever bands",
               swipe([(0, .began), (-500, .changed)], count: 1, index: 0).last == -w * Swipe.bandCap)

        // Momentum, and one commit per gesture.
        assert("momentum after the fingers leave moves nothing",
               swipe([(0, .began), (-200, .changed), (0, .ended), (-400, .momentum)]).last == nil)
        assert("a whole momentum tail switches space exactly once",
               swipe([(0, .began), (-200, .changed), (0, .ended)]
                       + Array(repeating: (-400, Swipe.Phase.momentum), count: 8),
                     dt: 0.05).commits == [1])
        var once = Swipe()
        _ = once.feed(dx: 0, dt: 0, phase: .began, width: w, count: 3, index: 1)
        _ = once.feed(dx: -200, dt: 0.05, phase: .changed, width: w, count: 3, index: 1)
        assert("the first fingers-up commits",
               once.feed(dx: 0, dt: 0, phase: .ended, width: w, count: 3, index: 1).commit == 1)
        assert("a second fingers-up in the same gesture does not",
               once.feed(dx: 0, dt: 0, phase: .ended, width: w, count: 3, index: 1).commit == nil)
        assert("and the strip is not dragged any further either",
               once.feed(dx: -99, dt: 0.05, phase: .changed, width: w, count: 3, index: 1).offset == nil)
        assert("a new gesture re-arms it",
               once.feed(dx: 0, dt: 0, phase: .began, width: w, count: 3, index: 1).offset == 0
                   && once.armed)
        assert("fingers up on an untouched strip springs back rather than committing",
               swipe([(0, .began), (0, .ended)]).commits.isEmpty)
        assert("travel is signed, so left then right cancels out",
               swipe([(0, .began), (-30, .changed), (30, .changed)]).last == 0)
        // The monitor only claims a gesture once it has a direction, which is several events
        // after the `.began` that opened it — so the state machine is routinely handed a
        // gesture that starts in the middle.
        assert("a gesture that arrives without its beginning still tracks",
               swipe([(-40, .changed), (-40, .changed), (-40, .changed)], dt: 0.05).last == -120)
        assert("…and still commits on the same rule",
               swipe([(-40, .changed), (-40, .changed), (-40, .changed), (0, .ended)],
                     dt: 0.05).commits == [1])
        // Coalesced events: a crawl's worth of travel delivered with no gap between samples,
        // which without the floor reads as forty times the speed the fingers were going.
        assert("a coalesced burst cannot fake a flick",
               swipe([(0, .began), (-2, .changed), (-2, .changed), (0, .ended)],
                     dt: 0.0001).commits.isEmpty)
        assert("…while the same travel at a real frame rate is still just a crawl",
               swipe([(0, .began), (-2, .changed), (-2, .changed), (0, .ended)],
                     dt: 1.0 / 120).commits.isEmpty)

        return out
    }
}
