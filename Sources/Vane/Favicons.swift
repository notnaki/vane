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

            // What stays is written down as its current page, wherever it has gone.
            ("a favourite is saved as its current page",
             TabStore.pinURL(u("https://elsewhere.example/x")) == "https://elsewhere.example/x"),
            ("one on no page is not written down", TabStore.pinURL(nil) == nil),
            ("a non-http page is not written down", TabStore.pinURL(u("file:///x.html")) == nil),
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
