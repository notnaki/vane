import AppKit
import WebKit

/// Favicons, fetched from the site itself and cached by host.
///
/// ponytail: no favicon proxy service. Those are one HTTP request per site you visit sent
/// to a third party — that is a browsing-history feed, and it is not worth a rounder icon.
/// Ceiling: no ETag/Cache-Control handling, so an icon only changes when the LRU sweep
/// evicts it; the upgrade path is writing the response headers next to the bytes.
@MainActor final class Favicons: ObservableObject {
    static let shared = Favicons()

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
    private static var dir: URL {
        let d = Store.directory.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func readDisk(_ key: String) -> NSImage? {
        guard let data = try? Data(contentsOf: Favicons.dir.appendingPathComponent(key)),
              let img = NSImage(data: data), img.isValid else { return nil }
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    private func writeDisk(_ key: String, _ data: Data) {
        try? data.write(to: Favicons.dir.appendingPathComponent(key))
        prune()
    }

    /// Oldest-first eviction once the directory gets silly. Modification date is the only
    /// access record kept, which makes this LRU-by-write rather than true LRU.
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Favicons.dir,
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

            ("pinned tab stays inside the pinned run",
             TabStore.clampedDestination(count: 5, pinnedCount: 2, movingPinned: true, to: 4) == 1),
            ("unpinned tab can't jump ahead of pinned tabs",
             TabStore.clampedDestination(count: 5, pinnedCount: 2, movingPinned: false, to: 0) == 2),
            ("an in-range drop is left alone",
             TabStore.clampedDestination(count: 5, pinnedCount: 2, movingPinned: false, to: 3) == 3),
            ("a drop past the end lands on the last index",
             TabStore.clampedDestination(count: 5, pinnedCount: 0, movingPinned: false, to: 9) == 4),
            ("with nothing pinned, any position is allowed",
             TabStore.clampedDestination(count: 5, pinnedCount: 0, movingPinned: false, to: 0) == 0),
            ("the only pinned tab can only land at 0",
             TabStore.clampedDestination(count: 3, pinnedCount: 1, movingPinned: true, to: 2) == 0),
        ]
    }
}
