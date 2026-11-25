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
    private var view: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    var onChange: () -> Void = {}

    init(_ saved: Saved) { id = saved.id; spaceID = saved.spaceID; url = saved.url; title = saved.title; home = saved.home }
    var saved: Saved { Saved(id: id, spaceID: spaceID, url: url, title: title, home: home) }

    var webView: WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
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
        ]
        web.load(URLRequest(url: url))
        view = web
        return web
    }
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
    private let tabsFile = Store.directory.appending(path: "tabs.json")
    private let historyFile = Store.directory.appending(path: "history.json")

    init() {
        spaceID = UserDefaults.standard.string(forKey: "space").flatMap(UUID.init(uuidString:)) ?? Local.space
        engine = UserDefaults.standard.string(forKey: "engine").flatMap(SearchEngine.init(rawValue:)) ?? .google
        if let data = try? Data(contentsOf: tabsFile), let saved = try? JSONDecoder().decode([Tab.Saved].self, from: data) {
            tabs = saved.map(Tab.init); tabs.forEach(watch)
        }
        if let data = try? Data(contentsOf: historyFile) { history = (try? JSONDecoder().decode([Visit].self, from: data)) ?? [] }
        selectedID = UserDefaults.standard.string(forKey: "tab").flatMap(UUID.init(uuidString:))
        if selected?.spaceID != spaceID { selectedID = nil }
    }

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == spaceID } }

    func select(_ tab: Tab?) {
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
        if selectedID == tab.id { select(spaceTabs.last) }
        save()
    }
    func closeTabs(in space: UUID) {
        tabs.removeAll { $0.spaceID == space }
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
        return history.filter { ($0.url.absoluteString.localizedCaseInsensitiveContains(text) || $0.title.localizedCaseInsensitiveContains(text)) && seen.insert($0.url).inserted }.prefix(8).map { $0 }
    }

    func clearHistory() {
        history = []; saveHistory()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    private func watch(_ tab: Tab) {
        tab.onChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
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
        try? JSONEncoder().encode(tabs.map(\.saved)).write(to: tabsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
