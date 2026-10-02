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
    private struct Pending {
        var urls: [URL] = []
        var seen: Set<URL> = []
        var persistentURLs: Set<URL> = []
        var fallbackURLs: Set<URL> = []

        mutating func append(_ candidates: [URL], persist: Bool, fallback: URL?) {
            for url in candidates where seen.insert(url).inserted { urls.append(url) }
            if persist { persistentURLs.formUnion(candidates) }
            if let fallback { fallbackURLs.insert(fallback) }
        }
    }
    private var pending: [String: Pending] = [:]
    /// Parked tabs have no didFinish callback to pick up an icon discovered later by
    /// another tab. Weak references let every row for that host receive the result.
    private let tabs = NSHashTable<Tab>.weakObjects()
    /// Hosts that had nothing to give, and when they said so. A 404 isn't re-requested on
    /// every page load — but a timeout during a busy restore is not a verdict for the whole
    /// session either, and it left a real icon showing as a letter until relaunch. After
    /// `missFor` the host is asked again.
    private var misses: [String: Date] = [:]
    private static let missFor: TimeInterval = 600
    private func missed(_ key: String, at date: Date = .now) -> Bool {
        misses[key].map { date.timeIntervalSince($0) < Self.missFor } ?? false
    }

    private func recordMiss(_ key: String, attemptedFallback: Bool, at date: Date = .now) {
        guard attemptedFallback else { return }
        misses[key] = date
    }

    private static let maxBytes = 512_000     // an icon that big is a mistake, not an icon
    private static let maxFiles = 300

    // MARK: Public

    /// Cached icon if there is one, otherwise nil and a fetch starts; `generation` bumps
    /// when it lands.
    func icon(for url: URL) -> NSImage? {
        guard let key = Favicons.key(for: url) else { return nil }
        if let img = memory[key] { return img }
        if let img = readDisk(key) { memory[key] = img; return img }
        guard !missed(key), let fallback = Favicons.fallback(for: url) else { return nil }
        warm(key: key, urls: [fallback], persist: profileID != Profile.incognito.id, fallback: fallback)
        return nil
    }

    /// Call on didFinish or restoration. Loaded pages supply their declarations; parked
    /// tabs use the cache and root fallback without starting a WebContent process.
    func load(for tab: Tab) {
        tabs.add(tab)
        if let url = tab.currentURL, url.isFileURL { tab.favicon = Files.icon(for: url); return }
        guard let url = tab.currentURL, let key = Favicons.key(for: url) else { tab.favicon = nil; return }
        if let img = memory[key] { tab.favicon = img; return }
        // Keep disk reads and decoding off the main actor, including during restoration.
        let file = profileID == Profile.incognito.id ? nil : dir.appendingPathComponent(key)
        let web = tab.web
        Task { @MainActor [weak self, weak tab, weak web] in
            let diskImage = if let file { await Favicons.decoded(file) } else { nil as NSImage? }
            guard let self, let tab, let web, tab.web === web, tab.currentURL == url else { return }
            if let img = self.memory[key] ?? diskImage {
                self.memory[key] = img
                tab.favicon = img
                return
            }
            if tab.suspended {
                tab.favicon = nil
                if !self.missed(key), let fallback = Favicons.fallback(for: url) {
                    self.warm(key: key, urls: [fallback], persist: !tab.isPrivate, fallback: fallback)
                }
                return
            }
            // A failed root probe says nothing about the icons declared by this page.
            let declared = ((try? await web.evaluateJavaScript(Favicons.linkJS)) as? String ?? "")
                .split(separator: "\n").compactMap { URL(string: String($0)) }
            guard tab.web === web, tab.currentURL == url else { return }
            var candidates = Favicons.ordered(declared)
            let fallback = self.missed(key) ? nil : Favicons.fallback(for: url)
            if let fallback { candidates.append(fallback) }
            guard !candidates.isEmpty else { tab.favicon = self.memory[key]; return }
            await self.warm(key: key, urls: candidates, persist: !tab.isPrivate, fallback: fallback).value
            guard tab.web === web, tab.currentURL == url else { return }
            tab.favicon = self.memory[key]
        }
    }

    // MARK: Fetch

    /// One fetch per host at a time; a second tab on the same host awaits the same task.
    @discardableResult
    private func warm(key: String, urls: [URL], persist: Bool, fallback: URL?) -> Task<Void, Never> {
        var request = pending[key] ?? Pending()
        request.append(urls, persist: persist, fallback: fallback)
        pending[key] = request
        if let running = inflight[key] { return running }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inflight[key] = nil; self.pending[key] = nil }
            var attemptedFallback = false
            // A page may finish while a cache-only /favicon.ico probe is awaiting its
            // response. Keep its declarations in the same queue instead of losing them.
            while let url = self.pending[key]?.urls.first {
                self.pending[key]?.urls.removeFirst()
                let data = await Favicons.fetch(url)
                if self.pending[key]?.fallbackURLs.contains(url) == true { attemptedFallback = true }
                guard let data, let img = Favicons.image(from: data)
                else { continue }
                self.memory[key] = img
                self.misses.removeValue(forKey: key)
                // A public fallback does not authorize storing another tab's private-only
                // declaration. Eligibility follows the successful URL, not the batch.
                if self.pending[key]?.persistentURLs.contains(url) == true { self.writeDisk(key, data) }
                for tab in self.tabs.allObjects where tab.currentURL.flatMap(Favicons.key) == key {
                    tab.favicon = img
                }
                self.generation += 1
                return
            }
            self.recordMiss(key, attemptedFallback: attemptedFallback)
        }
        inflight[key] = task
        return task
    }

    private static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        // An icon is small and already compressed, so asking for it uncompressed costs
        // nothing — and it sidesteps a class of misconfigured server that answers a
        // gzip-accepting request for /favicon.ico with its cached, gzipped index page.
        // Seen on a school portal: the same url gave curl the icon and URLSession the html,
        // and the html decoded to no image, so the host was filed as a miss.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
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
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
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

    /// A dark mark on transparency (such as GitHub's favicon) is an alpha mask, so let
    /// AppKit/SwiftUI draw it with the surrounding ink in both light and dark chrome.
    /// Colored artwork, light details, and opaque tiles keep their original pixels.
    /// Applied on decode so old disk entries benefit without changing the cached bytes.
    nonisolated static func image(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        image.isTemplate = isDarkMark(image)
        // Pin the point size regardless of the site's bitmap resolution.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private nonisolated static func isDarkMark(_ image: NSImage) -> Bool {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(source, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var visible = 0
        var transparent = 0
        for pixel in 0..<(32 * 32) {
            let offset = pixel * 4
            let alpha = Double(bytes[offset + 3])
            if alpha < 16 { transparent += 1; continue }
            visible += 1
            let red = Double(bytes[offset])
            let green = Double(bytes[offset + 1])
            let blue = Double(bytes[offset + 2])
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            // Components are premultiplied: compare against alpha, not 255, so a
            // translucent colored logo is never mistaken for a dark gray mark.
            guard high <= alpha * 0.35, high - low <= alpha * 0.08 else { return false }
        }
        return visible >= 32 && transparent >= 32
    }

    /// ponytail: synchronous file IO on the main thread. These are sub-10KB reads on a
    /// local SSD, once per host per launch; if it ever shows up in a trace, move it behind
    /// the same Task the network fetch already uses.
    private var dir: URL {
        let d = ProfileManager.faviconDir(for: profileID, in: Store.directory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func readDisk(_ key: String) -> NSImage? {
        guard profileID != Profile.incognito.id else { return nil }
        return Favicons.read(dir.appendingPathComponent(key)).image
    }

    /// Freshly made here and handed over untouched, which is the whole of what the box
    /// asserts: nothing else has a reference to it on either side.
    private struct Icon: @unchecked Sendable { let image: NSImage? }

    private nonisolated static func read(_ file: URL) -> Icon {
        guard let data = try? Data(contentsOf: file),
              let img = image(from: data) else { return Icon(image: nil) }
        return Icon(image: img)
    }

    /// The same read, off the main actor. The caller publishes the result — nothing here
    /// touches the cache, because the cache belongs to the actor this has just left.
    private nonisolated static func decoded(_ file: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { read(file) }.value.image
    }

    private func writeDisk(_ key: String, _ data: Data) {
        guard profileID != Profile.incognito.id else { return }
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
        let retry = Favicons()
        retry.recordMiss("retry-fixture", attemptedFallback: true, at: d(100))
        retry.recordMiss("retry-fixture", attemptedFallback: false, at: d(500))
        let declarationKeepsDeadline = !retry.missed("retry-fixture", at: d(710))
        retry.recordMiss("retry-fixture", attemptedFallback: true, at: d(750))
        let fallbackRestartsDeadline = retry.missed("retry-fixture", at: d(800))
        return [
            ("a failed declaration does not extend the fallback retry delay", declarationKeepsDeadline),
            ("a newly attempted fallback starts its own retry delay", fallbackRestartsDeadline),
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
            ("fallback preserves HTTP and a custom port",
             fallback(for: u("http://127.0.0.1:8123/page?q=x#part"))?.absoluteString
                == "http://127.0.0.1:8123/favicon.ico"),
            ("fallback preserves HTTPS and a custom port",
             fallback(for: u("https://example.com:8443/page"))?.absoluteString
                == "https://example.com:8443/favicon.ico"),
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
