import SwiftUI
import WebKit

/// One open page. The web view is made on first show, so restored tabs cost nothing until opened.
@MainActor @Observable final class Tab: Identifiable {
    struct Saved: Codable { var id: UUID; var spaceID: UUID; var url: URL; var title: String; var home: URL?; var active: Date? }
    let id: UUID
    var spaceID: UUID
    /// The favourite or pinned link this tab was opened from, so tapping it again returns here.
    var home: URL?
    var url: URL
    var title: String
    /// Last time it was on screen: picks the previous tab, and archives it once it's been idle long enough.
    var active: Date
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    /// The bar shrinks while the page scrolls down, and returns when it scrolls back up.
    var collapsed = false {
        // The page's foot changes as the page resizes under the bar; read it again once it settles.
        didSet { if oldValue != collapsed { sampleSoon() } }
    }
    /// How the page last looked, for its card in the Space. Memory only.
    var snapshot: UIImage?
    /// Reader is on: the article shown in place of the page.
    var reading: Article?
    /// Pulling down past the top of the page, Chrome-style: how far (0…1, armed at 1) and which
    /// action the finger is over: new tab on the left, reload in the middle, close on the right.
    struct Pull: Equatable { var progress: CGFloat; var choice: PullChoice; var dx: CGFloat; var depth: CGFloat = 100 }
    enum PullChoice: Int { case newTab = -1, reload = 0, close = 1 }
    var pull: Pull?
    var onPull: (PullChoice) -> Void = { _ in }
    private var pullTracker: PullTracker?
    /// Where the finger was, on screen, when the page first passed its top: sideways movement
    /// counts from here, not from wherever the scroll began.
    private var pullStart: (finger: CGFloat, travel: CGFloat)?
    /// The colours actually drawn along the page's top and bottom edges, so the pull strip and
    /// the strip under the bar continue the page exactly.
    /// Also paints the overscroll and the status-bar area, so the top reads as one surface with the page's top element.
    var pageColor: UIColor? { didSet { if let pageColor { view?.underPageBackgroundColor = pageColor } } }
    var footColor: UIColor?
    private var lastOffset: CGFloat = 0
    private var view: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    var onChange: () -> Void = {}
    /// A page finished loading: the moment its URL and title are both settled.
    var onLoaded: () -> Void = {}
    /// The last URL reported as a visit, so reloads and subresource loads don't repeat it.
    var visited: URL?

    /// Incognito tabs keep nothing: no history, not saved or synced, and their cookies and
    /// website data live in memory until the last one closes.
    var isPrivate: Bool { spaceID == SpaceRow.incognito.id }

    init(_ saved: Saved) { id = saved.id; spaceID = saved.spaceID; url = saved.url; title = saved.title; home = saved.home; active = saved.active ?? .now }
    var saved: Saved { Saved(id: id, spaceID: spaceID, url: url, title: title, home: home, active: active) }

