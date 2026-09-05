import AppKit
import WebKit

/// Safari's UA string. WKWebView's own UA gets Netflix/Disney+ bounced on sight, and
/// FairPlay is only offered to clients that look like Safari. macOS 26 / Safari 26.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"

/// One tab. Owns its WKWebView and republishes the bits the chrome needs via KVO.
/// Which of Arc's three sidebar sections a tab lives in, in the order they are drawn.
/// The strip is kept sorted by this, so a section is a contiguous run and never a filter
/// that has to be re-sorted to be shown.
///
/// Favourites are the icon-only grid at the top; Pinned are list rows under the space's
/// name; Today is everything below the New Tab divider. Only Today auto-archives, and only
/// Today is closed by ⌘W — which is the whole reason the distinction exists.
enum TabKind: Int, Codable, Comparable, Sendable, CaseIterable {
    case favourite = 0, pinned = 1, today = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

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
    /// The link under the pointer, for the status bar. nil when nothing is hovered.
    @Published var hoveredLink: String?
    /// `web.pageZoom`, republished: the pill's zoom chip. Zoom.swift writes it.
    @Published var zoom = 1.0
    /// WebKit's `hasOnlySecureContent` and whether `serverTrust` evaluates — the pill's
    /// insecure glyph. Both start true and are only ever set by a live page.
    @Published var secureContent = true
    @Published var certificateTrusted = true
    /// Which section of the sidebar this tab is in. The strip is sorted by it.
    @Published var kind: TabKind = .today
    /// Favourites and Pinned both *stay*: neither auto-archives, ⌘W leaves both where they
    /// are, and both are written down so they come back after a relaunch. Almost everything
    /// that used to ask "is this pinned?" means this.
    var stays: Bool { kind != .today }
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
    /// A link the user asked for *beside* this tab — ⌘-click, middle-click, `target=_blank`.
    /// The Bool is whether to go there; ⌘-click deliberately does not.
    var onOpenBeside: ((URL, Bool) -> Void)?

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
        cfg.userContentController.addUserScript(
            WKUserScript(source: StatusBar.script, injectionTime: .atDocumentEnd,
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
        web.configuration.userContentController.add(WeakHandler(self), name: StatusBar.messageName)
        // A fresh web view has no page to be insecure about.
        secureContent = true
        certificateTrusted = true
        hoveredLink = nil
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
            web.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.suspended else { return }
                    self.secureContent = w.hasOnlySecureContent
                }
            },
            // A certificate the user clicked through is still a certificate that failed:
            // WebKit hands the trust back, and the pill says so for as long as it is shown.
            web.observe(\.serverTrust, options: [.new]) { [weak self] w, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.suspended else { return }
                    self.certificateTrusted = w.serverTrust.map { SecTrustEvaluateWithError($0, nil) } ?? true
                }
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
        old.configuration.userContentController.removeScriptMessageHandler(forName: StatusBar.messageName)
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

    /// The window holding this tab is closing. `suspend` is what drops the KVO observers,
    /// the script message handlers and the WebContent process; without it `TabAudio`'s
    /// observer outlives the web view it was watching — a crash, not a leak — the process
    /// is never given back, and a page handed to another window carries on playing sound
    /// from a window nobody can see any more.
    func tearDown() {
        suspend()
        TabAudio.forget(id)
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
        // A favourite or a pinned tab is the tab itself, wherever it has gone: the record
        // on disk follows it.
        if stays { TabStore.savePins(owning: self) }
    }

    /// HTTPS-only mode. `.cancel` plus a re-load is the only way to change a navigation's
    /// scheme from here — WebKit does not let the delegate rewrite the request.
    func webView(_ w: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // ⌘-click, ⇧⌘-click and middle-click are a request for a tab, not for this page to
        // go somewhere. Before HTTPS-only, because the new tab does its own load and gets
        // its own vetting.
        if let intent = TabActions.intent(for: navigationAction),
           let url = navigationAction.request.url, let open = onOpenBeside {
            decisionHandler(.cancel)
            open(url, intent.focus)
            return
        }
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
        if m.name == StatusBar.messageName { hoveredLink = StatusBar.link(from: m.body); return }
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
        if let url = action.request.url, let open = onOpenBeside {
            open(url, !action.modifierFlags.contains(.command))
        } else {
            onNewTab?(action.request.url)
        }
        return nil
    }
}

