import AppKit
import WebKit

/// Favicons, fetched from the site itself and cached by host.
///
/// ponytail: no favicon proxy service. Those are one HTTP request per site you visit sent
/// to a third party — that is a browsing-history feed, and it is not worth a rounder icon.
/// Ceiling: no ETag/Cache-Control handling, so an icon only changes when the LRU sweep
/// evicts it; the upgrade path is writing the response headers next to the bytes.
@MainActor final class Favicons: ObservableObject {
    /// The active profile's cache. An icon on disk is a record that a host was visited, so
    /// it is profile data like any other; the default profile still uses the `favicons/`
    /// folder it always used.
    static var shared: Favicons { cache(for: ProfileManager.shared.active.id) }

    private static var caches: [UUID: Favicons] = [:]

    static func cache(for profileID: UUID) -> Favicons {
        if let hit = caches[profileID] { return hit }
        let fresh = Favicons(profileID: profileID)
        caches[profileID] = fresh
        return fresh
    }

    static func forget(_ profileID: UUID) {
        caches[profileID] = nil
        try? FileManager.default.removeItem(
            at: ProfileManager.faviconDir(for: profileID, in: Store.directory))
    }

    let profileID: UUID

    init(profileID: UUID = ProfileManager.defaultID) { self.profileID = profileID }

    /// Bumped when a fetch lands, so views that asked for a nil icon redraw.
    @Published private(set) var generation = 0

    private var memory: [String: NSImage] = [:]
    private var inflight: [String: Task<Void, Never>] = [:]
    /// Hosts that had nothing to give, so a 404 isn't re-requested on every page load.
    private var misses: Set<String> = []

    private static let maxBytes = 512_000     // an icon that big is a mistake, not an icon
    private static let maxFiles = 300

    // MARK: Public

    /// Cached icon if there is one, otherwise nil and a fetch starts; `generation` bumps
    /// when it lands.
    func icon(for url: URL) -> NSImage? {
        guard let key = Favicons.key(for: url) else { return nil }
        if let img = memory[key] { return img }
        if let img = readDisk(key) { memory[key] = img; return img }
        guard !misses.contains(key), let fallback = Favicons.fallback(for: url) else { return nil }
        warm(key: key, urls: [fallback], persist: true)
        return nil
    }

    /// Call on didFinish: asks the page which icon it declares, falls back to /favicon.ico.
    func load(for tab: Tab) {
        // A local file has no host to fetch an icon from; Finder's own icon for the
        // document is what it is recognised by everywhere else on the Mac.
        if let url = tab.web.url, url.isFileURL { tab.favicon = Files.icon(for: url); return }
        guard let url = tab.web.url, let key = Favicons.key(for: url) else { tab.favicon = nil; return }
        if let img = memory[key] ?? readDisk(key) {
            memory[key] = img
            tab.favicon = img
            return
        }
        guard !misses.contains(key) else { tab.favicon = nil; return }
        tab.web.evaluateJavaScript(Favicons.linkJS) { [weak tab] result, _ in
            let declared = ((result as? String) ?? "").split(separator: "\n")
                .compactMap { URL(string: String($0)) }
            var candidates = Favicons.ordered(declared)
            if let f = Favicons.fallback(for: url) { candidates.append(f) }
            // A private tab may read the shared cache but never writes to it — a favicon
            // on disk is a record that the host was visited.
            let task = self.warm(key: key, urls: candidates, persist: !(tab?.isPrivate ?? true))
            Task { await task.value; tab?.favicon = self.memory[key] }
        }
    }

    // MARK: Fetch

    /// One fetch per host at a time; a second tab on the same host awaits the same task.
    @discardableResult
    private func warm(key: String, urls: [URL], persist: Bool) -> Task<Void, Never> {
        if let running = inflight[key] { return running }
        let task = Task { @MainActor [weak self] in
            defer { self?.inflight[key] = nil }
            for url in urls {
                guard let data = await Favicons.fetch(url),
                      let img = NSImage(data: data), img.isValid, img.size.width > 0
                else { continue }
                // Icons ship at anything from 16 to 512px; pin the point size so SwiftUI
                // picks the right representation instead of laying out a 512pt image.
                img.size = NSSize(width: 16, height: 16)
                guard let self else { return }
                self.memory[key] = img
                if persist { self.writeDisk(key, data) }
                self.generation += 1
                return
            }
            self?.misses.insert(key)
        }
        inflight[key] = task
        return task
    }

