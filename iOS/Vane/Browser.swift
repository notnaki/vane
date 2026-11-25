import SwiftUI
import WebKit

/// One open page. The web view is made on first show, so restored tabs cost nothing until opened.
@MainActor @Observable final class Tab: Identifiable {
    struct Saved: Codable { var id: UUID; var spaceID: UUID; var url: URL; var title: String; var home: URL? }
    let id: UUID
    var spaceID: UUID
    /// The favourite or pinned link this tab was opened from, so tapping it again returns here.
    var home: URL?
    var url: URL
    var title: String
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    /// The bar shrinks while the page scrolls down, and returns when it scrolls back up.
    var collapsed = false
    /// How the page last looked, for its card in the Space. Memory only.
    var snapshot: UIImage?
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

    init(_ saved: Saved) { id = saved.id; spaceID = saved.spaceID; url = saved.url; title = saved.title; home = saved.home }
    var saved: Saved { Saved(id: id, spaceID: spaceID, url: url, title: title, home: home) }

    var webView: WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        if isPrivate { configuration.websiteDataStore = Browser.privateStore }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.allowsBackForwardNavigationGestures = true
        web.isFindInteractionEnabled = true
        web.allowsLinkPreview = true
        web.uiDelegate = PopupOpener.shared
        observations = [
            web.observe(\.title) { [weak self] web, _ in MainActor.assumeIsolated { if let t = web.title, !t.isEmpty { self?.title = t; self?.onChange() } } },
            web.observe(\.url) { [weak self] web, _ in MainActor.assumeIsolated { if let u = web.url { self?.url = u; self?.onChange() } } },
            web.observe(\.estimatedProgress) { [weak self] web, _ in MainActor.assumeIsolated { self?.progress = web.estimatedProgress } },
            web.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoBack = web.canGoBack } },
            web.observe(\.canGoForward) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoForward = web.canGoForward } },
            web.scrollView.observe(\.contentOffset) { [weak self] scroll, _ in MainActor.assumeIsolated { self?.scrolled(scroll) } },
            web.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { if !web.isLoading { self?.onLoaded() } } },
        ]
        // The floating bar covers the page's foot; let its last line scroll clear of it.
        web.scrollView.contentInset.bottom = Look.barHeight
        web.scrollView.verticalScrollIndicatorInsets.bottom = Look.barHeight
        web.load(URLRequest(url: url))
        view = web
        return web
    }

    private func scrolled(_ scroll: UIScrollView) {
        let y = scroll.contentOffset.y + scroll.adjustedContentInset.top
        defer { lastOffset = y }
        guard scroll.isTracking || scroll.isDecelerating else { return }
        let atEnd = y + scroll.bounds.height >= scroll.contentSize.height + scroll.adjustedContentInset.bottom - 4
        let next = y < 40 || atEnd ? false : y - lastOffset > 6 ? true : y - lastOffset < -6 ? false : collapsed
        if next != collapsed { withAnimation(.smooth(duration: 0.3)) { collapsed = next } }
    }

    /// The page's article as plain text blocks, or nil when there isn't one. The script runs
    /// in its own content world, so the page's scripts can't tamper with it, and only text
    /// comes back: the reader view renders it natively, never as the page's markup.
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
      if (node.closest('nav,aside,footer,form,figure figcaption')) continue;
      const text = node.innerText.trim();
      if (text) blocks.push({ heading: /^H/.test(node.tagName), text });
    }
    const heading = document.querySelector('h1');
    return { title: (heading && heading.innerText.trim()) || document.title, blocks };
    """
}

/// Links that ask for a new window (target=_blank, window.open) open in the same tab.
final class PopupOpener: NSObject, WKUIDelegate {
    @MainActor static let shared = PopupOpener()
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

struct Visit: Codable, Hashable { var url: URL; var title: String; var at: Date }

@MainActor @Observable final class Browser {
    private(set) var tabs: [Tab] = []
    var selectedID: UUID?
    var spaceID: UUID { didSet { UserDefaults.standard.set(spaceID.uuidString, forKey: "space") } }
    private(set) var history: [Visit] = []
    var engine: SearchEngine { didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") } }
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

    init() {
        // Incognito never outlives the app, so a relaunch starts back in a Space.
        let space = UserDefaults.standard.string(forKey: "space").flatMap(UUID.init(uuidString:))
        spaceID = space == SpaceRow.incognito.id ? Local.space : space ?? Local.space
        engine = UserDefaults.standard.string(forKey: "engine").flatMap(SearchEngine.init(rawValue:)) ?? .google
        if let data = try? Data(contentsOf: tabsFile), let saved = try? JSONDecoder().decode([Tab.Saved].self, from: data) {
            tabs = saved.map(Tab.init).filter { !$0.isPrivate }; tabs.forEach(watch)
        }
        if let data = try? Data(contentsOf: historyFile) { history = (try? JSONDecoder().decode([Visit].self, from: data)) ?? [] }
        selectedID = UserDefaults.standard.string(forKey: "tab").flatMap(UUID.init(uuidString:))
        if selected?.spaceID != spaceID { selectedID = nil }
    }

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == spaceID } }

    func select(_ tab: Tab?) {
        if tab?.id != selectedID { selected?.takeSnapshot() }
        selectedID = tab?.id
        UserDefaults.standard.set(tab?.id.uuidString, forKey: "tab")
    }

    /// Favourites and pinned links return to the tab they opened, like on the Mac.
    func open(_ url: URL, home: URL? = nil, newTab: Bool = true) {
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
        if selected == nil { select(nil) }
        save()
    }
    func switchSpace(_ id: UUID) {
        spaceID = id
        select(spaceTabs.last)
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

    func clearHistory() {
        history = []; saveHistory()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// The last Incognito tab closed: drop its cookies and website data with the store.
    private func forgetPrivateData() {
        guard !tabs.contains(where: \.isPrivate) else { return }
        Browser.privateStore = .nonPersistent()
    }

    private func watch(_ tab: Tab) {
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
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ host: UIView, context: Context) {
        let web = tab.webView
        guard web.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        web.frame = host.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(web)
    }
}