@MainActor final class TabStore: ObservableObject {
    @Published var tabs: [Tab] = []
    /// The tab whose row is a name field right now. One at a time, per window — and one
    /// between the two: arming either name field puts the other away, or two rows in the
    /// same list are both waiting to be typed into and only one of them can be.
    @Published var renamingTab: Tab.ID? {
        didSet { if renamingTab != nil { renamingFolder = nil } }
    }
    /// Arc's Folders: the shape of the Pinned section — which tabs sit in which folder, and
    /// the order the rows are drawn in. `tabs` still holds the tabs themselves; this only
    /// says how they are arranged. See `Pins` in Folders.swift.
    @Published var pins = Pins()
    /// The folder whose row is a name field right now, the way `renamingTab` is for a tab.
    @Published var renamingFolder: UUID? {
        didSet { if renamingFolder != nil { renamingTab = nil } }
    }
    /// Counts the archives that land in one burst, so Clear can sweep rows out one after
    /// another. See `archive`.
    private let bursts = Motion.Burst()
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
    /// A Little Arc window: one page, no sidebar, no Space. It shares the profile's cookies
    /// and history — it is the same browser, only a different window — but it owns none of
    /// the profile's furniture, so it restores no favourites and no pinned rows and is
    /// never written into the session. See LittleArc.swift.
    let isLittle: Bool
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
         parked: [String: Parked] = [:], isLittle: Bool = false) {
        self.isPrivate = isPrivate
        self.isLittle = isLittle
        self.profileID = profileID
        self.currentSpaceID = space?.id
        TabStore.all.append(self)
        Suspension.begin()        // idempotent; here so main.swift needs no wiring
        // A space carries its own tabs, favourites and pinned rows; otherwise fall back to
        // the profile's.
        // A Space's own Today tabs, plus whatever this window was asked to open — a url
        // handed to a window that is in a Space opens *in* that Space rather than replacing
        // it, which is what "new windows open in the current space" means.
        let urls = space.map { s in s.tabURLs + urls.filter { !s.tabURLs.contains($0) } } ?? urls
        // What stays belongs to the profile, not to a window, so only the first window of
        // that profile gets it back — and the session's copy of those same urls is dropped
        // so they don't come up twice.
        // A Little Arc does not count: it is not a window the profile's pinned rows belong
        // to, and letting it be "the first one" would cost the next real window its rows.
        let firstOfProfile = TabStore.all
            .filter { $0.profileID == profileID && !$0.isPrivate && !$0.isLittle }.count == 1
        let mine = !isPrivate && !isLittle && firstOfProfile
        // Favourites are the one thing every Space shares, so they come from the profile
        // whether this window is in a Space or not. `Spaces.favourites` also folds any
        // per-space grid an older spaces.json still carries into that one list.
        // A Little Arc has no sidebar to put either section in, and nothing it does may
        // move the profile's grid — so it starts with the one page it was handed.
        let favourites = isPrivate || isLittle ? [] : Spaces.favourites(for: profileID)
        let pinned = isLittle ? []
            : (space?.pinnedTabURLs ?? (mine ? TabStore.stayingURLs(.pinned, for: profileID) : []))
        // A space carries its own per-tab state in a sidecar; a window restore is handed one.
        let parked = space.map { Suspension.SpaceState.load(space: $0.id, profileID: profileID, in: Store.directory) } ?? parked
        restore(favourites, as: .favourite, parked: parked)
        // The Pinned section is not a list any more but a shape — folders and the tabs in
        // them — so its tabs come up in the order the folders draw them.
        restorePins(urls: pinned, parked: parked)
        let kept = Set(favourites + pinned)
        let rest = urls.filter { !kept.contains($0) }
        rest.forEach { newBlankTab().open($0, parked: parked[$0.absoluteString]) }
        // Favourites and pinned rows come back parked and stay parked: focus lands on the
        // first Today tab, and with none the column is bare and the search bar is up — the
        // same thing an empty window does, because as far as pages go it is one.
        current = tabs.first { $0.kind == .today }?.id
        // `openPalette`, not `newTab(nil)`: they do the same thing, but `newTab` on a Little
        // Arc opens another window, and a window opening itself does not end.
        if rest.isEmpty { openPalette(.newTab) }
        rememberSpace()
    }

    /// Which Space each profile was last showing. Arc comes back up in the Space you left it
    /// in, and opens a new window in the Space you are looking at; the session file holds
    /// tabs, not Spaces, so this is the one thing that has to be remembered separately.
    nonisolated static func lastSpaceKey(_ profileID: UUID) -> String {
        ProfileManager.defaultsKey("lastSpace", profileID)
    }

    static func lastSpace(for profileID: UUID) -> Space? {
        guard let raw = UserDefaults.standard.string(forKey: lastSpaceKey(profileID)),
              let id = UUID(uuidString: raw) else { return nil }
        return ProfileManager.shared.spaces(for: profileID).first { $0.id == id }
    }

    private func rememberSpace() {
        // A Little Arc is in no Space, and must not be read as "the user left this profile
        // outside every Space" — that would clear the Space the next window comes up in.
        guard !isPrivate, !isLittle else { return }
        let key = TabStore.lastSpaceKey(profileID)
        if let id = currentSpaceID {
            UserDefaults.standard.set(id.uuidString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// One section's tabs, in order, all parked. Never loaded eagerly whatever
    /// `Prefs.suspendTabs` says: a favourite tile or a pinned row is a place to go, and
    /// eight of them at launch are eight processes for pages nobody is looking at.
    /// `parked` may carry the state each one was last on.
    @discardableResult
    func restore(_ urls: [URL], as kind: TabKind, parked: [String: Parked]) -> [Tab] {
        urls.map { url in
            let t = newBlankTab()
            t.kind = kind
            t.park(url: url, parked[url.absoluteString] ?? Parked())
            return t
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
        // One page per Little Arc: ⌘T, the palette's New Tab and everything else that asks
        // this window for a tab gets another Little Arc instead of a second page hidden
        // behind the first. With no url it comes up empty with the search bar over it,
        // which is what a new window does.
        if isLittle { LittleArc.open(url); return }
        if let url {
            newBlankTab().web.load(URLRequest(url: url))
        } else {
            openPalette(.newTab)
        }
    }

    /// ⌘T, ⌘L and the pill: opening the bar over a bar that is already up closes it instead
    /// (Arc v0.107). `Palette.toggled` is where that decision is written down.
    func openPalette(_ mode: PaletteMode) { palette = Palette.toggled(current: palette, pressed: mode) }

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
        // A popup or a `target=_blank` link belongs next to the page that opened it, not at
        // the bottom of a list of thirty tabs — and it is what the user just asked for, so
        // it takes focus where a ⌘-click does not. Out of a Little Arc there is no list to
        // be beside, and a page that escaped into the sidebar is not what was clicked.
        t.onOpenBeside = { [weak self] u, focus in
            guard let self else { return }
            if isLittle { LittleArc.open(u) } else { openBeside(u, focus: focus) }
        }
        Motion.list { tabs.append(t) }
        current = t.id
        extensions.sync()
        return t
    }

    /// Close a tab — or, for a favourite, close its *page*: the tile stays, parked back at
    /// its home url, and only Unpin ever takes it out of the grid. Closing the last tab
    /// leaves an empty window, not no window: the sidebar stays and the page area shows the
    /// glass, the way Arc's does.
    /// ⌘W, and what the auto-archive sweep does: remember the page so it can be brought
    /// back from the Library, then close it. A favourite or a pinned tab is written down
    /// already and stays exactly where it is — `close` parks it — so nothing is archived
    /// for it either; that is the whole difference between the sections.
    func archive(_ id: Tab.ID) {
        // Several archives in one synchronous burst — Clear, Archive Tabs Below, the
        // auto-archive sweep — leave one after another, the way Arc sweeps Today away,
        // rather than all in the same frame. A lone ⌘W is a burst of one and goes at once.
        let delay = Motion.sweepDelay(bursts.next(), reduced: Motion.reduced)
        guard delay > 0 else { archiveNow(id); return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.archiveNow(id)      // a no-op if the tab has gone in the meantime
        }
    }

    private func archiveNow(_ id: Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.kind == .today, !isPrivate, let u = tab.currentURL,
           u.scheme?.hasPrefix("http") == true {
            Archive.shared(for: profileID).add(url: u, title: TidyTitles.title(for: tab))
        }
        close(id)
    }

    /// A row in the Library's Archived Tabs list, clicked: open it again and take it out of
    /// the archive, because it is not archived any more.
    func unarchive(_ entry: Archive.Entry) {
        Archive.shared(for: profileID).remove(entry.id)
        guard let u = URL(string: entry.url) else { return }
        newTab(u)
    }

    func close(_ id: Tab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        let outcome = TabStore.closing(i, kinds: tabs.map(\.kind), lastActive: tabs.map(\.lastActive))
        // A favourite or a pinned tab is the same tab, only moved into its section: closing
        // it leaves it exactly as it is, and only Unfavourite/Unpin ever takes it out.
        // Nothing is "closed", so nothing is pushed for Reopen Closed Tab either.
        if !outcome.keep {
            if !isPrivate { ClosedTabs.push(tab.currentURL) }
            Motion.list { _ = tabs.remove(at: i) }
            TabAudio.forget(id)        // else the maps grow by one per tab ever opened
            pins.remove(tab: id.uuidString)      // a folder outlives the tabs that left it
        }
        if renamingTab == id { renamingTab = nil }
        extensions.sync()
        if current == id { current = outcome.next.map { tabs[$0].id } }
    }

    /// What closing the tab at `i` does, as pure index math over the strip's kinds. A
    /// favourite or a pinned tab is kept — parked in place — and a Today tab goes. `next` is
    /// what to show if the closed tab was showing, as an index into the strip *after* the
    /// close: a kept tab hands over to the most recently used Today tab, a Today tab to its
    /// neighbour — unless that neighbour is one of the kept ones, because waking a favourite
    /// over something else closing is exactly the "ones on top go away" the user complained
    /// of. nil means the content column goes bare.
    static func closing(_ i: Int, kinds: [TabKind], lastActive: [Date]) -> (keep: Bool, next: Int?) {
        let keep = kinds[i] != .today
        var rest = kinds, recent = lastActive
        if !keep { rest.remove(at: i); recent.remove(at: i) }
        if keep {
            let ordinary = rest.indices.filter { rest[$0] == .today }
            return (true, ordinary.max { recent[$0] < recent[$1] })
        }
        guard !rest.isEmpty else { return (false, nil) }
        let neighbour = min(i, rest.count - 1)
        return (false, rest[neighbour] == .today ? neighbour : nil)
    }

    func cycle(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == current }), tabs.count > 1 else { return }
        current = tabs[(i + delta + tabs.count) % tabs.count].id
    }

    // MARK: Reorder + sections

    /// The one ordering invariant: the strip is sorted by section — every favourite ahead of
    /// every pinned tab, every pinned tab ahead of every Today tab — so each section is a
    /// contiguous run. A drag that would break it is clamped to the nearest position that
    /// doesn't. `others` is the strip's kinds with the moved tab *already removed*, and the
    /// result is an index into `others` to insert at.
    static func clampedDestination(others: [TabKind], moving: TabKind, to: Int) -> Int {
        let low = others.firstIndex { $0 >= moving } ?? others.count
        let high = others.lastIndex { $0 <= moving }.map { $0 + 1 } ?? 0
        return min(max(to, low), max(low, high))
    }

    /// Move a tab into a section. It lands at the end of Favourites or Pinned — where Arc
    /// drops one — and at the head of Today, so an unpinned tab appears right under the
    /// New Tab row rather than at the bottom of a long list.
    func move(_ id: Tab.ID, to kind: TabKind) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].kind != kind else { return }
        Motion.list {
            let tab = tabs.remove(at: i)
            setKind(tab, kind)
            let dest = TabStore.clampedDestination(others: tabs.map(\.kind), moving: kind,
                                                   to: kind == .today ? 0 : tabs.count)
            tabs.insert(tab, at: dest)
        }
        syncPins()          // a tab leaving Pinned leaves its folder with it
        savePins()
    }

    /// ⌘D / the Favourite Tab menu item: into the grid, or back down to Today.
    func toggleFavourite(_ id: Tab.ID) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        move(id, to: t.kind == .favourite ? .today : .favourite)
    }

    /// ⌘⇧D / the Pin Tab menu item: into the Pinned list, or back down to Today.
    func togglePinned(_ id: Tab.ID) {
        guard let t = tabs.first(where: { $0.id == id }) else { return }
        move(id, to: t.kind == .pinned ? .today : .pinned)
    }

    private func setKind(_ tab: Tab, _ kind: TabKind) {
        guard tab.kind != kind else { return }
        tab.kind = kind
        TidyTitles.refresh(tab)
    }

    /// One drop for the whole sidebar: `id` lands before or after `target` and takes on the
    /// target's section — onto a tile favourites it, onto a pinned row pins it, onto a Today
    /// row sends it back down — so the grid and the two lists read as one strip the user
    /// drags across.
    func drop(_ id: Tab.ID, onto target: Tab.ID, after: Bool) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let want = tabs[to].kind
        let touchesSections = Motion.list {
            let tab = tabs.remove(at: from)
            let touches = tab.stays || want != .today
            setKind(tab, want)
            let dest = TabStore.clampedDestination(
                others: tabs.map(\.kind), moving: want,
                to: TabStore.insertionIndex(from: from, target: to, after: after))
            tabs.insert(tab, at: min(dest, tabs.count))
            return touches
        }
        placeInPins(id, onto: target, after: after)
        if touchesSections { savePins() }
    }

    /// Where a tab dragged from `from` goes to sit before (or after) `target`, once its own
    /// removal has shifted everything past it up by one.
    static func insertionIndex(from: Int, target: Int, after: Bool) -> Int {
        let t = target > from ? target - 1 : target
        return after ? t + 1 : t
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

    /// ponytail: the two staying sections' urls in UserDefaults, deliberately not in
    /// session.json — the session is per-window and is rewritten by whichever window closed
    /// last, while favourites and pinned tabs have to outlive all of them. Ceiling: one set
    /// per profile, so favouriting in two windows at once means last writer wins.
    ///
    /// The default profile keeps the un-suffixed `pinnedTabs` key for its *favourites*: that
    /// key predates the split between Favourites and Pinned, and pointing it anywhere else
    /// would drop every existing user's grid on the floor for the sake of a tidier name.
    static func defaultsKey(_ kind: TabKind, _ profileID: UUID) -> String {
        ProfileManager.defaultsKey(kind == .favourite ? "pinnedTabs" : "pinnedRows", profileID)
    }

    static func stayingURLs(_ kind: TabKind, for profileID: UUID) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey(kind, profileID)) ?? [])
            .compactMap(URL.init(string:))
    }

    /// What is written down for a favourite or a pinned tab: the page it is on. Only web
    /// pages; a blank or file tab is not a place to come back to.
    static func pinURL(_ current: URL?) -> String? {
        guard let s = current?.absoluteString, s.hasPrefix("http") else { return nil }
        return s
    }

    /// A favourite or a pinned tab that navigated is still itself, now pointing where it
    /// went.
    static func savePins(owning tab: Tab) {
        all.first { $0.tabs.contains { $0 === tab } }?.savePins()
    }

    func savePins() {
        // A Little Arc holds no favourites and no pinned rows; writing its empty lists down
        // would erase the profile's.
        guard !isPrivate, !isLittle else { return }
        saveShape()          // the folders around the urls; see Folders.swift
        func urls(_ kind: TabKind) -> [String] {
            tabs.filter { $0.kind == kind }.compactMap { TabStore.pinURL($0.currentURL) }
        }
        let favourites = urls(.favourite), pinned = urls(.pinned)
        // Arc: the only thing Spaces share is Favourites. The grid belongs to the profile and
        // is written there from every window; the Pinned rows belong to whichever Space this
        // window is showing, and only fall back to the profile outside one.
        UserDefaults.standard.set(favourites, forKey: TabStore.defaultsKey(.favourite, profileID))
        if let id = currentSpaceID, var space = spaces.first(where: { $0.id == id }) {
            space.pinnedURLs = []          // migrated out; see Spaces.favourites
            space.pinnedTabURLs = pinned.compactMap(URL.init(string:))
            ProfileManager.shared.updateSpace(space)
            return
        }
        UserDefaults.standard.set(pinned, forKey: TabStore.defaultsKey(.pinned, profileID))
    }

    // MARK: Spaces

    /// Every space in this window's profile. A space belongs to exactly one profile, so this
    /// is the complete list a window can ever switch between.
    var spaces: [Space] { ProfileManager.shared.spaces(for: profileID) }

    var currentSpace: Space? { spaces.first { $0.id == currentSpaceID } }

    /// Bumped whenever a space's name, icon or theme changes. `spaces` reads the file every
    /// time, so without a published counter nothing in the sidebar would know to redraw.
    @Published private(set) var spaceRevision = 0

    /// The space whose inline editor is open in the sidebar's footer, if any. Arc's `+`
    /// makes the Space first and lets you name it in place; this is what says so.
    @Published var editingSpace: UUID?

    /// The space whose name is a text field in the header row right now. Double-clicking the
    /// name and "Rename Space…" both set it; Arc renames in place rather than in a dialog.
    @Published var renamingSpace: UUID?

    /// Which way the strip should slide on the next switch: +1 for a later Space (contents
    /// come in from the right), -1 for an earlier one. Arc slides in the direction of travel.
    @Published private(set) var spaceDirection = 1

    /// Same thing a `spaceRevision` bump does, for the code outside `update(space:)` that
    /// edits `spaces.json` directly — a move, a reorder, a delete.
    func spacesChanged() { spaceRevision += 1 }

    /// Sign of the move from the current Space to `space` in the sidebar's own order, so a
    /// wrap-around from the last Space to the first still slides forwards.
    private func direction(to space: Space) -> Int {
        let list = spaces
        guard let from = list.firstIndex(where: { $0.id == currentSpaceID }),
              let to = list.firstIndex(where: { $0.id == space.id }) else { return 1 }
        return to > from ? 1 : -1
    }

    /// Drag the footer dots: the profile's space order, rewritten.
    func reorderSpaces(from: Int, to: Int) {
        let list = Spaces.reordered(spaces, from: from, to: to)
        ProfileManager.shared.saveSpaces(list, for: profileID)
        spacesChanged()
    }

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
    /// A Little Arc is neither in a Space nor holding the profile's favourites, and writing
    /// its one tab down as both would empty the grid and the Space it was opened from.
    func saveCurrentSpace() {
        guard !isPrivate, !isLittle,
              let id = currentSpaceID, var space = spaces.first(where: { $0.id == id })
        else { return }
        func urls(_ keep: (Tab) -> Bool) -> [URL] {
            tabs.filter(keep).compactMap(\.currentURL).filter { $0.scheme?.hasPrefix("http") == true }
        }
        space.tabURLs = urls { $0.kind == .today }
        space.pinnedURLs = []              // Favourites are the profile's; see `savePins`
        space.pinnedTabURLs = urls { $0.kind == .pinned }
        saveShape()                        // and the folders those urls are arranged in
        ProfileManager.shared.updateSpace(space)
        UserDefaults.standard.set(urls { $0.kind == .favourite }.map(\.absoluteString),
                                  forKey: TabStore.defaultsKey(.favourite, profileID))
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
        // a window from ever showing another profile's tabs. A Little Arc is in no Space and
        // has no strip to rebuild — switching one would throw the page away and leave an
        // empty window claiming to be in a Space. Every route into here is shared with the
        // browser window (the palette's Space rows, ⌃1–9, ⌥⌘←/→, the Spaces menu), so the
        // refusal belongs here rather than at each of them.
        guard !isLittle, space.profileID == profileID, space.id != currentSpaceID else { return }
        saveCurrentSpace()
        // Which way the strip slides. Set before the switch so the sidebar's transition and
        // the tint cross-fade are already pointing the right way when the list changes.
        spaceDirection = direction(to: space)
        // Not close(): that pushes onto the reopen stack and closes the window on the last tab.
        // Favourites are the profile's, not the Space's, so their tabs stay exactly as they
        // are — Arc's grid does not so much as blink when you swipe between Spaces.
        tabs.removeAll { $0.kind != .favourite }
        currentSpaceID = space.id
        applySpaceAppearance()          // the new space may be pinned to light or dark
        let parked = Suspension.SpaceState.load(space: space.id, profileID: profileID, in: Store.directory)
        restorePins(urls: space.pinnedTabURLs ?? [], parked: parked)
        for url in space.tabURLs { newBlankTab().open(url, parked: parked[url.absoluteString]) }
        current = tabs.first { $0.kind == .today }?.id
        if space.tabURLs.isEmpty { openPalette(.newTab) }
        rememberSpace()
        extensions.sync()
    }

    /// ⌥⌘→ / ⌥⌘←: the next or previous space in this profile's list, wrapping round. A
    /// window with one space (or none) has nowhere to go, and does nothing.
    func cycleSpace(_ delta: Int) {
        let list = spaces
        guard list.count > 1, let i = list.firstIndex(where: { $0.id == currentSpaceID })
        else { return }
        switchTo(space: list[(i + delta + list.count) % list.count])
    }

    /// ⌃1…⌃9. Literally space N, unlike ⌘9 which means "the last tab": Arc numbers spaces
    /// and there is no ninth space to be the last one.
    func switchTo(spaceNumber n: Int) {
        let list = spaces
        guard list.indices.contains(n - 1) else { return }
        switchTo(space: list[n - 1])
    }

    /// The Library popover in the sidebar's footer, so ⇧⌘L can open it — it is a popover on
    /// a button, and AppKit has no way to press a SwiftUI button from a menu item.
    @Published var libraryOpen = false

    /// Convenience for a menu that has an id rather than the struct.
    func switchTo(spaceID: UUID) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        switchTo(space: space)
    }

    /// Create a space in this window's profile and move this window into it, carrying the
    /// tabs that are already open — which is what "new space" means from a window's point of
    /// view. Returns nil for a private window, which has no profile storage to write to.
    /// `name` defaults to Arc's placeholder because Arc's `+` does not ask: the Space appears
    /// straight away and the name field is already focused inside it. See `NewSpaceButton`.
    @discardableResult
    func newSpace(named name: String = "New Space") -> Space? {
        // Nor a Little Arc: it would make the Space and then move itself into it, taking the
        // page with it and leaving the browser window none the wiser.
        guard !isPrivate, !isLittle else { return nil }
        saveCurrentSpace()
        let space = ProfileManager.shared.createSpace(name: name, in: profileID)
        spaceDirection = 1                 // a new Space is always the last one
        if currentSpaceID != nil {
            // Arc's new Space is *empty*. Switching into it is what empties the strip; moving
            // `currentSpaceID` by hand would have written this window's open tabs into the new
            // Space as well as leaving them in the old one, so they showed up in both.
            switchTo(space: space)
        } else {
            // Outside any Space there is nothing to switch away from, and what is already open
            // is what the first Space is made of.
            currentSpaceID = space.id
            saveCurrentSpace()
        }
        palette = nil                      // the editor is the thing to look at, not the bar
        rememberSpace()
        editingSpace = space.id            // opens the inline name/icon/colour editor
        Toasts.show("New Space created", in: self)
        return spaces.first { $0.id == space.id } ?? space
    }
}
