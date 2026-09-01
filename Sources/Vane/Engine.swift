import AppKit
import WebKit

/// Safari's UA string. WKWebView's own UA gets Netflix/Disney+ bounced on sight, and
/// FairPlay is only offered to clients that look like Safari. macOS 26 / Safari 26.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"

/// One tab. Owns its WKWebView and republishes the bits the chrome needs via KVO.
/// ponytail: KVO straight to @Published instead of a navigation-delegate state machine —
/// WebKit already tracks all of this.
@MainActor final class Tab: NSObject, ObservableObject, Identifiable, WKUIDelegate,
                            WKNavigationDelegate, WKScriptMessageHandler {
    let id = UUID()
    let web: WKWebView
    @Published var title = "New Tab"
    @Published var address = ""          // what the URL field shows
    @Published var progress = 0.0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// A password the page just submitted, waiting on the user to approve saving it.
    @Published var pendingSave: PendingSave?
    @Published var bookmarked = false
    /// Whether this page has an article worth reading — drives the toolbar button.
    @Published var readerAvailable = false
    @Published var favicon: NSImage?
    /// Pinned tabs sit at the head of the strip and survive a relaunch.
    @Published var pinned = false
    private var suppressHistoryOnce = false
    /// Set when a page is being edited in the URL field, so KVO doesn't fight the user.
    var editing = false
    private var obs: [NSKeyValueObservation] = []
    var onNewTab: ((URL?) -> Void)?

    let isPrivate: Bool
    /// Which profile's data this tab reads and writes. Never changes for the life of the tab.
    let profileID: UUID

    /// The profile-scoped singletons this tab must use. `Store.shared` and friends resolve to
    /// the *active* profile, which is the wrong one for a background window.
    var history: Store { Store.store(for: profileID) }
    var favicons: Favicons { Favicons.cache(for: profileID) }
    var extensions: ExtensionHost { ExtensionHost.host(for: profileID) }

    init(url: URL? = nil, isPrivate: Bool = false,
         profileID: UUID = ProfileManager.shared.active.id) {
        self.isPrivate = isPrivate
        self.profileID = profileID
        let cfg = Tab.configuration(isPrivate: isPrivate, profileID: profileID)
        cfg.userContentController.addUserScript(
            WKUserScript(source: Autofill.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "vanepw")
        web.customUserAgent = Settings.userAgent
        web.isInspectable = Settings.inspectorEnabled     // right-click → Inspect Element
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.uiDelegate = self
        web.navigationDelegate = self
        obs = [
            web.observe(\.title, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = w.title?.isEmpty == false ? w.title! : "New Tab"
                    if !self.isPrivate, let u = w.url { self.history.retitle(u, title: self.title) }
                    self.extensions.sync()
                }
            },
            web.observe(\.url, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.editing else { return }
                    self.address = w.url?.absoluteString ?? ""
                    self.extensions.sync()
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, self.loading else { return }
                    self.progress = max(self.progress, w.estimatedProgress)
                }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoBack = w.canGoBack }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated { self?.canGoForward = w.canGoForward }
            },
        ]
        if let url { web.load(URLRequest(url: url)) }
    }

    static func configuration(isPrivate: Bool = false,
                              profileID: UUID = ProfileManager.shared.active.id) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        // Persistent: cookies, logins, media keys — and one persistent store per profile, via
        // WKWebsiteDataStore(forIdentifier:). A private window gets a store that lives only as
        // long as the window does — that is the whole of private browsing.
        cfg.websiteDataStore = isPrivate ? .nonPersistent() : ProfileManager.dataStore(for: profileID)
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        // isInspectable governs remote inspection from Safari's Develop menu. The in-app
        // inspector window and the "Inspect Element" context-menu item are gated on this
        // preference instead, which has no public setter.
        // ponytail: KVC on a documented-by-everyone WebKit preference key, wrapped so a
        // rename degrades to "no dev tools" rather than a crash.
        cfg.preferences.setValue(Settings.inspectorEnabled, forKey: "developerExtrasEnabled")
        cfg.webExtensionController = ExtensionHost.host(for: profileID).controller
        Blocker.apply(to: cfg, profileID: profileID)
        return cfg
    }

    /// Address-bar input: a URL if it plausibly is one, otherwise a search.
    func go(_ input: String) {
        guard let target = Search.url(for: input) else { return }
        editing = false
        web.load(URLRequest(url: target))
    }

    /// Only ever over https — filling a saved password into a plaintext page hands it to
    /// anyone on the path, and saving one from there means it was already exposed.
    private var secureHost: String? {
        guard let u = web.url, u.scheme == "https", let h = u.host else { return nil }
        return h
    }

    func fillPassword() {
        guard let host = secureHost,
              let hit = Passwords.lookup(host: host, profileID: profileID) else { return }
        web.evaluateJavaScript(Autofill.fillJS(account: hit.account, password: hit.password))
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        progress = 0.08        // a sliver immediately, so the bar never appears to stall at 0
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        show(error, in: w)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        show(error, in: w)
    }

    /// loadSimulatedRequest, not loadHTMLString: it leaves the failed url in the address bar
    /// and in `location`, so the page's own Try Again button retries the right thing.
    private func show(_ error: Error, in w: WKWebView) {
        guard ErrorPage.shouldShow(error) else { return }
        let failed = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
            ?? URL(string: address)
        guard let failed else { return }
        // The simulated load reports success, so without this the failed url lands in
        // history. ponytail: consumed by the next didFinish, which is always this one.
        suppressHistoryOnce = true
        w.loadSimulatedRequest(URLRequest(url: failed),
                               responseHTML: ErrorPage.html(for: error, url: failed))
    }

    // 4: per-site camera/microphone. WebKit owns the geolocation prompt itself, so there
    // is no location equivalent to implement here.
    func webView(_ w: WKWebView, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await CertificateTrust.handle(challenge: challenge)
    }

    func webView(_ w: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        await SitePermissions.decide(origin: origin, type: type)
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        progress = 1
        loading = false
        fillPassword()
        favicons.load(for: self)
        // A pinned tab that navigated somewhere else is still the pin the user wants back.
        if pinned { TabStore.savePins(owning: self) }
        guard let url = w.url else { return }
        bookmarked = history.isBookmarked(url)
        Task { readerAvailable = await Reader.isAvailable(in: w) }
        if suppressHistoryOnce {
            suppressHistoryOnce = false
        } else if !isPrivate {
            history.record(url, title: w.title ?? "")
        }
    }

    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.attach(download)
    }

    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.attach(download)
    }

    func toggleBookmark() {
        guard let url = web.url, url.scheme?.hasPrefix("http") == true else { return }
        bookmarked = history.toggleBookmark(url, title: web.title ?? url.absoluteString)
    }

    /// ⌘F. WebKit owns the search itself, including wrapping and highlight.
    func find(_ text: String, forward: Bool = true) async -> Bool {
        guard !text.isEmpty else { return true }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.wraps = true
        return (try? await web.find(text, configuration: cfg))?.matchFound ?? false
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any],
              let password = body["password"] as? String, !password.isEmpty,
              let host = secureHost else { return }
        let account = (body["account"] as? String) ?? ""
        // Already stored and unchanged — nothing to ask about.
        if let hit = Passwords.lookup(host: host, profileID: profileID),
           hit.account == account, hit.password == password { return }
        pendingSave = PendingSave(host: host, account: account, password: password)
    }

    func confirmSave() {
        guard let p = pendingSave else { return }
        Passwords.save(host: p.host, account: p.account, password: p.password, profileID: profileID)
        pendingSave = nil
    }

    func reload()     { web.reload() }
    func hardReload() { web.reloadFromOrigin() }
    func stop()       { web.stopLoading(); loading = false }

    /// ⌥⌘U. ponytail: WebKit has no view-source: handler, so this is the page's own HTML
    /// in a <pre>. No syntax highlighting — that is what the inspector is for.
    func viewSource(into store: TabStore) {
        web.evaluateJavaScript("document.documentElement.outerHTML") { html, _ in
            guard let html = html as? String else { return }
            let escaped = html.replacingOccurrences(of: "&", with: "&amp;")
                              .replacingOccurrences(of: "<", with: "&lt;")
                              .replacingOccurrences(of: ">", with: "&gt;")
            let tab = store.newBlankTab()
            tab.title = "Source of " + (self.web.url?.host ?? "page")
            tab.web.loadHTMLString(
                "<meta charset=utf-8><body style='margin:0'>"
                + "<pre style='font:12px ui-monospace,Menlo,monospace;padding:16px;"
                + "white-space:pre-wrap;word-break:break-word'>\(escaped)</pre>", baseURL: nil)
        }
    }
    func back()    { web.goBack() }
    func forward() { web.goForward() }

    // target="_blank" and window.open — hand it to a real tab instead of a popup window.
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        onNewTab?(action.request.url)
        return nil
    }
}