    var webView: WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // As in Safari: muted videos may start themselves (a site's looping demo); ones with sound wait for a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        if isPrivate { configuration.websiteDataStore = Browser.privateStore }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.allowsBackForwardNavigationGestures = true
        web.isFindInteractionEnabled = true
        web.allowsLinkPreview = true
        web.uiDelegate = PopupOpener.shared
        // Pull down at the top of a page for new tab / reload / close, as in Chrome.
        web.scrollView.alwaysBounceVertical = true
        let tracker = PullTracker { [weak self] pan in self?.pulled(pan) }
        web.scrollView.panGestureRecognizer.addTarget(tracker, action: #selector(PullTracker.fire(_:)))
        pullTracker = tracker
        observations = [
            web.observe(\.title) { [weak self] web, _ in MainActor.assumeIsolated { if let t = web.title, !t.isEmpty { self?.title = t; self?.onChange() } } },
            web.observe(\.url) { [weak self] web, _ in MainActor.assumeIsolated {
                // Going to another page leaves Reader.
                if let u = web.url { if u != self?.url { self?.reading = nil }; self?.url = u; self?.onChange() }
            } },
            web.observe(\.estimatedProgress) { [weak self] web, _ in MainActor.assumeIsolated { self?.progress = web.estimatedProgress } },
            web.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoBack = web.canGoBack } },
            web.observe(\.canGoForward) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoForward = web.canGoForward } },
            web.scrollView.observe(\.contentOffset) { [weak self] scroll, _ in MainActor.assumeIsolated { self?.scrolled(scroll) } },
            web.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { if !web.isLoading { self?.onLoaded(); self?.sampleEdges(); self?.sampleSoon(after: 1.2) } } },
        ]
        web.load(URLRequest(url: url))
        view = web
        return web
    }

    private func pulled(_ pan: UIPanGestureRecognizer) {
        guard let scroll = pan.view as? UIScrollView else { return }
        let depth = -(scroll.contentOffset.y + scroll.adjustedContentInset.top)
        switch pan.state {
        case .began, .changed:
            if pan.state == .began { sampleEdges() }
            guard depth > 0, reading == nil else { if pull != nil { pull = nil }; pullStart = nil; return }
            // A finger moves the touch point; a trackpad or mouse wheel (the Simulator, iPad)
            // moves only the pan's travel. Count whichever went further sideways.
            let finger = pan.location(in: nil).x, travel = pan.translation(in: nil).x
            let start = pullStart ?? (finger, travel)
            pullStart = start
            let moved = (finger - start.finger, travel - start.travel)
            let dx = abs(moved.0) >= abs(moved.1) ? moved.0 : moved.1
            let next = Pull(progress: min(depth / 100, 1), choice: dx < -24 ? .newTab : dx > 24 ? .close : .reload, dx: dx, depth: depth)
            if next.progress >= 1, pull.map({ $0.progress < 1 || $0.choice != next.choice }) ?? true {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            pull = next
        default:
            pullStart = nil
            if let pull, pull.progress >= 1 {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onPull(pull.choice)
            }
            pull = nil
        }
    }

    /// Reads the edges again shortly, once whatever's moving has settled; repeated calls coalesce.
    private var sampleTask: Task<Void, Never>?
    func sampleSoon(after delay: Double = 0.4) {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.sampleEdges()
        }
    }

    private func scrolled(_ scroll: UIScrollView) {
        let y = scroll.contentOffset.y + scroll.adjustedContentInset.top
        defer { lastOffset = y }
        // Pages change colour as they scroll (headers, banners): keep the strips matching.
        sampleSoon(after: 0.25)
        guard scroll.isTracking || scroll.isDecelerating else { return }
        let atEnd = y + scroll.bounds.height >= scroll.contentSize.height + scroll.adjustedContentInset.bottom - 4
        let next = y < 40 || atEnd ? false : y - lastOffset > 6 ? true : y - lastOffset < -6 ? false : collapsed
        if next != collapsed { withAnimation(.smooth(duration: 0.3)) { collapsed = next } }
    }

    /// The page's article as plain text blocks, or nil when there isn't one. The script runs
    /// in its own content world, so the page's scripts can't tamper with it, and only text
    /// comes back: the reader view renders it natively, never as the page's markup.
    /// Reads the colour of the page's top and bottom rows of pixels.
    func sampleEdges() {
        guard let view, view.bounds.height > 4 else { return }
        let top = view.safeAreaInsets.top
        for (y, foot) in [(top, false), (view.bounds.height - 2, true)] {
            let config = WKSnapshotConfiguration()
            // A 2-point strip a little inside the edge, at full size (a scaled-down strip this thin comes back empty).
            config.rect = CGRect(x: 0, y: foot ? y - 2 : y + 2, width: view.bounds.width, height: 2)
            view.takeSnapshot(with: config) { [weak self] image, _ in
                MainActor.assumeIsolated {
                    guard let color = image.flatMap(Self.average) else { return }
                    if foot { self?.footColor = color } else { self?.pageColor = color }
                }
            }
        }
    }

    /// The page's background along a strip: the commonest colour across it, so text and
    /// pictures in the row don't tint the result (an average would turn white-with-text grey).
    nonisolated static func average(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let width = 24
        var pixels = [UInt8](repeating: 0, count: width * 4)
        guard let context = CGContext(data: &pixels, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: 1))
        var counts: [UInt32: Int] = [:]
        for x in 0..<width {
            let key = UInt32(pixels[x * 4]) << 16 | UInt32(pixels[x * 4 + 1]) << 8 | UInt32(pixels[x * 4 + 2])
            counts[key, default: 0] += 1
        }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return UIColor(red: CGFloat(key >> 16 & 0xFF) / 255, green: CGFloat(key >> 8 & 0xFF) / 255, blue: CGFloat(key & 0xFF) / 255, alpha: 1)
    }

    /// Keeps a picture of the page for its card; called as the tab goes out of view.
    func takeSnapshot() {
        guard let view, view.window != nil else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 360
        view.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated { if let image { self?.snapshot = image } }
        }
    }

    func article() async -> Article? {
        guard let view else { return nil }
        let result = try? await view.callAsyncJavaScript(Article.script, contentWorld: .world(name: "vane-reader"))
        guard let object = result as? [String: Any], let title = object["title"] as? String,
              let raw = object["blocks"] as? [[String: Any]] else { return nil }
        let blocks = raw.prefix(5000).compactMap { block -> Article.Block? in
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return Article.Block(heading: block["heading"] as? Bool == true, text: String(text.prefix(20000)))
        }
        // ponytail: "enough text" is a 600-character floor; tune if short articles are refused.
        guard blocks.filter({ !$0.heading }).reduce(0, { $0 + $1.text.count }) >= 600 else { return nil }
        return Article(title: title, site: url.host() ?? "", blocks: blocks)
    }
}

