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
    /// A `var` only because suspension swaps it: the whole point of suspending a tab is
    /// dropping the WKWebView so WebKit tears its WebContent process down with it. Every
    /// reader outside this file keeps working — a suspended tab holds a fresh, unloaded
    /// WKWebView, which costs no process.
    private(set) var web: WKWebView
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
    /// Playing in a detached window. Kept so suspension leaves it alone even when the tab
    /// is in the background — which is exactly when a PiP video is being watched.
    @Published var pictureInPicture = false
    /// Making noise the user can hear. Muting the tab clears it.
    @Published var audible = false
    @Published var favicon: NSImage?
    /// Pinned tabs sit at the head of the strip and survive a relaunch.
    @Published var pinned = false
    /// True while this tab has no live page — see `suspend()`. Published so anything that
    /// wants to badge the strip can, but nothing does: suspension is meant to be invisible.
    @Published private(set) var suspended = false
    /// Last time the user was looking at this tab. The only input to the idle clock.
    var lastActive = Date.now
    /// Where a suspended tab is parked, and the state it comes back with.
    private(set) var parkedURL: URL?
    private var parkedState: Data?
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
        web = Tab.freshWebView(isPrivate: isPrivate, profileID: profileID)
        super.init()
        attach()
        if let url { web.load(URLRequest(url: url)) }
    }

    /// A WKWebView with nothing in it. WebKit does not spawn a WebContent process until
    /// something is actually loaded, which is what makes a suspended tab free.
    private static func freshWebView(isPrivate: Bool, profileID: UUID) -> WKWebView {
        let cfg = Tab.configuration(isPrivate: isPrivate, profileID: profileID)
        cfg.userContentController.addUserScript(
            WKUserScript(source: Autofill.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(
            WKUserScript(source: Previews.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // All frames, unlike the password script: an embedded player lives in an iframe.
        cfg.userContentController.addUserScript(
            WKUserScript(source: PictureInPicture.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false))
        cfg.userContentController.addUserScript(
            WKUserScript(source: TabAudio.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false))
        return WKWebView(frame: .zero, configuration: cfg)
    }

    /// Point `web` at this tab: the password bridge, the delegates, the developer settings
    /// and the KVO that republishes WebKit's state. Runs at init and again on every resume,
    /// because suspension swaps the web view out from under all of it.
    private func attach() {
        web.configuration.userContentController.add(WeakHandler(self), name: "vanepw")
        web.configuration.userContentController.add(WeakHandler(self), name: PictureInPicture.messageName)
        web.configuration.userContentController.add(WeakHandler(self), name: Previews.messageName)
        web.configuration.userContentController.add(WeakHandler(self), name: TabAudio.messageName)
        web.customUserAgent = Settings.userAgent
        web.isInspectable = Settings.inspectorEnabled     // right-click → Inspect Element
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.uiDelegate = self
        web.navigationDelegate = self
        obs = [
            web.observe(\.title, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    // A suspended tab keeps the title it was parked with — the strip must
                    // not flicker back to "New Tab" the moment the page goes away.
                    guard let self, !self.suspended else { return }
                    self.title = w.title?.isEmpty == false ? w.title! : "New Tab"
                    if !self.isPrivate, let u = w.url { self.history.retitle(u, title: self.title) }
                    self.extensions.sync()
                }
            },
            web.observe(\.url, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.editing, !self.suspended else { return }
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
        // attach() re-runs on resume, so this covers a waking tab too.
        TabAudio.watch(self) { [weak self] in self?.audible = $0 }
        TabAudio.reapply(self)
    }

    // MARK: Suspension

    /// The url this tab is on, live or parked. Everything that writes a tab down — pins,
    /// the session, spaces — has to come through here, or a suspended tab quietly vanishes
    /// from all of them.
    var currentURL: URL? { web.url ?? parkedURL }

    /// Enough to redraw the strip and to come back exactly where the user left off.
    var snapshot: Parked {
        Parked(title: title, state: parkedState ?? web.interactionState as? Data)
    }

    /// Drop the WKWebView, and with it the WebContent process, keeping only the
    /// interactionState. The failure mode is one-directional: a state that does not come
    /// back just means the tab reloads from its url.
    func suspend() {
        guard !suspended, let url = web.url else { return }
        parkedState = web.interactionState as? Data
        parkedURL = url
        suspended = true

        let old = web
        TabAudio.unwatch(self)         // KVO on a dead observee is a crash, not a leak
        obs = []                       // KVO on a view that is about to die
        old.stopLoading()
        old.uiDelegate = nil
        old.navigationDelegate = nil
        old.configuration.userContentController.removeScriptMessageHandler(forName: "vanepw")
        old.configuration.userContentController.removeScriptMessageHandler(forName: Previews.messageName)
        old.configuration.userContentController.removeScriptMessageHandler(
            forName: PictureInPicture.messageName)
        old.configuration.userContentController.removeScriptMessageHandler(forName: TabAudio.messageName)
        old.removeFromSuperview()      // SwiftUI should have done this already; belt and braces
        // ponytail: `old` is never deallocated — it survives at a high retain count, so
        // Tab.close() has to use `_close` SPI to give the process back. The retainer is
        // still unidentified, but these have been TESTED AND RULED OUT, so do not spend
        // the time again: a WKWebExtensionController on the configuration, a script message
        // handler (removed or left in place), an injected user script, and window
        // membership. A standalone WKWebView with each of those deallocates cleanly, so the
        // retainer is something in the live app graph — SwiftUI's hosting of the
        // NSViewRepresentable is the next place to look. The leak is an empty view with no
        // page and no process, bounded per suspend, so it is a wart, not a regression.
        Tab.close(old)
        // The replacement is unloaded, so every `tab.web.…` call site elsewhere still has a
        // real object to talk to and none of them costs a process.
        web = Tab.freshWebView(isPrivate: isPrivate, profileID: profileID)
        attach()
    }

    /// Shut the page down explicitly. Dropping the last Swift reference *ought* to be
    /// enough, and in a standalone harness it is — but measured inside Vane the web view
    /// stays alive at a retain count of 26 and its WebContent process with it, so
    /// suspension reclaimed nothing at all. `-[WKWebView _close]` is what WebKit's own
    /// clients call and it tears the process down immediately: 8 processes / 632 MB became
    /// 2 processes / 144 MB in the same run where the plain release changed nothing.
    ///
    /// ponytail: SPI, respondsToSelector-guarded exactly like `_inspector` in Develop.swift.
    /// If it ever disappears, `about:blank` still drops the page's memory and leaves a mostly
    /// empty process behind, which is a worse suspension rather than a broken browser.
    /// Ceiling: whatever is really holding the view is still holding it — this closes the
    /// page, it does not fix the leak. Upgrade path is finding that reference.
    private static func close(_ web: WKWebView) {
        let sel = Selector(("_close"))
        if web.responds(to: sel) { _ = web.perform(sel) }
        else if let blank = URL(string: "about:blank") { web.load(URLRequest(url: blank)) }
    }

    /// Rebuild the page. `interactionState` sets url and the back/forward list
    /// synchronously, so the url check below is a genuine "that state was no good".
    func resume() {
        guard suspended else { return }
        suspended = false
        if let parkedState { web.interactionState = parkedState }
        if web.url == nil, let parkedURL { web.load(URLRequest(url: parkedURL)) }
        parkedState = nil
        parkedURL = nil
        // interactionState restores a page without running a navigation, so didCommit
        // never fires for a waking tab.
        Zoom.apply(to: self)
    }

    /// Come up already suspended, so restoring thirty tabs costs one WebContent process
    /// instead of thirty. The strip still has a title and a favicon.
    func park(url: URL, _ p: Parked) {
        parkedURL = url
        parkedState = p.state
        suspended = true
        if !p.title.isEmpty { title = p.title }
        address = url.absoluteString
        favicon = favicons.icon(for: url)      // from the cache, no page needed
    }


    /// Load it now, or park it if we know enough about it to draw it without loading.
    func open(_ url: URL, parked p: Parked?) {
        if let p, Prefs.suspendTabs { park(url: url, p) } else { web.load(URLRequest(url: url)) }
    }

    func isPlayingMedia() async -> Bool {
        await web.requestMediaPlaybackState() == .playing
    }

    /// ponytail: one evaluateJavaScript, main frame only, `value != defaultValue` so a page
    /// that ships prefilled inputs does not pin itself open forever. Ceiling: nothing inside
    /// an iframe or a shadow root counts, and a page that stores its draft in JS state
    /// rather than in the DOM looks empty.
    func hasUnsubmittedInput() async -> Bool {
        let js = """
        (function(){for(const e of document.querySelectorAll('input,textarea')){\
        const t=(e.type||'').toLowerCase();\
        if(t==='hidden'||t==='submit'||t==='button'||t==='checkbox'||t==='radio')continue;\
        if(e.value&&e.value!==e.defaultValue)return true}\
        return !!document.querySelector('[contenteditable=true],[contenteditable=""]')})()
        """
        return (try? await web.evaluateJavaScript(js)) as? Bool ?? false
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
    /// Tab in the address bar: ask an assistant instead of searching.
    func ask(_ input: String) {
        let (assistant, question) = AIChat.match(input) ?? (AIChat.preferred, input)
        guard let target = AIChat.url(for: question, using: assistant) else { return }
        editing = false
        web.load(URLRequest(url: target))
    }

    func go(_ input: String) {
        // "claude how do actors work" opens Claude rather than searching for that sentence.
        if let (assistant, question) = AIChat.match(input),
           let target = AIChat.url(for: question, using: assistant) {
            editing = false
            web.load(URLRequest(url: target))
            return
        }
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
        Previews.shared.cancel()      // the link that raised it is gone
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
        // An https attempt we made ourselves that never connected. The honest page is the
        // https-only interstitial, which offers a way through; "the secure connection
        // failed" offers none.
        if let http = HTTPSOnly.downgradeOffer(after: error, url: failed, profileID: profileID) {
            suppressHistoryOnce = true
            w.loadSimulatedRequest(URLRequest(url: http),
                                   responseHTML: HTTPSOnly.interstitial(for: http))
            return
        }
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

    /// The destination is final here — redirects are done — and the new document has not
    /// laid out yet, so the remembered zoom is on before the page is ever painted.
    /// didStartProvisionalNavigation is too early (the url is still provisional, so a
    /// redirect applies the wrong site's level) and didFinish is too late (the page has
    /// already painted at the old zoom, which reads as a visible reflow bug).
    func webView(_ w: WKWebView, didCommit navigation: WKNavigation!) {
        Zoom.apply(to: self)
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        progress = 1
        loading = false
        fillPassword()
        favicons.load(for: self)
        guard let url = w.url else { return }
        bookmarked = history.isBookmarked(url)
        Task { readerAvailable = await Reader.isAvailable(in: w) }
        TabAudio.reapply(self)         // no-op unless this tab is muted
        if suppressHistoryOnce {
            suppressHistoryOnce = false
        } else if !isPrivate {
            history.record(url, title: w.title ?? "")
        }
        // A favourite is the tab itself, wherever it has gone: the pin on disk follows it.
        if pinned { TabStore.savePins(owning: self) }
    }

    /// HTTPS-only mode. `.cancel` plus a re-load is the only way to change a navigation's
    /// scheme from here — WebKit does not let the delegate rewrite the request.
    func webView(_ w: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        switch HTTPSOnly.decide(navigationAction, profileID: profileID) {
        case .allow:
            decisionHandler(.allow)
        case .upgrade(let to):
            decisionHandler(.cancel)
            w.load(HTTPSOnly.request(to))          // a shorter leash than the 60s default
        case .block(let at):
            decisionHandler(.cancel)
            suppressHistoryOnce = true
            w.loadSimulatedRequest(URLRequest(url: at),
                                   responseHTML: HTTPSOnly.interstitial(for: at))
        case .confirm(let at):
            decisionHandler(.cancel)
            if HTTPSOnly.confirmAndRemember(at, profileID: profileID) {
                w.load(URLRequest(url: at))
            }
        }
    }

    /// Without this nothing is ever routed to a download. WebKit only calls
    /// navigationResponse:didBecome: for a response the app answered `.download` to, so a
    /// Content-Disposition: attachment link simply navigated and rendered nothing.
    func webView(_ w: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        // The server asked for a save, or WebKit has no way to display it.
        let save = disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType
        decisionHandler(save ? .download : .allow)
    }

    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        TidyDownloads.remember(download, pageTitle: w.title)   // the page title only exists here
        Downloads.manager(for: profileID).attach(download)
    }

    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        TidyDownloads.remember(download, pageTitle: w.title)   // the page title only exists here
        Downloads.manager(for: profileID).attach(download)
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
        if m.name == TabAudio.messageName { TabAudio.handle(m.body, for: self); return }
        if m.name == Previews.messageName {
            guard let body = m.body as? [String: Any] else { return }
            if body["gone"] as? Bool == true { Previews.shared.cancel(); return }
            guard let raw = body["url"] as? String, let url = URL(string: raw) else { return }
            Previews.shared.request(url, from: self)
            return
        }
        if m.name == PictureInPicture.messageName {
            if let active = PictureInPicture.state(from: m.body) { pictureInPicture = active }
            return
        }
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
    @Published var current: Tab.ID? {
        didSet {
            // Selecting a tab is what wakes it, and it has to happen here rather than in a
            // Task: SwiftUI reads `tab.web` on this same turn of the run loop.
            if let t = tabs.first(where: { $0.id == current }) { t.lastActive = .now; t.resume() }
            // The tab being left behind starts its idle clock now, not when it was opened.
            if let old = tabs.first(where: { $0.id == oldValue }) { old.lastActive = .now }
            extensions.sync()
        }
    }
    /// Per window: hiding the sidebar in one window must not hide it in the next.
    @Published var sidebarShown = true
    /// The command bar. Set to open it in a mode, nil to close. Per window: two windows can
    /// each have their own open. `.address` is what ⌘L, ⌘T and clicking the address pill
    /// open — the place to type a url or a search.
    @Published var palette: PaletteMode?
    @Published var findOpen = false
    @Published var suggestions: [Suggestion] = []
    /// -1 means "no suggestion highlighted" — Enter then uses what was typed.
    @Published var suggestionIndex = -1

    var pickedSuggestion: Suggestion? {
        suggestions.indices.contains(suggestionIndex) ? suggestions[suggestionIndex] : nil
    }

    private var suggestTask: Task<Void, Never>?

    func suggest(_ query: String) {
        let local = isPrivate ? [] : history.suggest(query)
        suggestions = local
        suggestionIndex = -1
        suggestTask?.cancel()
        // Remote completions land later and only widen the list; the local half is already
        // drawn, and suggestionIndex is left alone so a late response cannot move the
        // user's arrow-key selection out from under them.
        suggestTask = Task { [isPrivate] in
            let merged = await SearchSuggestions.merged(query, local: local, isPrivate: isPrivate)
            guard !Task.isCancelled else { return }
            suggestions = merged
        }
    }

    func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        suggestionIndex = max(-1, min(suggestions.count - 1, suggestionIndex + delta))
    }

    func clearSuggestions() { suggestTask?.cancel(); suggestions = []; suggestionIndex = -1 }

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

    /// `parked` is url → what the session (or a space) knew about that tab: its title and
    /// its interactionState. A tab we have state for comes up suspended instead of loading.
    init(isPrivate: Bool = false, urls: [URL] = [],
         profileID: UUID = ProfileManager.shared.active.id, space: Space? = nil,
         parked: [String: Parked] = [:]) {
        self.isPrivate = isPrivate
        self.profileID = profileID
        self.currentSpaceID = space?.id
        TabStore.all.append(self)
        Suspension.begin()        // idempotent; here so main.swift needs no wiring
        // A space carries its own tabs and pins; otherwise fall back to the profile's pins.
        let urls = space.map { $0.tabURLs } ?? urls
        // Pins belong to the profile, not to a window, so only the first window of that
        // profile gets them back — and the session's copy of those same urls is dropped so
        // they don't come up twice.
        let firstOfProfile = TabStore.all.filter { $0.profileID == profileID && !$0.isPrivate }.count == 1
        let pins = space?.pinnedURLs
            ?? ((!isPrivate && firstOfProfile) ? TabStore.pinnedURLs(for: profileID) : [])
        // A space carries its own per-tab state in a sidecar; a window restore is handed one.
        let parked = space.map { Suspension.SpaceState.load(space: $0.id, profileID: profileID, in: Store.directory) } ?? parked
        restoreFavourites(pins, parked: parked)
        let rest = urls.filter { !pins.contains($0) }
        rest.forEach { newBlankTab().open($0, parked: parked[$0.absoluteString]) }
        // Favourites come back parked and stay parked: focus lands on the first ordinary
        // tab, and with none the column is bare and the search bar is up — the same thing
        // an empty window does, because as far as pages go it is one.
        current = tabs.first { !$0.pinned }?.id
        if rest.isEmpty { newTab(nil) }
    }

    /// Favourites, in order, all parked. Never loaded eagerly whatever `Prefs.suspendTabs`
    /// says: a tile is a place to go, and eight of them at launch are eight processes for
    /// pages nobody is looking at. `parked` may carry the state a favourite was last on.
    private func restoreFavourites(_ urls: [URL], parked: [String: Parked]) {
        for url in urls {
            let t = newBlankTab()
            t.pinned = true
            t.park(url: url, parked[url.absoluteString] ?? Parked())
        }
    }

    var active: Tab? { tabs.first { $0.id == current } }

    /// A new tab with nowhere to go loads *nothing* and opens the command bar instead. Arc's
    /// bet, and the right one: the homepage is a page nobody asked for, and about:blank at
    /// least stays out of the way while the user types where they actually meant to go.
    /// There is no new-tab page. ⌘T opens the search bar over whatever is showing, and the
    /// tab only comes into being when the user searches or opens something from it — a
    /// dismissed bar leaves nothing behind.
    func newTab(_ url: URL?) {
        if let url {
            newBlankTab().web.load(URLRequest(url: url))
        } else {
            palette = .newTab
        }
    }

    /// Shift-Return in the address bar: skip the results page. The first target replaces
    /// the current tab and the rest open beside it, with focus staying where the user was.
    func goInstant(_ input: String, from tab: Tab) {
        Task { [isPrivate] in
            let urls = await InstantLinks.targets(for: input, isPrivate: isPrivate)
            guard let first = urls.first else { return }
            tab.editing = false
            tab.web.load(URLRequest(url: first))
            let keep = tab.id
            for u in urls.dropFirst() { newTab(u) }
            current = keep          // newTab focuses what it opens; undo that
        }
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

    /// Close a tab — or, for a favourite, close its *page*: the tile stays, parked back at
    /// its home url, and only Unpin ever takes it out of the grid. Closing the last tab
    /// leaves an empty window, not no window: the sidebar stays and the page area shows the
    /// glass, the way Arc's does.
    func close(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        let outcome = TabStore.closing(i, pinned: tabs.map(\.pinned), lastActive: tabs.map(\.lastActive))
        // A favourite is the same tab, only moved into the grid: closing it leaves it exactly
        // as it is, and only Unpin ever takes it out. Nothing is "closed", so nothing is
        // pushed for Reopen Closed Tab either.
        if !outcome.keep {
            if !isPrivate { ClosedTabs.push(tab.currentURL) }
            tabs.remove(at: i)
            TabAudio.forget(id)        // else the maps grow by one per tab ever opened
        }
        extensions.sync()
        if current == id { current = outcome.next.map { tabs[$0].id } }
    }

    /// What closing the tab at `i` does, as pure index math over the strip's pin flags. A
    /// favourite is kept — parked in place — and an ordinary tab goes. `next` is what to show
    /// if the closed tab was showing, as an index into the strip *after* the close: a
    /// favourite hands over to the most recently used ordinary tab, an ordinary tab to its
    /// neighbour — unless that neighbour is a favourite, because waking a favourite over
    /// something else closing is exactly the "ones on top go away" the user complained of.
    /// nil means the content column goes bare.
    static func closing(_ i: Int, pinned: [Bool], lastActive: [Date]) -> (keep: Bool, next: Int?) {
        let keep = pinned[i]
        var rest = pinned, recent = lastActive
        if !keep { rest.remove(at: i); recent.remove(at: i) }
        if keep {
            let ordinary = rest.indices.filter { !rest[$0] }
            return (true, ordinary.max { recent[$0] < recent[$1] })
        }
        guard !rest.isEmpty else { return (false, nil) }
        let neighbour = min(i, rest.count - 1)
        return (false, rest[neighbour] ? nil : neighbour)
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

    /// Pinning parks the tab at the end of the pinned run; unpinning at the head of the rest.
    func togglePin(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: i)
        setPinned(tab, !tab.pinned)
        tabs.insert(tab, at: tabs.filter(\.pinned).count)
        savePins()
    }

    private func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard tab.pinned != pinned else { return }
        tab.pinned = pinned
        TidyTitles.refresh(tab)
    }

    /// One drop for the whole sidebar: `id` lands before or after `target` and takes on the
    /// target's side of the line — onto a tile pins, onto a row unpins — so the grid and
    /// the list read as one strip the user drags across.
    func drop(_ id: Tab.ID, onto target: Tab.ID, after: Bool) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let wantPinned = tabs[to].pinned
        let tab = tabs.remove(at: from)
        let touchesPins = tab.pinned || wantPinned
        setPinned(tab, wantPinned)
        let dest = TabStore.clampedDestination(
            count: tabs.count + 1,
            pinnedCount: tabs.filter(\.pinned).count + (tab.pinned ? 1 : 0),
            movingPinned: tab.pinned,
            to: TabStore.insertionIndex(from: from, target: to, after: after))
        tabs.insert(tab, at: min(dest, tabs.count))
        if touchesPins { savePins() }
    }

    /// Where a tab dragged from `from` goes to sit before (or after) `target`, once its own
    /// removal has shifted everything past it up by one.
    static func insertionIndex(from: Int, target: Int, after: Bool) -> Int {
        let t = target > from ? target - 1 : target
        return after ? t + 1 : t
    }

    /// A drop on the empty grid: the first favourite.
    func pin(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), !tabs[i].pinned else { return }
        let tab = tabs.remove(at: i)
        setPinned(tab, true)
        tabs.insert(tab, at: 0)
        savePins()
    }

    /// How many across the favourites grid runs, the way Arc lays it out: tiles grow to fill
    /// a row until there are enough for a square, then the rows fill up instead. 0 is the
    /// single full-width placeholder.
    static func favouriteColumns(_ count: Int) -> Int {
        switch count {
        case 0, 1: 1
        case 2, 3: count
        case 4: 2
        case 5, 6: 3
        default: 4
        }
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

    /// What is written down for a favourite: the page it is on. Only web pages; a blank or
    /// file tab is not a place to come back to.
    static func pinURL(_ current: URL?) -> String? {
        guard let s = current?.absoluteString, s.hasPrefix("http") else { return nil }
        return s
    }

    /// A pinned tab that navigated is still the pin, now pointing where it went.
    static func savePins(owning tab: Tab) {
        all.first { $0.tabs.contains { $0 === tab } }?.savePins()
    }

    func savePins() {
        guard !isPrivate else { return }
        let urls = tabs.filter(\.pinned).compactMap { TabStore.pinURL($0.currentURL) }
        // Inside a space the pins belong to the space, not to the profile — switching space
        // must not drag the last space's pins along.
        if let id = currentSpaceID, var space = spaces.first(where: { $0.id == id }) {
            space.pinnedURLs = urls.compactMap(URL.init(string:))
            ProfileManager.shared.updateSpace(space)
            return
        }
        UserDefaults.standard.set(urls, forKey: ProfileManager.defaultsKey("pinnedTabs", profileID))
    }

    // MARK: Spaces

    /// Every space in this window's profile. A space belongs to exactly one profile, so this
    /// is the complete list a window can ever switch between.
    var spaces: [Space] { ProfileManager.shared.spaces(for: profileID) }

    var currentSpace: Space? { spaces.first { $0.id == currentSpaceID } }

    /// Bumped whenever a space's name, icon or theme changes. `spaces` reads the file every
    /// time, so without a published counter nothing in the sidebar would know to redraw.
    @Published private(set) var spaceRevision = 0

    /// The one way the chrome edits a space: save it, tell the views, and re-apply the look.
    func update(space: Space) {
        ProfileManager.shared.updateSpace(space)
        spaceRevision += 1
        applySpaceAppearance()
    }

    /// A space can pin its window to light or dark; nil follows the system, which is what
    /// every window did before spaces had a look.
    func applySpaceAppearance() {
        switch currentSpace?.appearance {
        case "light": window?.appearance = NSAppearance(named: .aqua)
        case "dark":  window?.appearance = NSAppearance(named: .darkAqua)
        default:      window?.appearance = nil
        }
    }

    /// Write the open tabs back into whichever space this window is showing. No-op when the
    /// window is not in a space, and never for a private window — nothing private is written.
    func saveCurrentSpace() {
        guard !isPrivate, let id = currentSpaceID, var space = spaces.first(where: { $0.id == id })
        else { return }
        space.tabURLs = tabs.filter { !$0.pinned }.compactMap(\.currentURL).filter { $0.scheme?.hasPrefix("http") == true }
        space.pinnedURLs = tabs.filter(\.pinned).compactMap(\.currentURL).filter { $0.scheme?.hasPrefix("http") == true }
        ProfileManager.shared.updateSpace(space)
        // Scroll position and back/forward list, in a sidecar — `Space` is another file's
        // Codable struct and is not mine to widen. Keyed by url, which is what
        // `restoreFavourites` looks a favourite's state up by.
        var parked: [String: Parked] = [:]
        for t in tabs {
            guard let key = t.currentURL,
                  key.scheme?.hasPrefix("http") == true else { continue }
            parked[key.absoluteString] = t.snapshot
        }
        Suspension.SpaceState.save(parked, space: id, profileID: profileID, in: Store.directory)
    }

    /// Save the outgoing space, then rebuild the strip from the incoming one. A window shows
    /// one space at a time.
    ///
    /// The tabs are still torn down rather than parked alive, but each one's
    /// interactionState goes into the sidecar on the way out and comes back on the way in,
    /// so switching back lands on the same page, the same scroll offset and the same
    /// back/forward list. Ceiling: only the tab that becomes current actually loads — the
    /// rest come up suspended, which is the point.
    func switchTo(space: Space) {
        // A space's profileID is the only link to its profile, so refusing here is what keeps
        // a window from ever showing another profile's tabs.
        guard space.profileID == profileID, space.id != currentSpaceID else { return }
        saveCurrentSpace()
        // Not close(): that pushes onto the reopen stack and closes the window on the last tab.
        tabs.removeAll()
        currentSpaceID = space.id
        applySpaceAppearance()          // the new space may be pinned to light or dark
        let parked = Suspension.SpaceState.load(space: space.id, profileID: profileID, in: Store.directory)
        restoreFavourites(space.pinnedURLs, parked: parked)
        for url in space.tabURLs { newBlankTab().open(url, parked: parked[url.absoluteString]) }
        current = tabs.first { !$0.pinned }?.id
        if space.tabURLs.isEmpty { newTab(nil) }
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
        let space = ProfileManager.shared.createSpace(name: name, in: profileID)
        // Move in first, then save through the one path that also writes the state sidecar.
        currentSpaceID = space.id
        saveCurrentSpace()
        return spaces.first { $0.id == space.id } ?? space
    }
}