@MainActor final class TabStore: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var current: Tab.ID? { didSet { extensions.sync() } }
    /// Bumped to pull focus into the URL field (⌘L, new tab) / open the find bar (⌘F).
    @Published var focusAddress = 0
    @Published var findOpen = false
    @Published var suggestions: [Suggestion] = []
    /// -1 means "no suggestion highlighted" — Enter then uses what was typed.
    @Published var suggestionIndex = -1

    var pickedSuggestion: Suggestion? {
        suggestions.indices.contains(suggestionIndex) ? suggestions[suggestionIndex] : nil
    }

    func suggest(_ query: String) {
        suggestions = isPrivate ? [] : history.suggest(query)
        suggestionIndex = -1
    }

    func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = max(-1, min(suggestions.count - 1, suggestionIndex + delta))
    }

    func clearSuggestions() { suggestions = []; suggestionIndex = -1 }

    let isPrivate: Bool
    /// The profile this window belongs to. A window never changes profile — opening another
    /// profile opens another window.
    let profileID: UUID
    /// Which space this window is showing, if any. A window shows one space at a time.
    @Published private(set) var currentSpaceID: UUID?
    weak var window: NSWindow?
    /// Every live window, oldest first.
    static var all: [TabStore] = []

    var profile: Profile {
        ProfileManager.shared.profiles.first { $0.id == profileID } ?? ProfileManager.shared.active
    }
    var history: Store { Store.store(for: profileID) }
    var favicons: Favicons { Favicons.cache(for: profileID) }
    var extensions: ExtensionHost { ExtensionHost.host(for: profileID) }

    static var home: URL { Prefs.homepage }

    init(isPrivate: Bool = false, urls: [URL] = [],
         profileID: UUID = ProfileManager.shared.active.id, space: Space? = nil) {
        self.isPrivate = isPrivate
        self.profileID = profileID
        self.currentSpaceID = space?.id
        TabStore.all.append(self)
        // A space carries its own tabs and pins; otherwise fall back to the profile's pins.
        let urls = space.map { $0.tabURLs } ?? urls
        // Pins belong to the profile, not to a window, so only the first window of that
        // profile gets them back — and the session's copy of those same urls is dropped so
        // they don't come up twice.
        let firstOfProfile = TabStore.all.filter { $0.profileID == profileID && !$0.isPrivate }.count == 1
        let pins = space?.pinnedURLs
            ?? ((!isPrivate && firstOfProfile) ? TabStore.pinnedURLs(for: profileID) : [])
        for url in pins {
            let t = newBlankTab()
            t.pinned = true
            t.favicon = favicons.icon(for: url)          // from cache, before the page loads
            t.web.load(URLRequest(url: url))
        }
        let rest = urls.filter { !pins.contains($0) }
        if rest.isEmpty && pins.isEmpty { newTab(nil) } else { rest.forEach { newTab($0) } }
        // Restored pins sit first but are not what the user asked for, so focus lands on
        // the first ordinary tab when there is one.
        current = (tabs.first { !$0.pinned } ?? tabs.first)?.id
    }

    var active: Tab? { tabs.first { $0.id == current } }

    func newTab(_ url: URL?) {
        let t = newBlankTab()
        t.web.load(URLRequest(url: url ?? TabStore.home))
        if url == nil { focusAddress += 1 }
    }

    @discardableResult
    func newBlankTab() -> Tab {
        let t = Tab(isPrivate: isPrivate, profileID: profileID)
        t.onNewTab = { [weak self] u in self?.newTab(u) }
        tabs.append(t)
        current = t.id
        extensions.sync()
        return t
    }

    func close(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if !isPrivate { ClosedTabs.push(tabs[i].web.url) }
        let wasPinned = tabs[i].pinned
        tabs.remove(at: i)
        if wasPinned { savePins() }
        extensions.sync()
        // Last tab closed closes the window, the way every other Mac browser behaves.
        if tabs.isEmpty { window?.performClose(nil); return }
        if current == id { current = tabs[min(i, tabs.count - 1)].id }
    }

    func cycle(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == current }), tabs.count > 1 else { return }
        current = tabs[(i + delta + tabs.count) % tabs.count].id
    }

    // MARK: Reorder + pins

    /// The one ordering invariant: every pinned tab sits ahead of every unpinned one. A
    /// drag that would break it is clamped to the nearest position that doesn't.
    /// `count` and `pinnedCount` describe the strip *after* the move.
    static func clampedDestination(count: Int, pinnedCount: Int, movingPinned: Bool, to: Int) -> Int {
        let low = movingPinned ? 0 : pinnedCount
        let high = movingPinned ? pinnedCount - 1 : count - 1
        return min(max(to, low), max(low, high))
    }

    func move(from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let tab = tabs.remove(at: from)
        let dest = TabStore.clampedDestination(
            count: tabs.count + 1,
            pinnedCount: tabs.filter(\.pinned).count + (tab.pinned ? 1 : 0),
            movingPinned: tab.pinned, to: to)
        tabs.insert(tab, at: min(dest, tabs.count))
        if tab.pinned { savePins() }
    }

    /// Pinning parks the tab at the end of the pinned run; unpinning at the head of the rest.
    func togglePin(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: i)
        tab.pinned.toggle()
        tabs.insert(tab, at: tabs.filter(\.pinned).count)
        savePins()
    }

    /// ponytail: pinned urls in UserDefaults, deliberately not in session.json — the
    /// session is per-window and is rewritten by whichever window closed last, while pins
    /// have to outlive all of them. Ceiling: one shared pin set, so pinning in two windows
    /// at once means last writer wins.
    static var pinnedURLs: [URL] { pinnedURLs(for: ProfileManager.shared.active.id) }

    /// Pins are profile data. The default profile keeps the un-suffixed `pinnedTabs` key, so
    /// pins from before profiles existed are simply the default profile's pins.
    static func pinnedURLs(for profileID: UUID) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: ProfileManager.defaultsKey("pinnedTabs", profileID)) ?? [])
            .compactMap(URL.init(string:))
    }

    func savePins() {
        guard !isPrivate else { return }
        let urls = tabs.filter(\.pinned).compactMap { $0.web.url?.absoluteString }
                       .filter { $0.hasPrefix("http") }
        // Inside a space the pins belong to the space, not to the profile — switching space
        // must not drag the last space's pins along.
        if let id = currentSpaceID, var space = spaces.first(where: { $0.id == id }) {
            space.pinnedURLs = urls.compactMap(URL.init(string:))
            ProfileManager.shared.updateSpace(space)
            return
        }
        UserDefaults.standard.set(urls, forKey: ProfileManager.defaultsKey("pinnedTabs", profileID))
    }

    /// Save from whichever store actually owns this tab, so a window with no pins never
    /// overwrites the pins of one that has them.
    static func savePins(owning tab: Tab) {
        all.first { $0.tabs.contains { $0 === tab } }?.savePins()
    }

    // MARK: Spaces

    /// Every space in this window's profile. A space belongs to exactly one profile, so this
    /// is the complete list a window can ever switch between.
    var spaces: [Space] { ProfileManager.shared.spaces(for: profileID) }

    var currentSpace: Space? { spaces.first { $0.id == currentSpaceID } }

    /// Write the open tabs back into whichever space this window is showing. No-op when the
    /// window is not in a space, and never for a private window — nothing private is written.
    func saveCurrentSpace() {
        guard !isPrivate, let id = currentSpaceID, var space = spaces.first(where: { $0.id == id })
        else { return }
        space.tabURLs = tabs.filter { !$0.pinned }.compactMap(\.web.url).filter { $0.scheme?.hasPrefix("http") == true }
        space.pinnedURLs = tabs.filter(\.pinned).compactMap(\.web.url).filter { $0.scheme?.hasPrefix("http") == true }
        ProfileManager.shared.updateSpace(space)
    }

    /// Save the outgoing space, then rebuild the strip from the incoming one. A window shows
    /// one space at a time.
    ///
    /// ponytail: the tabs are torn down and reloaded from urls rather than parked alive —
    /// same trade the session restore already makes. Ceiling: switching back loses scroll
    /// position and the back/forward list. Upgrade path is keeping the Tab objects in a
    /// per-space array on the store and swapping the arrays instead of the urls.
    func switchTo(space: Space) {
        // A space's profileID is the only link to its profile, so refusing here is what keeps
        // a window from ever showing another profile's tabs.
        guard space.profileID == profileID, space.id != currentSpaceID else { return }
        saveCurrentSpace()
        // Not close(): that pushes onto the reopen stack and closes the window on the last tab.
        tabs.removeAll()
        currentSpaceID = space.id
        for url in space.pinnedURLs {
            let t = newBlankTab()
            t.pinned = true
            t.favicon = favicons.icon(for: url)
            t.web.load(URLRequest(url: url))
        }
        for url in space.tabURLs { newTab(url) }
        if tabs.isEmpty { newTab(nil) }
        current = (tabs.first { !$0.pinned } ?? tabs.first)?.id
        extensions.sync()
    }

    /// Convenience for a menu that has an id rather than the struct.
    func switchTo(spaceID: UUID) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        switchTo(space: space)
    }

    /// Create a space in this window's profile and move this window into it, carrying the
    /// tabs that are already open — which is what "new space" means from a window's point of
    /// view. Returns nil for a private window, which has no profile storage to write to.
    @discardableResult
    func newSpace(named name: String) -> Space? {
        guard !isPrivate else { return nil }
        saveCurrentSpace()
        var space = ProfileManager.shared.createSpace(name: name, in: profileID)
        space.tabURLs = tabs.filter { !$0.pinned }.compactMap(\.web.url)
        space.pinnedURLs = tabs.filter(\.pinned).compactMap(\.web.url)
        ProfileManager.shared.updateSpace(space)
        currentSpaceID = space.id
        return space
    }
}