struct Article: Hashable, Identifiable {
    var id: Self { self }
    struct Block: Hashable { var heading: Bool; var text: String }
    var title: String, site: String, blocks: [Block]
    /// Picks the element whose paragraphs hold the most text, then reads its headings and
    /// paragraphs in order. ponytail: a cut-down Readability; port the Mac's Reader scoring
    /// if real articles come out wrong.
    static let script = """
    const candidates = new Map();
    for (const p of document.querySelectorAll('p')) {
      const parent = p.parentElement; if (!parent) continue;
      candidates.set(parent, (candidates.get(parent) || 0) + p.innerText.trim().length);
    }
    let best = null, score = 0;
    for (const [node, length] of candidates) if (length > score) { best = node; score = length; }
    if (!best) return null;
    const blocks = [];
    for (const node of best.querySelectorAll('h1,h2,h3,h4,p,li,blockquote,pre')) {
      if (node.closest('nav,aside,footer,form,figure figcaption,#toc,.toc,.vector-toc,[role=navigation],.navbox,.reflist,.mw-editsection')) continue;
      if (node.tagName === 'LI' && node.querySelector('li')) continue;
      const text = node.innerText.trim();
      if (text) blocks.push({ heading: /^H/.test(node.tagName), text });
    }
    const heading = document.querySelector('h1');
    return { title: (heading && heading.innerText.trim()) || document.title, blocks };
    """
}

/// Forwards the scroll view's pan to the tab, which isn't an NSObject.
final class PullTracker: NSObject {
    let handler: (UIPanGestureRecognizer) -> Void
    init(_ handler: @escaping (UIPanGestureRecognizer) -> Void) { self.handler = handler }
    @MainActor @objc func fire(_ pan: UIPanGestureRecognizer) { handler(pan) }
}

/// Links that ask for a new window (target=_blank, window.open) open in the same tab, and a
/// long-pressed link offers a new tab.
final class PopupOpener: NSObject, WKUIDelegate {
    @MainActor static let shared = PopupOpener()
    /// Opens a URL in a new tab; set by the browser.
    @MainActor var openInNewTab: (URL) -> Void = { _ in }
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
            UIMenu(children: [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    MainActor.assumeIsolated { PopupOpener.shared.openInNewTab(url) }
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = url },
            ] + suggested)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

struct Visit: Codable, Hashable { var url: URL; var title: String; var at: Date }
/// A tab put away after sitting unopened, as Arc Search does; reopened from the tab switcher's archive.
struct Archived: Codable, Hashable, Identifiable { var id: UUID; var spaceID: UUID; var url: URL; var title: String; var at: Date }

