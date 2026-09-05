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

    /// Which Space an ordinary window opens in: the one it was asked for, else the profile's
    /// last-used one, else its first. Nil only for a profile with no Spaces at all, which
    /// `ProfileManager.ensureSpaces` is what makes impossible.
    ///
    /// Pure so the rule can be proved without a window server; `resolve` is the one line of
    /// I/O around it.
    static func pick(asked: Space?, last: UUID?, from all: [Space]) -> Space? {
        if let asked { return asked }
        return all.first { $0.id == last } ?? all.first
    }

    /// `pick`, against the profile's real Spaces — creating and migrating its first one if
    /// it has none. Private windows never come through here: Arc's incognito has no Spaces
    /// either, and a window that writes nothing down must not create a Space as a side
    /// effect of being opened.
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
    /// threshold and the debounce can be proved without a trackpad.
    ///
    /// One switch per gesture: `armed` goes false the moment the threshold is crossed and
    /// only comes back when the fingers leave the trackpad (`ended`). Without it a single
    /// long swipe walks through every Space in the profile, and the momentum phase walks
    /// through them again.
    struct Swipe {
        /// Points of horizontal travel before a swipe counts. Below ~30 a diagonal scroll on
        /// a long tab list switches Space by accident.
        static let threshold: CGFloat = 40

        private(set) var travel: CGFloat = 0
        private(set) var armed = true

        /// Feeds one scroll event. Returns +1 for "next Space", -1 for "previous", nil for
        /// "not yet". `dx` is `NSEvent.scrollingDeltaX`: fingers moving left produce a
        /// negative delta and mean "bring on what is to the right", i.e. the next Space.
        mutating func feed(dx: CGFloat, ended: Bool) -> Int? {
            if ended { travel = 0; armed = true; return nil }
            travel += dx
            guard armed, abs(travel) >= Self.threshold else { return nil }
            armed = false
            let direction = travel < 0 ? 1 : -1
            travel = 0
            return direction
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

        // The swipe: one switch per gesture, in the direction the fingers went.
        var s = Swipe()
        assert("a nudge below the threshold does not switch space",
               s.feed(dx: -Swipe.threshold + 1, ended: false) == nil)
        assert("crossing the threshold leftwards goes to the next space",
               s.feed(dx: -2, ended: false) == 1)
        assert("the rest of the same swipe switches nothing else",
               s.feed(dx: -200, ended: false) == nil && s.feed(dx: -200, ended: false) == nil)
        assert("the gesture ending re-arms it", s.feed(dx: 0, ended: true) == nil && s.armed)
        assert("crossing it rightwards goes to the previous space",
               s.feed(dx: Swipe.threshold, ended: false) == -1)
        var back = Swipe()
        assert("a swipe that changes its mind still needs the full threshold",
               back.feed(dx: -30, ended: false) == nil && back.feed(dx: 30, ended: false) == nil)
        assert("travel is signed, so left then right cancels out", back.travel == 0)
        var drift = Swipe()
        assert("many small deltas add up to one switch",
               (0..<7).compactMap { _ in drift.feed(dx: -8, ended: false) } == [1])

        return out
    }
}