    private static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              (1...maxBytes).contains(data.count)
        else { return nil }
        return data
    }

    /// The page's own declaration. `~=` matches one word of rel, so "shortcut icon" hits.
    private static let linkJS = """
    (function(){var o=[];document.querySelectorAll(\
    "link[rel~='icon' i],link[rel~='apple-touch-icon' i],link[rel~='apple-touch-icon-precomposed' i]")\
    .forEach(function(l){if(l.href)o.push(l.href)});return o.join("\\n")})()
    """

    /// apple-touch-icons are big PNGs; a favicon.ico is often a 16px bitmap that looks
    /// chewed-up on a retina display, so try the good one first.
    static func ordered(_ hrefs: [URL]) -> [URL] {
        let touch = { (u: URL) in u.path.lowercased().contains("apple-touch") }
        return hrefs.filter(touch) + hrefs.filter { !touch($0) }
    }

    /// Always the site's own host — never a third party's icon service.
    static func fallback(for url: URL) -> URL? {
        guard let host = url.host, url.scheme?.hasPrefix("http") == true else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    /// Cache key: the host, with a leading "www." folded onto the apex, and anything that
    /// isn't safe in a file name replaced. Doubles as the on-disk file name.
    static func key(for url: URL) -> String? {
        guard url.scheme?.hasPrefix("http") == true,
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return String(bare.map { c in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "." || c == "-" ? c : "_"
        })
    }

    /// The letter a site is known by, for the box a favicon has not filled yet — a brand-new
    /// tab, a site that declares no icon, a page still being fetched from a host we have
    /// never been to. Arc puts the site's initial there; it never puts a spinner there, which
    /// is the whole point: a row is a place, and a place does not flicker while it loads.
    ///
    /// The name is the label under the public suffix, so `mail.google.com` is a G and not an
    /// M, and `www.bbc.co.uk` is a B and not a C. That is `TidyTabs.registrableDomain`'s
    /// question and it is asked there rather than answered twice: a tab with no icon and a
    /// group of tabs with one then agree about what the site is called, and the handful of
    /// two-part suffixes it knows (co.uk, com.au, co.jp …) is one list to fix, not two.
    ///
    /// Two hosts have no name to take a letter from:
    ///
    /// - An address literal. Every label is a number, and "the label under the suffix" would
    ///   make `127.0.0.1` a 0; its first digit is at least stable.
    /// - A punycode host. `xn--fiqs8s` is an encoding, not a word, and every one of them
    ///   would be an X — the one letter that would be wrong for all of them at once. There
    ///   is no public API to turn it back into the label a reader would recognise, so this
    ///   gives up and the globe stands in. Upgrade path: an IDN decode, and the letter falls
    ///   out of it.
    nonisolated static func letter(for url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        let name = labels.allSatisfy({ $0.allSatisfy(\.isNumber) })
            ? labels.first.map(String.init)
            : TidyTabs.registrableDomain(host).split(separator: ".").first.map(String.init)
        guard let name, !name.hasPrefix("xn--"),
              let c = name.first(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return String(c).uppercased()
    }

    // MARK: Disk

    /// ponytail: synchronous file IO on the main thread. These are sub-10KB reads on a
    /// local SSD, once per host per launch; if it ever shows up in a trace, move it behind
    /// the same Task the network fetch already uses.
    private var dir: URL {
        let d = ProfileManager.faviconDir(for: profileID, in: Store.directory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func readDisk(_ key: String) -> NSImage? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(key)),
              let img = NSImage(data: data), img.isValid else { return nil }
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    private func writeDisk(_ key: String, _ data: Data) {
        try? data.write(to: dir.appendingPathComponent(key))
        prune()
    }

    /// Oldest-first eviction once the directory gets silly. Modification date is the only
    /// access record kept, which makes this LRU-by-write rather than true LRU.
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > Favicons.maxFiles else { return }
        let byAge = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in byAge.prefix(files.count - Favicons.maxFiles / 2) { try? fm.removeItem(at: url) }
    }

    // MARK: Checks

    /// Offline assertions for the pure logic. No network, no disk.
    static func check() -> [(String, Bool)] {
        let u = { (s: String) in URL(string: s)! }
        let d = { (t: Double) in Date(timeIntervalSince1970: t) }
        return [
            ("cache key is the host", key(for: u("https://example.com/a?b=c")) == "example.com"),
            ("www folds onto the apex", key(for: u("https://WWW.Example.com/")) == "example.com"),
            ("a subdomain keeps its own key", key(for: u("https://a.example.com/")) == "a.example.com"),
            ("non-http urls have no key", key(for: u("file:///tmp/x.html")) == nil),
            ("a key can never contain a path separator",
             key(for: u("https://a.example.com/x/y"))?.contains("/") == false),
            ("fallback is the site's own /favicon.ico",
             fallback(for: u("https://www.example.com/deep/page"))?.absoluteString
                == "https://www.example.com/favicon.ico"),
            ("fallback never points at a third-party host",
             fallback(for: u("https://example.com/x"))?.host == "example.com"),
            ("apple-touch-icon is tried before a .ico",
             ordered([u("https://e.com/favicon.ico"), u("https://e.com/apple-touch-icon.png")])
                .first?.lastPathComponent == "apple-touch-icon.png"),
            ("declaration order is otherwise preserved",
             ordered([u("https://e.com/a.png"), u("https://e.com/b.png")]).last?.lastPathComponent == "b.png"),

            // The stand-in a row shows while a tab has no favicon. There is no spinner to
            // fall back to any more, so this is what a brand-new tab is recognised by.
            ("a site with no icon yet is known by its initial",
             letter(for: u("https://example.com/a")) == "E"),
            ("…the site's own, not the subdomain's",
             letter(for: u("https://mail.google.com/mail/u/0")) == "G"),
            ("…and www is not a name", letter(for: u("https://www.example.com/")) == "E"),
            ("…nor is a mobile prefix", letter(for: u("https://m.example.com/")) == "E"),
            ("a two-part suffix is a suffix: bbc.co.uk is a B, not a C",
             letter(for: u("https://www.bbc.co.uk/news")) == "B"
                && letter(for: u("https://news.bbc.co.uk/")) == "B"),
            ("…the same list the tab grouping folds hosts with, so the two agree",
             letter(for: u("https://example.com.au/")) == "E"
                && letter(for: u("https://shop.example.co.jp/")) == "E"),
            ("a punycode host is an encoding, not a word: every one of them would be an X",
             letter(for: u("https://xn--fiqs8s.example/")) == nil),
            ("…and it is the site's own label that has to be readable, not a subdomain's",
             letter(for: u("https://www.xn--fiqs8s.com/")) == nil),
            ("a bare host is its own name", letter(for: u("http://localhost:8000/")) == "L"),
            ("an address literal is not a name with an initial in the middle of it",
             letter(for: u("http://127.0.0.1:8000/")) == "1"),
            ("a digit is a letter here, since a host may start with one",
             letter(for: u("https://1password.com/")) == "1"),
            ("the letter is upper case however the host was typed",
             letter(for: u("https://EXAMPLE.com/")) == "E"),
            ("a url with no host has no letter, and gets the globe",
             letter(for: u("about:blank")) == nil && letter(for: nil) == nil),
            ("neither does a local file — Finder's own icon stands in for those",
             letter(for: u("file:///tmp/x.html")) == nil),

            // The one ordering invariant: the strip is sorted by section. `others` is the
            // strip with the moved tab already taken out. F = favourite, P = pinned,
            // T = today.
            ("a favourite stays inside the favourites run",
             TabStore.clampedDestination(others: [.favourite, .favourite, .today, .today],
                                         moving: .favourite, to: 4) == 2),
            ("a pinned tab lands between the favourites and today",
             TabStore.clampedDestination(others: [.favourite, .favourite, .today, .today],
                                         moving: .pinned, to: 0) == 2),
            ("a today tab can't jump ahead of what stays",
             TabStore.clampedDestination(others: [.favourite, .pinned, .today, .today],
                                         moving: .today, to: 0) == 2),
            ("an in-range drop is left alone",
             TabStore.clampedDestination(others: [.favourite, .pinned, .today, .today],
                                         moving: .today, to: 3) == 3),
            ("a drop past the end lands after the last tab",
             TabStore.clampedDestination(others: [.today, .today, .today, .today],
                                         moving: .today, to: 9) == 4),
            ("with nothing above it, any position is allowed",
             TabStore.clampedDestination(others: [.today, .today], moving: .today, to: 0) == 0),
            ("the first favourite of an all-today strip lands at the head",
             TabStore.clampedDestination(others: [.today, .today], moving: .favourite, to: 2) == 0),
            ("a section that does not exist yet still has exactly one legal slot",
             TabStore.clampedDestination(others: [.favourite, .today], moving: .pinned, to: 0) == 1
                && TabStore.clampedDestination(others: [.favourite, .today], moving: .pinned, to: 9) == 1),
            ("an empty strip takes anything at 0",
             TabStore.clampedDestination(others: [], moving: .pinned, to: 5) == 0),

            // The same invariant, restored after a batch rather than kept one move at a
            // time. Tidy's undo is the caller: it puts a whole strip's saved order back, and
            // a tab the user pinned by hand while the tidy was thinking is in that order
            // carrying a section the saved order never knew about.
            ("a strip already in section order is left exactly as it is",
             TabStore.sectionOrder([.favourite, .pinned, .pinned, .today]) == [0, 1, 2, 3]),
            ("a pinned tab stranded below Today is lifted above it",
             TabStore.sectionOrder([.today, .pinned, .today]) == [1, 0, 2]),
            ("every favourite ends up ahead of every pinned tab, and those ahead of Today",
             TabStore.sectionOrder([.today, .pinned, .favourite]) == [2, 1, 0]),
            ("nothing moves within a section",
             TabStore.sectionOrder([.today, .today, .pinned, .today]) == [2, 0, 1, 3]),
            ("the result is always a permutation, losing and inventing nothing",
             TabStore.sectionOrder([.today, .pinned, .favourite, .today, .pinned]).sorted()
                == [0, 1, 2, 3, 4]),
            ("an empty strip sorts to nothing", TabStore.sectionOrder([]).isEmpty),
            // The "Unpinned" toast's Undo is the other caller, and its saved order is older
            // than the tidy's: it was taken one press ago, so a tab the user pinned *while
            // the toast was up* is in it sitting among Today tabs. Put back unsettled, the
            // repinned row P1 leads and the newly pinned T2 sits below a Today tab — the
            // strip invariant broken by an undo. Settled, T2 joins the Pinned run.
            ("a tab pinned while the Unpinned toast was up joins the Pinned run",
             TabStore.sectionOrder([.pinned, .today, .pinned]) == [0, 2, 1]),

            // The favourites grid: columns from the count, Arc's way.
            ("no favourites is one placeholder column", TabStore.favouriteColumns(0) == 1),
            ("one favourite is one full-width tile", TabStore.favouriteColumns(1) == 1),
            ("two and three favourites get a column each",
             TabStore.favouriteColumns(2) == 2 && TabStore.favouriteColumns(3) == 3),
            ("four favourites are a 2×2", TabStore.favouriteColumns(4) == 2),
            ("five and six run three across",
             TabStore.favouriteColumns(5) == 3 && TabStore.favouriteColumns(6) == 3),
            ("seven or more run four across",
             TabStore.favouriteColumns(7) == 4 && TabStore.favouriteColumns(12) == 4),

            // Closing: a favourite or a pinned tab parks in place, a today tab goes.
            ("closing a favourite keeps its tile",
             TabStore.closing(0, kinds: [.favourite, .today], lastActive: [d(0), d(1)]).keep),
            ("closing a pinned tab keeps its row",
             TabStore.closing(0, kinds: [.pinned, .today], lastActive: [d(0), d(1)]).keep),
            ("closing a today tab removes it",
             !TabStore.closing(1, kinds: [.favourite, .today], lastActive: [d(0), d(1)]).keep),
            ("a closed favourite hands over to the most recently used today tab",
             TabStore.closing(0, kinds: [.favourite, .pinned, .today, .today],
                              lastActive: [d(9), d(9), d(2), d(1)]).next == 2),
            ("a closed favourite with no today tabs leaves the column bare",
             TabStore.closing(1, kinds: [.favourite, .pinned], lastActive: [d(0), d(1)]).next == nil),
            ("closing a today tab shows its neighbour",
             TabStore.closing(1, kinds: [.favourite, .today, .today], lastActive: [d(0), d(0), d(0)]).next == 1),
            ("closing the last today tab never wakes a favourite or a pin",
             TabStore.closing(2, kinds: [.favourite, .pinned, .today], lastActive: [d(0), d(0), d(0)]).next == nil),
            ("closing the only tab leaves nothing to show",
             TabStore.closing(0, kinds: [.today], lastActive: [d(0)]) == (false, nil)),

            // What stays is written down as the page it stands for, wherever it has since
            // been taken. See `Tab.homeURL`: a pinned row or a favourite remembers the url
            // it was pinned at, and that is the one that goes to disk.
            ("a favourite is saved as the page it is on",
             TabStore.pinURL(u("https://elsewhere.example/x")) == "https://elsewhere.example/x"),
            ("one on no page is not written down", TabStore.pinURL(nil) == nil),
            ("a non-http page is not written down", TabStore.pinURL(u("file:///x.html")) == nil),

            // Home: the url a favourite or a pinned row stands for.
            ("pinning a tab records the page it was pinned at",
             TabStore.home(entering: .pinned, at: u("https://google.example/")) == u("https://google.example/")),
            ("favouriting one records it the same way",
             TabStore.home(entering: .favourite, at: u("https://google.example/")) == u("https://google.example/")),
            ("a row that leaves for Today stands for nothing and forgets it",
             TabStore.home(entering: .today, at: u("https://google.example/")) == nil),
            ("a tab pinned while it is still blank has no home to be sent back to",
             TabStore.home(entering: .pinned, at: nil) == nil),

            // …and that home, not the wander, is what both writers put on disk. `savePins`
            // and `saveCurrentSpace` write the same two lists and the Space fingerprint is
            // taken off what they leave there, so they read this one expression.
            ("a pinned row browsed elsewhere is still written down as its own page",
             TabStore.pinned(home: u("https://google.example/"), at: u("https://wandered.example/x"))
                == u("https://google.example/")),
            ("…which is what the Space fingerprint is taken off, so a wander is no edit",
             TabStore.fingerprint(
                tabURLs: [], pinnedTabURLs: [TabStore.pinned(home: u("https://google.example/"),
                                                             at: u("https://wandered.example/x"))!],
                shapes: [nil, nil])
                == TabStore.fingerprint(tabURLs: [], pinnedTabURLs: [u("https://google.example/")],
                                        shapes: [nil, nil])),
            ("a row with no home is written down as the page it is on, exactly as before",
             TabStore.pinned(home: nil, at: u("https://wandered.example/x")) == u("https://wandered.example/x")),
            ("a Today tab has no home, so its url is untouched by any of this",
             TabStore.pinned(home: TabStore.home(entering: .today, at: u("https://a.example/")),
                             at: u("https://a.example/")) == u("https://a.example/")),

            // Closing a row that has wandered sends it home rather than parking it there.
            ("a pinned row browsed away from its page is sent back to it",
             TabStore.goesHome(home: u("https://google.example/"), at: u("https://wandered.example/x"))
                == u("https://google.example/")),
            ("one already on its own page has nowhere to go and parks in place",
             TabStore.goesHome(home: u("https://google.example/"), at: u("https://google.example/")) == nil),
            ("a row with no home parks in place, which is what every row used to do",
             TabStore.goesHome(home: nil, at: u("https://wandered.example/x")) == nil),
            // The resume gap: `resume` clears `parkedURL` before `WKWebView.url` catches up,
            // so for that width the tab has no url at all. Unknown is not "wandered".
            ("a row whose whereabouts are unknown is left exactly where it is",
             TabStore.goesHome(home: u("https://google.example/"), at: nil) == nil),

            // And it says where it went. The wandered page's title goes with the wander.
            ("a row sent home takes the name history knows that page by",
             TabStore.homeTitle(known: "Google", url: u("https://google.example/")) == "Google"),
            ("…the host when this profile has never been there",
             TabStore.homeTitle(known: nil, url: u("https://google.example/")) == "google.example"),
            ("…and the host again for a page whose title never arrived",
             TabStore.homeTitle(known: "", url: u("https://google.example/")) == "google.example"),
            ("favourites and pinned rows are written to different keys",
             TabStore.defaultsKey(.favourite, ProfileManager.defaultID)
                != TabStore.defaultsKey(.pinned, ProfileManager.defaultID)),
            ("the favourites key is still the one that predates the split",
             TabStore.defaultsKey(.favourite, ProfileManager.defaultID) == "pinnedTabs"),

            // Drop index math: where a dragged tab lands before or after its target.
            ("dropping before a later target lands one short of it",
             TabStore.insertionIndex(from: 0, target: 3, after: false) == 2),
            ("dropping after a later target lands on it",
             TabStore.insertionIndex(from: 0, target: 3, after: true) == 3),
            ("dropping before an earlier target lands on it",
             TabStore.insertionIndex(from: 3, target: 0, after: false) == 0),
            ("dropping after an earlier target lands one past it",
             TabStore.insertionIndex(from: 3, target: 0, after: true) == 1),
            ("a today row dropped after the last tile joins the favourites at the end",
             TabStore.clampedDestination(others: [.favourite, .favourite, .today, .today],
                                         moving: .favourite,
                                         to: TabStore.insertionIndex(from: 4, target: 1, after: true)) == 2),
            ("a tile dropped above the first today row joins today at its head",
             TabStore.clampedDestination(others: [.favourite, .today, .today, .today],
                                         moving: .today,
                                         to: TabStore.insertionIndex(from: 0, target: 2, after: false)) == 1),
            ("a today row dropped onto a pinned row joins the pinned run",
             TabStore.clampedDestination(others: [.favourite, .pinned, .today],
                                         moving: .pinned,
                                         to: TabStore.insertionIndex(from: 3, target: 1, after: true)) == 2),
        ]
    }
}