@MainActor @Observable final class Browser {
    private(set) var tabs: [Tab] = []
    var selectedID: UUID?
    var spaceID: UUID { didSet { UserDefaults.standard.set(spaceID.uuidString, forKey: "space") } }
    private(set) var history: [Visit] = []
    private(set) var archived: [Archived] = []
    /// Seconds a tab can sit unopened before it's archived; 0 keeps tabs open.
    var archiveAfter: Double { didSet { UserDefaults.standard.set(archiveAfter, forKey: "archiveAfter"); archiveIdle() } }
    var engine: SearchEngine { didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") } }
    enum Editing { case current, newTab }
    /// The address field is open: for the page on screen, or for a new tab.
    var editing: Editing?
    /// What's typed in the address field while editing.
    var query = ""
    /// When a link from another app last arrived, so search doesn't open over it.
    var externalOpen: Date?
    /// The Space to go back to when Incognito is switched off.
    private(set) var beforeIncognito: UUID?
    var onTabsChanged: () -> Void = {}
    var onVisit: (Tab) -> Void = { _ in }
    /// History from other devices, when history sync is on.
    var syncedHistory: () -> [Visit] = { [] }
    var allHistory: [Visit] { (history + syncedHistory()).sorted { $0.at > $1.at } }
    /// One in-memory store shared by Incognito tabs (so a sign-in carries across them),
    /// replaced with a fresh one when the last Incognito tab closes.
    static var privateStore = WKWebsiteDataStore.nonPersistent()
    private let tabsFile = Store.directory.appending(path: "tabs.json")
    private let historyFile = Store.directory.appending(path: "history.json")
    private let archiveFile = Store.directory.appending(path: "archive.json")

    init() {
        // Incognito never outlives the app, so a relaunch starts back in a Space.
        let space = UserDefaults.standard.string(forKey: "space").flatMap(UUID.init(uuidString:))
        spaceID = space == SpaceRow.incognito.id ? Local.space : space ?? Local.space
        engine = UserDefaults.standard.string(forKey: "engine").flatMap(SearchEngine.init(rawValue:)) ?? .google
        archiveAfter = UserDefaults.standard.object(forKey: "archiveAfter") as? Double ?? 86_400
        if let data = try? Data(contentsOf: tabsFile), let saved = try? JSONDecoder().decode([Tab.Saved].self, from: data) {
            tabs = saved.map(Tab.init).filter { !$0.isPrivate }; tabs.forEach(watch)
        }
        if let data = try? Data(contentsOf: historyFile) { history = (try? JSONDecoder().decode([Visit].self, from: data)) ?? [] }
        if let data = try? Data(contentsOf: archiveFile) { archived = (try? JSONDecoder().decode([Archived].self, from: data)) ?? [] }
        PopupOpener.shared.openInNewTab = { [weak self] url in self?.open(url) }
        selectedID = UserDefaults.standard.string(forKey: "tab").flatMap(UUID.init(uuidString:))
        if selected?.spaceID != spaceID { selectedID = nil }
        archiveIdle()
    }

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == spaceID } }
    /// The tab you were on before this one, in this Space: a flick up on the bar's tab stack swaps to it.
    var previous: Tab? { spaceTabs.filter { $0.id != selectedID }.max { $0.active < $1.active } }

    func select(_ tab: Tab?) {
        if tab?.id != selectedID { selected?.takeSnapshot(); selected?.active = .now }
        tab?.active = .now
        selectedID = tab?.id
        UserDefaults.standard.set(tab?.id.uuidString, forKey: "tab")
        // Keeps the last-seen times on disk, so a tab just looked at isn't archived after a relaunch.
        save()
    }

    /// Favourites and pinned links return to the tab they opened, like on the Mac.
    func open(_ url: URL, home: URL? = nil, newTab: Bool = true) {
        // Whatever opens a page (a link from another app, a favourite) closes the search sheet over it.
        editing = nil
        if let home, let existing = spaceTabs.first(where: { $0.home == home }) { return select(existing) }
        if !newTab, let tab = selected {
            tab.webView.load(URLRequest(url: url))
            return
        }
        let tab = Tab(.init(id: UUID(), spaceID: spaceID, url: url, title: url.host() ?? url.absoluteString, home: home))
        watch(tab)
        tabs.append(tab)
        select(tab)
        save()
    }
    func close(_ tab: Tab) {
        tabs.removeAll { $0.id == tab.id }
        forgetPrivateData()
        if selectedID == tab.id { select(spaceTabs.last) }
        save()
    }
    func closeTabs(in space: UUID) {
        tabs.removeAll { $0.spaceID == space }
        forgetPrivateData()
        archived.removeAll { $0.spaceID == space }; saveArchive()
        if selected == nil { select(nil) }
        save()
    }
    /// On the Spaces home you stay on the home; on a page you land on that Space's last tab.
    func switchSpace(_ id: UUID) {
        let home = selectedID == nil
        if id == SpaceRow.incognito.id, spaceID != id { beforeIncognito = spaceID }
        spaceID = id
        select(home ? nil : spaceTabs.last)
    }

    /// Opens what was picked or typed in the address field, then closes it.
    func go(_ url: URL?) {
        guard let url else { return }
        open(url, newTab: editing == .newTab || selected == nil)
        editing = nil
    }

    /// Text from the address field: a URL if it looks like one, otherwise a search.
    func destination(for text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil { return url }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host()?.contains(".") == true { return url }
        return engine.url(for: text)
    }
    func suggestions(for text: String) -> [Visit] {
        guard !text.isEmpty else { return [] }
        var seen = Set<URL>()
        return allHistory.filter { ($0.url.absoluteString.localizedCaseInsensitiveContains(text) || $0.title.localizedCaseInsensitiveContains(text)) && seen.insert($0.url).inserted }.prefix(8).map { $0 }
    }

    /// Archives tabs left unopened longer than `archiveAfter`. Tabs opened from a pinned tab or
    /// favourite stay, as on the Mac, and so does the one on screen.
    func archiveIdle() {
        guard archiveAfter > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-archiveAfter)
        let idle = tabs.filter { !$0.isPrivate && $0.home == nil && $0.id != selectedID && $0.active < cutoff }
        guard !idle.isEmpty else { return }
        archived.insert(contentsOf: idle.reversed().map { Archived(id: $0.id, spaceID: $0.spaceID, url: $0.url, title: $0.title, at: .now) }, at: 0)
        // ponytail: newest 500 kept; plenty for a phone's archive.
        archived = Array(archived.prefix(500))
        tabs.removeAll { tab in idle.contains { $0.id == tab.id } }
        save(); saveArchive()
    }
    func unarchive(_ item: Archived) {
        archived.removeAll { $0.id == item.id }; saveArchive()
        open(item.url)
    }
    func clearArchive() { archived = []; saveArchive() }

    func clearHistory() {
        history = []; saveHistory(); clearArchive()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// The last Incognito tab closed: drop its cookies and website data with the store.
    private func forgetPrivateData() {
        guard !tabs.contains(where: \.isPrivate) else { return }
        Browser.privateStore = .nonPersistent()
    }

    private func watch(_ tab: Tab) {
        tab.onPull = { [weak self, weak tab] choice in
            guard let self, let tab else { return }
            switch choice {
            case .newTab: self.editing = .newTab
            case .reload: tab.webView.reload()
            case .close: withAnimation(.smooth(duration: 0.3)) { self.close(tab) }
            }
        }
        tab.onLoaded = { [weak self, weak tab] in
            guard let self, let tab, !tab.isPrivate, ["http", "https"].contains(tab.url.scheme ?? ""), tab.visited != tab.url else { return }
            tab.visited = tab.url
            self.onVisit(tab)
        }
        tab.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard !tab.isPrivate else { return }
            if ["http", "https"].contains(tab.url.scheme ?? ""), self.history.first?.url != tab.url || self.history.first?.title != tab.title {
                if self.history.first?.url == tab.url { self.history.removeFirst() }
                self.history.insert(Visit(url: tab.url, title: tab.title, at: .now), at: 0)
                // ponytail: capped flat list; move to SQLite if history search gets slow.
                if self.history.count > 5000 { self.history.removeLast(self.history.count - 5000) }
                self.saveHistory()
            }
            self.save()
        }
    }
    private func save() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(tabs.filter { !$0.isPrivate }.map(\.saved)).write(to: tabsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        onTabsChanged()
    }
    private func saveArchive() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(archived).write(to: archiveFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func saveHistory() {
        try? JSONEncoder().encode(history).write(to: historyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia
    var id: String { rawValue }
    var name: String { ["google": "Google", "duckduckgo": "DuckDuckGo", "bing": "Bing", "ecosia": "Ecosia"][rawValue]! }
    func url(for query: String) -> URL? {
        let base = ["google": "https://www.google.com/search", "duckduckgo": "https://duckduckgo.com/",
                    "bing": "https://www.bing.com/search", "ecosia": "https://www.ecosia.org/search"][rawValue]!
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

/// Hosts the selected tab's web view; swapping tabs swaps the child view.
struct WebContainer: UIViewRepresentable {
    let tab: Tab
    /// Room the page scrolls its last line clear of, above the home-indicator strip: the bar's.
    var bottom: CGFloat = 0
    final class Host: UIView {
        /// Stands where the bar is, so UIKit draws the scroll view's soft edge (a blur that
        /// deepens toward the bottom) under it, as under system bars.
        let edge = UIView()
    }
    func makeUIView(context: Context) -> Host {
        let host = Host()
        host.edge.isUserInteractionEnabled = false
        host.edge.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        host.addSubview(host.edge)
        return host
    }
    func updateUIView(_ host: Host, context: Context) {
        let web = tab.webView
        if web.superview !== host {
            host.subviews.filter { $0 !== host.edge }.forEach { $0.removeFromSuperview() }
            web.frame = host.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.insertSubview(web, belowSubview: host.edge)
            host.edge.interactions.forEach { host.edge.removeInteraction($0) }
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.scrollView = web.scrollView
            interaction.edge = .bottom
            host.edge.addInteraction(interaction)
            web.scrollView.bottomEdgeEffect.style = .soft
        }
        if web.scrollView.contentInset.bottom != bottom {
            UIView.animate(withDuration: 0.3) {
                web.scrollView.contentInset.bottom = bottom
                web.scrollView.verticalScrollIndicatorInsets.bottom = bottom
            }
        }
        let height = bottom
        host.edge.frame = CGRect(x: 0, y: host.bounds.height - height, width: host.bounds.width, height: height)
    }
}
