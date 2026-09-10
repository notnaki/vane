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

/// One AI rename, as the row needs to draw it: how many have landed on this tab (so a
/// second one still animates) and the name the row was showing before this one arrived.
///
/// A value rather than two properties because the row animates on the pair changing
/// together, and two `@Published`s would publish twice and start the wipe against the new
/// name's own leftovers.
struct TitleReveal: Equatable, Sendable {
    var count = 0
    /// The name being replaced. Empty on a tab nothing has ever renamed.
    var from = ""
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
    /// The last time the on-device model renamed this tab, and what the row said before it
    /// did. Bumped by `noteAITitle` and by nothing else: a page navigating or swapping its
    /// own `<title>` is not a rename, and the row must not shimmer for it. See
    /// `ShimmerTitle` in UI.swift.
    @Published private(set) var titleReveal = TitleReveal()
    @Published var address = ""          // what the URL field shows
    @Published var progress = 0.0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// A password the page just submitted, waiting on the user to approve saving it.
    @Published var pendingSave: PendingSave?
    /// The account list hanging under this page's login form, when the site has more than
    /// one saved login. Nil the rest of the time, which is most of the time.
    @Published var passwordChoice: PasswordChoice?
    /// When this tab last filled a password. Filling moves the focus out of the page and
    /// back, which is another focusin — see `PasswordChooser.refillGrace`.
    private var lastFilledAt = Date.distantPast
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
    /// The frames of this page that say they hold a caret — an input, a textarea, a
    /// contenteditable. Kept current by the page itself (see `PageFocus`) so the key monitor
    /// can ask without an await: it is what stops ⌘← navigating out of a half-typed comment.
    /// A set rather than a flag because each frame only ever speaks for itself.
    /// Deliberately not `@Published`: nothing draws it, and on a page that moves focus as
    /// you type a published flag is a redraw per keystroke.
    var editableFrames: Set<String> = []
    /// Anywhere in this page is being typed into.
    var editableFocused: Bool { !editableFrames.isEmpty }
    /// `web.pageZoom`, republished: the pill's zoom chip. Zoom.swift writes it.
    @Published var zoom = 1.0
    /// WebKit's `hasOnlySecureContent` and whether `serverTrust` evaluates — the pill's
    /// insecure glyph. Both start true and are only ever set by a live page.
    @Published var secureContent = true
    @Published var certificateTrusted = true
    /// Which section of the sidebar this tab is in. The strip is sorted by it.
    ///
    /// The `didSet` is the one place a row's `homeURL` is decided, and it is here rather
    /// than at the half-dozen callers because they are a half-dozen: `move`, `drop`, the
    /// pin and favourite actions, `newBlankTab(as:)`, a folder dragged between the sections
    /// (Folders.swift) and a popup being adopted all set this field, and a home recorded at
    /// five of them is a home the sixth quietly forgets.
    @Published var kind: TabKind = .today {
        didSet { homeURL = TabStore.home(entering: kind, at: currentURL) }
    }
    /// The page this row *stands for*: the one it was pinned or favourited at. Arc's rule —
    /// browse a pinned row wherever you like, and ⌘W or the row's × puts it back on the page
    /// it was pinned at, which is also the page written down for the next launch.
    ///
    /// nil for a Today tab, and for a row pinned while it was still blank: a row with
    /// nowhere to be sent back to parks in place exactly as it always did. Set on the way
    /// into a section (above) and by `park`, which is how a row restored from disk — where
    /// the saved list *is* the home — and a live folder's row both get one.
    @Published private(set) var homeURL: URL?
    /// Whether this row is on the page it stands for. Always true for a row with no home.
    /// See `TabRowGlyph.decide`, which turns a wandered parked row's × back into "go home".
    var atHome: Bool { TabStore.goesHome(home: homeURL, at: currentURL) == nil }
    /// What a favourite or a pinned row is written down as. `savePins` and
    /// `saveCurrentSpace` both write it and must agree, or the Space fingerprint they feed
    /// would read one of the two as somebody else's edit and tear the Space down on every
    /// switch.
    var pinnedURL: URL? { TabStore.pinned(home: homeURL, at: currentURL) }
    /// Favourites and Pinned both *stay*: neither auto-archives, ⌘W leaves both where they
    /// are, and both are written down so they come back after a relaunch. Almost everything
    /// that used to ask "is this pinned?" means this.
    var stays: Bool { kind != .today }
    /// True while this tab has no live page — see `suspend()`. Published so anything that
    /// wants to badge the strip can, but nothing does: suspension is meant to be invisible.
    @Published private(set) var suspended = false
    /// Whether this tab has ever been given a page — one it loaded, or one it came up from
    /// disk parked on. Deliberately *not* `web.url != nil`, which those two states share
    /// with a third: the gap between `resume` handing the view a load and `WKWebView.url`
    /// catching up with it. A pinned row's × read that gap as "nothing left to unload" and
    /// took the pin off in one press. Once true it stays true — a tab that has held a page
    /// is never again a tab that never held one. See `TabRowGlyph.unpinsWithNothingParked`.
    var hasEverLoaded = false
    /// Last time the user was looking at this tab. The MRU order behind ⌃⇥ and the media
    /// tray's tie-break as well as an input to the idle clock, which is why nothing but a
    /// real visit ever writes it.
    var lastActive = Date.now
    /// When this tab last stopped making noise — written by `TabAudio`, read only by the
    /// auto-archive sweep. A tab that played for eight hours has not been idle for eight
    /// hours, and `Archive.idle` starts its clock here. `.distantPast` until it plays.
    var lastQuiet = Date.distantPast
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
    /// A link this tab should show *over* the window instead of going to — see Peek.swift.
    /// Left nil in a window with nowhere to float one, which is what keeps the test in
    /// `decidePolicyFor` a single condition rather than a list of exceptions.
    var onPeek: ((URL) -> Void)?
    /// A window this page asked for with `window.open` or `target=_blank`, and where its
    /// window said it should go. The web view that comes back is WebKit's own — see
    /// `createWebViewWith`, which hands it straight on. Nil is a popup that was refused.
    var onPopup: ((WKWebViewConfiguration, Popup.Placement) -> WKWebView?)?
    /// `window.close()`. Only ever called for a page a script opened, which is why every tab
    /// can carry it: WebKit refuses the call on a page the user navigated to themselves.
    var onClose: (() -> Void)?

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
        if let url { go(url) }
    }

    /// A tab around a page WebKit has already made: the popup behind `window.open` and
    /// `target=_blank`. The configuration is not ours to build — WebKit derives it from the
    /// opener's and hands it to the delegate, and a web view made from *that one* is what
    /// puts the opener on the popup's `window.opener`, gives the popup a page to be navigated
    /// to, and makes `window.close()` mean something. Building a plain tab and loading the
    /// url into it instead — which is what Vane used to do — quietly loses all three.
    ///
    /// So the configuration is taken as it comes, and the data store on it above all: it is
    /// already the opener's, which is how a popup out of a Private Window stays private
    /// without anything here knowing which window that was.
    ///
    /// Everything else a tab has, this tab gets: `attach()` puts the delegates, the user
    /// agent, the developer settings and the KVO on it exactly as for any other page.
    init(popup cfg: WKWebViewConfiguration, isPrivate: Bool, profileID: UUID) {
        self.isPrivate = isPrivate
        self.profileID = profileID
        // The one thing that must *not* be shared. WebKit copies the configuration but not
        // its content controller — the popup arrives holding the opener's own object — and
        // two tabs on one controller is two bugs: `attach()` would throw on script message
        // handlers that are already registered under those names, and suspending either tab
        // would tear the other's password bridge, media tray and status bar out from under
        // it. The scripts and the blocker's rules go onto one of this tab's own instead.
        cfg.userContentController = Tab.contentController(profileID: profileID)
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        attach()
        // Deliberately no load: WebKit navigates the view it is handed back, and for a popup
        // opened blank and written into by its opener there is nothing to navigate it to.
    }

    /// A WKWebView with nothing in it. WebKit does not spawn a WebContent process until
    /// something is actually loaded, which is what makes a suspended tab free.
    private static func freshWebView(isPrivate: Bool, profileID: UUID) -> WKWebView {
        let cfg = Tab.configuration(isPrivate: isPrivate, profileID: profileID)
        cfg.userContentController = contentController(profileID: profileID)
        return WKWebView(frame: .zero, configuration: cfg)
    }

    /// The scripts every page of a tab runs, and the blocker's rules, on a content controller
    /// of their own. Split out of `freshWebView` for the popup path, which is handed a
    /// configuration whose controller belongs to somebody else — see `init(popup:)`.
    private static func contentController(profileID: UUID) -> WKUserContentController {
        let c = WKUserContentController()
        c.addUserScript(
            WKUserScript(source: Autofill.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true, in: Autofill.world))
        c.addUserScript(
            WKUserScript(source: Previews.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        // All frames, unlike the password script: an embedded player lives in an iframe.
        // Its own content world: `__vanePiP` is then not on the page's `window` at all.
        c.addUserScript(
            WKUserScript(source: PictureInPicture.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false, in: PictureInPicture.world))
        c.addUserScript(
            WKUserScript(source: TabAudio.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false))
        // Document *start*: the media-session wrapper has to be in place before the page
        // registers its handlers. See MediaPlayer.swift.
        c.addUserScript(
            WKUserScript(source: MediaTray.script, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))
        c.addUserScript(
            WKUserScript(source: StatusBar.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false))
        // Document *start* and every frame: the listeners have to be in place before a page
        // can autofocus its search box, and a comment box is as often in an iframe as not.
        c.addUserScript(
            WKUserScript(source: PageFocus.script, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false, in: PageFocus.world))
        // A tab built around WebKit's own configuration never went through
        // `Tab.configuration`, so the blocker is attached here rather than there.
        Blocker.apply(to: c, profileID: profileID)
        return c
    }

    /// Point `web` at this tab: the password bridge, the delegates, the developer settings
    /// and the KVO that republishes WebKit's state. Runs at init and again on every resume,
    /// because suspension swaps the web view out from under all of it.
    private func attach() {
        web.configuration.userContentController.add(WeakHandler(self),
                                                    contentWorld: Autofill.world, name: "vanepw")
        web.configuration.userContentController.add(WeakHandler(self),
                                                    contentWorld: PictureInPicture.world,
                                                    name: PictureInPicture.messageName)
        web.configuration.userContentController.add(WeakHandler(self), name: Previews.messageName)
        web.configuration.userContentController.add(WeakHandler(self), name: TabAudio.messageName)
        web.configuration.userContentController.add(WeakHandler(self), name: MediaTray.messageName)
        web.configuration.userContentController.add(WeakHandler(self), name: StatusBar.messageName)
        web.configuration.userContentController.add(WeakHandler(self),
                                                    contentWorld: PageFocus.world,
                                                    name: PageFocus.messageName)
        // A fresh web view has no page to be insecure about.
        secureContent = true
        certificateTrusted = true
        hoveredLink = nil
        editableFrames = []
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
                    self.title = Files.title(page: w.title, url: w.url)
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

    /// The on-device model has just handed back a shorter name for this page and it is now
    /// what the row will draw. `was` is what the row said a moment ago, so it can be faded
    /// out from under the new one. A no-op when the name did not actually change — the model
    /// agreeing with the cheap answer is not an event.
    func noteAITitle(replacing was: String) {
        guard was != TidyTitles.title(for: self) else { return }
        titleReveal = TitleReveal(count: titleReveal.count + 1, from: was)
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
        release()
    }

    /// The half of suspension that lets go: the observers, the script message handlers, the
    /// view, and the WebContent process behind it — with a fresh unloaded view put in its
    /// place, so every `tab.web.…` call site elsewhere still has a real object to talk to
    /// and none of them costs a process.
    ///
    /// Split out of `suspend()` for `tearDown()`, which has to let go whatever the state of
    /// the tab: `suspend()` parks a page and so bails when there is no page to park, and
    /// "nothing was parked" must never mean "nothing was released".
    private func release() {
        let old = web
        TabAudio.unwatch(self)         // KVO on a dead observee is a crash, not a leak
        obs = []                       // KVO on a view that is about to die
        old.stopLoading()
        old.uiDelegate = nil
        old.navigationDelegate = nil
        old.configuration.userContentController.removeScriptMessageHandler(
            forName: "vanepw", contentWorld: Autofill.world)
        old.configuration.userContentController.removeScriptMessageHandler(forName: Previews.messageName)
        old.configuration.userContentController.removeScriptMessageHandler(
            forName: PictureInPicture.messageName, contentWorld: PictureInPicture.world)
        old.configuration.userContentController.removeScriptMessageHandler(forName: TabAudio.messageName)
        old.configuration.userContentController.removeScriptMessageHandler(forName: MediaTray.messageName)
        old.configuration.userContentController.removeScriptMessageHandler(forName: StatusBar.messageName)
        old.configuration.userContentController.removeScriptMessageHandler(
            forName: PageFocus.messageName, contentWorld: PageFocus.world)
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
        if web.url == nil, let parkedURL { go(parkedURL) }
        parkedState = nil
        parkedURL = nil
        // interactionState restores a page without running a navigation, so didCommit
        // never fires for a waking tab.
        Zoom.apply(to: self)
    }

    /// The window holding this tab is closing. `release` is what drops the KVO observers,
    /// the script message handlers and the WebContent process; without it `TabAudio`'s
    /// observer outlives the web view it was watching — a crash, not a leak — the process
    /// is never given back, and a page handed to another window carries on playing sound
    /// from a window nobody can see any more.
    ///
    /// `release` and not `suspend`: suspension is about *parking* a page, so it declines a
    /// tab with nothing to park — one already suspended, one that never loaded — and a
    /// closing window has to be let go either way. This is the path a Little Vane takes when
    /// its popup calls `window.close()`: `closedByScript` → `performClose` →
    /// `windowWillClose` → here, and a `suspend()` that decided there was nothing to do left
    /// that popup's WebContent process running for the life of the app.
    func tearDown() {
        release()
        TabAudio.forget(id)
        MediaState.shared.forget(id)
    }

    /// Come up already suspended, so restoring thirty tabs costs one WebContent process
    /// instead of thirty. The strip still has a title and a favicon.
    func park(url: URL, _ p: Parked) {
        parkedURL = url
        parkedState = p.state
        suspended = true
        // A tab that comes up from disk parked has a page — that is what parked means — and
        // it has one before it has ever run a navigation. Without this the very first × on a
        // restored pinned row, pressed in the gap after it was clicked awake, unpinned it.
        hasEverLoaded = true
        // A row that comes up from disk, and one a live folder makes, is at home by
        // definition: the url in the saved list *is* the page it stands for. A row that
        // already has one keeps it — going home parks at the home url, and parking a
        // wandered row in place must never move its home to where it wandered.
        if stays, homeURL == nil { homeURL = url }
        // A row nothing remembers a title for used to come up called "New Tab", and a
        // wandered pinned row is now exactly that row: what is written down for it is its
        // home, while the sidecar of titles and scroll offsets is keyed by the page it was
        // left on. So it gets the same name the × gives one it sends home — what history
        // calls that page, else its host. Never worse than "New Tab", and the page replaces
        // it the moment it loads.
        title = TabStore.homeTitle(known: p.title.isEmpty ? history.title(for: url) : p.title,
                                   url: url)
        address = url.absoluteString
        favicon = favicons.icon(for: url)      // from the cache, no page needed
    }


    /// Load it now, or park it if we know enough about it to draw it without loading.
    func open(_ url: URL, parked p: Parked?) {
        if let p, Prefs.suspendTabs { park(url: url, p) } else { go(url) }
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
        // Picture in picture is off by default in WKWebView on macOS — measured: the key is
        // there and reads false, and with it false `webkitSetPresentationMode` is a silent
        // no-op, which is why both the ⌥⌘P toggle and auto-PiP did nothing. The public
        // property is iOS-only (`allowsPictureInPictureMediaPlayback` on the configuration),
        // so this is KVC on the same preference Safari sets.
        // ponytail: KVC on a documented-by-name preference, exactly like developerExtrasEnabled
        // below. If the key ever goes away this throws nothing and PiP simply stays off.
        cfg.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
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

    /// One saved login fills straight in, the way it always has. Several put the list under
    /// the username field and wait — guessing which of your two accounts you meant is worse
    /// than asking, and it is what Arc does.
    ///
    /// Names only until something is chosen: deciding *whether* to ask decrypts nothing.
    func fillPassword(announcing: Bool = false) {
        guard let host = secureHost else {
            if announcing { axAnnounce("No saved password for this page.") }
            return
        }
        let hits = Passwords.matches(host: host, profileID: profileID)
        guard hits.count > 1 else {
            if let one = hits.first {
                fill(one)
            } else if announcing {
                axAnnounce("No saved password for \(host).")
            }
            return
        }
        web.evaluateJavaScript("window.__vaneAnchor && window.__vaneAnchor()",
                               in: nil, in: Autofill.world) { [weak self] result in
            guard case let .success(value) = result, let raw = value as? String,
                  let json = raw.data(using: .utf8),
                  let rect = try? JSONSerialization.jsonObject(with: json) as? [String: Double]
            else { return }
            self?.openChooser(host: host, accounts: hits.map(\.account), at: rect)
        }
    }

    /// Fills both fields and remembers the choice, so this account leads the list next time.
    /// The password is read here and nowhere else, and lives exactly as long as the call.
    func fill(_ login: Passwords.Login) {
        closeChooser(.filled)
        lastFilledAt = .now
        guard let password = Passwords.password(host: login.host, account: login.account,
                                                profileID: profileID) else { return }
        Passwords.recordUse(host: login.host, account: login.account, profileID: profileID)
        web.evaluateJavaScript(Autofill.fillJS(account: login.account, password: password),
                               in: nil, in: Autofill.world) { result in
            // The script says whether it found a form. Silence on a page with no sign-in
            // form is indistinguishable from a fill that went somewhere invisible.
            guard case let .success(value) = result, (value as? Bool) == false else { return }
            Task { @MainActor in axAnnounce("No sign-in form on this page.") }
        }
    }

    /// The chooser's row action. It carries its own host and account rather than reading
    /// `passwordChoice`, because by the time a click completes the list may already be gone:
    /// the mouse-*down* takes first responder off the web view, the page reports that as a
    /// blur, and the blur is a dismiss. Reading the state here lost every click.
    func fillChosen(host: String, account: String) {
        guard let hit = Passwords.matches(host: host, profileID: profileID)
            .first(where: { $0.account == account })
        else { closeChooser(.filled); return }
        fill(hit)
    }

    /// Whether the pointer is over the list. Set by the view; read by `closeChooser` for the
    /// one blur that must not close it — the one caused by pressing a row.
    var chooserHovered = false

    /// Everything that closes the list goes through here, so the rule lives in exactly one
    /// place — `PasswordChooser.opens` — and cannot drift between the page's events, the
    /// window's, and the keyboard's.
    func closeChooser(_ event: ChooserEvent) {
        guard passwordChoice != nil,
              !PasswordChooser.opens(event,
                                     sinceFill: Date.now.timeIntervalSince(lastFilledAt),
                                     pointerInside: chooserHovered)
        else { return }
        passwordChoice = nil
    }

    /// `{x, y, w}` in CSS pixels under the username field, scaled by the page zoom into the
    /// web view's own coordinates; `PasswordChooser.place` then keeps it inside the pane.
    /// ponytail: the anchor is read once, when the list opens — nothing tracks the element
    /// after that, which is why every scroll, blur and click closes the list instead.
    private func openChooser(host: String, accounts: [String], at r: [String: Double]) {
        guard PasswordChooser.opens(.focus, sinceFill: Date.now.timeIntervalSince(lastFilledAt)),
              let x = r["x"], let y = r["y"], let w = r["w"] else { return }
        let z = web.pageZoom
        let anchor = CGRect(x: x * z, y: y * z, width: w * z, height: 0)
        // Open only if it would actually be on the page. `place` refuses an anchor outside
        // the viewport, and a list that is "open" but drawn nowhere is worse than no list at
        // all: the keyboard handler still swallows the arrows and Return still fills, with
        // nothing on screen to say why.
        guard PasswordChooser.place(anchor: anchor, in: web.bounds.size,
                                    height: PasswordChooser.height(rows: accounts.count)) != nil
        else { return }
        passwordChoice = PasswordChoice(host: host, accounts: accounts, anchor: anchor)
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Previews.shared.cancel()      // the link that raised it is gone
        // Whatever was focused belongs to the page being left, frames and all; the incoming
        // one says so itself as soon as its script runs in each of them.
        editableFrames = []
        closeChooser(.navigate)       // …and so is the form the account list was anchored to
        loading = true
        hasEverLoaded = true          // whatever it turns out to be, this tab has a page now
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
    func show(_ error: Error, in w: WKWebView) {
        guard ErrorPage.shouldShow(error) else {
            // Nothing to draw and nothing coming: the navigation was cancelled — by a
            // download, by a policy decision — and a Peek opened for it would sit there as
            // an empty card with no way to know it was finished. See Peek.swift.
            Peek.dismissIfBlank(self)
            return
        }
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
    func webView(_ w: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
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
        closeChooser(.navigate)       // a redirect lands here without a fresh provisional
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
        // Vane's own scheme, before anything else: `vane://oauth/github` is where GitHub
        // sends the answer to a live folder's sign-in, and this is the only place in the
        // system that ever reads one. Cancelled unconditionally, whatever the rest of the
        // url says — WebKit has no loader for it, macOS has no handler for it because the
        // bundle deliberately declares none, and a page that redirects to `vane://anything`
        // gets nothing back at all.
        //
        // Cancelled here, answered only there: `finish` acts on the main frame of the one
        // tab the consent page was opened in and drops every other `vane:` navigation
        // without a trace — see `LiveFolders.accepts`. An iframe on an unrelated page
        // setting `location = "vane://oauth/github?error=x"` must not be able to cancel a
        // sign-in the user is in the middle of in another tab, or to learn from a toast or
        // a closing tab that there was one.
        if let url = navigationAction.request.url, ExternalApps.isOwn(url.scheme) {
            decisionHandler(.cancel)
            LiveFolders.shared(for: profileID)
                .finish(redirect: url, in: self,
                        isMainFrame: navigationAction.targetFrame?.isMainFrame == true)
            return
        }
        // A link to another app — zoommtg:, msteams:, mailto:, tel: — is not something
        // WebKit has a loader for: allowing it failed the navigation with "unsupported URL"
        // and the click looked like it did nothing at all. So it is cancelled and asked
        // about instead. Early, because the question is the same wherever the navigation
        // came from and whatever else it also is: the main frame, an iframe, a `location =`
        // redirect, a ⌘-click that would otherwise open a tab that cannot load, or a
        // target=_blank on its way to `createWebViewWith`.
        //
        // `w.url` is the site the card names — the page the link is on. Deliberately not
        // the link's own host: a `zoommtg:` url's host is part of the meeting address, not
        // a site anything can be granted to. ponytail: a url typed straight into the
        // address bar is credited to the page it is replacing, since the source frame is
        // that page either way. Ceiling: the card names the site you were on.
        if let url = navigationAction.request.url, ExternalApps.isExternal(url.scheme) {
            decisionHandler(.cancel)
            ExternalApps.offer(url, from: w.url ?? currentURL, tab: self)
            return
        }
        // ⌘-click, ⇧⌘-click and middle-click are a request for a tab, and ⌥⌘-click one for a
        // Little Arc — not for this page to go somewhere. Before HTTPS-only, because the new
        // tab or window does its own load and gets its own vetting.
        // A Little Arc needs no `onOpenBeside`: it is a window of its own, so the gesture
        // works from inside a Little Arc and a Peek as well as from a browser window.
        if let intent = TabActions.intent(for: navigationAction),
           let url = navigationAction.request.url {
            // Main frame only, for the reason the Peek branch below spells out: cancelling
            // a subframe's navigation would float an ad's destination out of the box it
            // belongs in, and `target=_blank` is already on its way to `createWebViewWith`.
            if intent.little, navigationAction.targetFrame?.isMainFrame == true {
                decisionHandler(.cancel)
                // The window this page came out of decides whether the Little Arc is
                // private — a page lifted out of a Private Window must not start writing
                // itself into history.
                LittleArc.open(url, isPrivate: isPrivate)
                return
            }
            if let open = onOpenBeside {
                decisionHandler(.cancel)
                open(url, intent.focus)
                return
            }
        }
        // Where a clicked link opens: over the window, in a tab of its own, or right here.
        // A link out of a favourite or a pinned tab that leads somewhere else does not take
        // that tab off the site it is kept on — ⇧ picks the other answer in either
        // direction. Before HTTPS-only, which vets whichever page actually loads. The table
        // and the reasoning are in Peek.swift.
        //
        // Only a navigation of the *main* frame. `targetFrame` is nil for `target=_blank`,
        // which WebKit is about to hand to `createWebViewWith` and `onOpenBeside` — Arc
        // opens those beside the tab, not in a Peek — and it is a subframe for a link
        // inside an iframe, which cancelling would have peeked an ad's destination over the
        // whole window instead of loading it in the box it belongs to.
        //
        // `from` is the frame that fired the click rather than `w.url`, which a navigation
        // already in flight may have moved on; a subframe aiming at the top is judged
        // against the page it is replacing, since the tab's site is what "the place you
        // keep" means, not the embed's.
        //
        // `onPeek` is nil in a window with nowhere to float one — a Little Arc, a Peek — and
        // gates the whole table, not just the peeking half: a floating one-page window has no
        // sidebar for the other answer to put a tab in either, so its links keep navigating.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, let peek = onPeek {
            let source = navigationAction.sourceFrame
            let from = (source.isMainFrame ? source.request.url : nil) ?? w.url ?? url
            switch Peek.route(sourceKind: kind, from: from, to: url,
                              modifiers: navigationAction.modifierFlags,
                              enabled: Prefs.peekLinks) {
            case .peek:
                decisionHandler(.cancel)
                peek(url)
                return
            // The link asked for a tab instead: ⇧-clicked out of a place you keep, or the
            // preference is off and this tab is still not going to be taken off its site.
            //
            // Cancelled first and unconditionally. A window with a sidebar always has an
            // `onOpenBeside` — `newBlankTab` sets one on every tab it makes — but "unless it
            // doesn't, in which case navigate here" is exactly the fallback this whole change
            // exists to remove: it would put the favourite on the page in the one case
            // nobody tests.
            case .newTab(let focus):
                decisionHandler(.cancel)
                onOpenBeside?(url, focus)
                return
            case .navigate:
                break
            }
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
        Peek.dismissIfBlank(self)      // a Peek opened for a download has no page to show
    }

    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        TidyDownloads.remember(download, pageTitle: w.title)   // the page title only exists here
        Downloads.manager(for: profileID).attach(download)
        Peek.dismissIfBlank(self)
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
        if m.name == MediaTray.messageName {
            MediaState.shared.handle(m.body, for: self, from: m.frameInfo)
            return
        }
        if m.name == StatusBar.messageName { hoveredLink = StatusBar.link(from: m.body); return }
        if m.name == PageFocus.messageName {
            editableFrames = PageFocus.frames(m.body, in: editableFrames)
            return
        }
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
        guard let body = m.body as? [String: Any] else { return }
        // The page saying the list is no longer wanted: a blur, a click elsewhere, a scroll,
        // or a history move inside a single-page app.
        if let why = body["dismiss"] as? String {
            closeChooser(ChooserEvent(page: why))
            return
        }
        // The username field was focused. Nothing happens unless this site has more than one
        // saved login — one still fills from the menu command, silently. Names only: nothing
        // is decrypted to answer "is there a choice here".
        if body["focus"] as? Bool == true {
            guard let host = secureHost else { return }
            let hits = Passwords.matches(host: host, profileID: profileID)
            guard hits.count > 1 else { return }
            openChooser(host: host, accounts: hits.map(\.account),
                        at: body.compactMapValues { $0 as? Double })
            return
        }
        guard let password = body["password"] as? String, !password.isEmpty,
              let host = secureHost else { return }
        // A private window is a window that leaves nothing behind, and an offer the user
        // says yes to on autopilot leaves the most personal thing there is.
        guard !isPrivate, !Passwords.isNeverSaved(host: host, profileID: profileID) else { return }
        let account = (body["account"] as? String) ?? ""
        // Already stored and unchanged — nothing to ask about. Only the account being
        // submitted is decrypted, and only to answer that one question.
        let stored = Passwords.password(host: host, account: account, profileID: profileID)
        if stored == password { return }
        pendingSave = PendingSave(host: host, account: account, password: password,
                                  update: stored != nil)
    }

    func confirmSave() {
        guard let p = pendingSave else { return }
        let stored = Passwords.save(host: p.host, account: p.account, password: p.password,
                                    profileID: profileID)
        axAnnounce(stored ? (p.update ? "Password updated." : "Password saved.")
                          : PasswordsPane.saveFailed(host: p.host))
        pendingSave = nil
    }

    /// "Never for this site". Saying no once is a decision about this password; saying never
    /// is a decision about the site, so it is the only one of the two that is remembered.
    func neverSaveHere() {
        guard let p = pendingSave else { return }
        Passwords.neverSave(host: p.host, profileID: profileID)
        axAnnounce("Vane will not offer to save passwords for \(p.host).")
        pendingSave = nil
    }

    /// ↑↓ in the account list. Wraps, the way every menu-shaped popup on the Mac does.
    func moveChoice(_ delta: Int) {
        guard let choice = passwordChoice else { return }
        passwordChoice?.selected = PasswordChooser.step(choice.selected, by: delta,
                                                        of: choice.accounts.count)
    }

    /// Return in the account list.
    func fillSelected() {
        guard let choice = passwordChoice,
              choice.accounts.indices.contains(choice.selected) else { return }
        fillChosen(host: choice.host, account: choice.accounts[choice.selected])
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

    /// `target="_blank"` and `window.open` — a tab beside this one, or a Little Vane for a
    /// popup that asked to be one. See Popups.swift for which, and why.
    ///
    /// The web view handed back is built from `cfg`, WebKit's own configuration for this
    /// popup, and it is handed back *unloaded*: WebKit navigates it itself. Vane used to
    /// open a plain tab on `action.request.url` and return nil, which is three bugs in one
    /// line — no `window.opener` for the popup to postMessage a credential back over, a
    /// blank page for any popup opened empty and written into afterwards, and a
    /// `window.close()` that did nothing.
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // `window.open('zoommtg:…')`. Belt and braces around the same test in
        // `decidePolicyFor` — a popup opened with no url and navigated afterwards arrives
        // here first — and a new tab for a scheme no tab can load is worse than no tab.
        if let url = action.request.url, ExternalApps.isExternal(url.scheme) {
            ExternalApps.offer(url, from: w.url ?? currentURL, tab: self)
            return nil
        }
        return onPopup?(cfg, Popup.placement(features: windowFeatures,
                                             userInitiated: Popup.userInitiated(action),
                                             background: action.modifierFlags.contains(.command)))
    }

    /// `window.close()`, which a page may only call on a window a script opened — so this
    /// arrives for a popup and for nothing else. Arc dismisses it, and so does this: an
    /// OAuth popup that has handed its credential back and closed itself must not be left
    /// sitting in the sidebar for the user to tidy up.
    func webViewDidClose(_ w: WKWebView) { onClose?() }
}

/// One Space's tabs, kept alive while the window is showing a different one. Arc does not
/// offload a Space when you swipe off it — the pages stay loaded and swiping back shows them
/// exactly as they were — so leaving a Space moves its strip in here instead of tearing it
/// down and opening every url again on the way back. See `TabStore.switchTo(space:)`.
///
/// ponytail: one dictionary of these per window, not a second `TabStore` per Space. Ceiling:
/// every Space a window has visited holds its pages until the window closes, which is the
/// point — the ordinary idle sweep is what stops that being a memory hole, because
/// `Suspension` and `Archive` are handed `everyTab` rather than `tabs`.
///
/// Every tab in here is suspendable, pinned rows included: the pin exemption in
/// `Suspension.shouldSuspend` is about the row you can click, and a stash has no rows. So a
/// kept-alive Space unloads on the ordinary idle clock and gives everything back under
/// memory pressure, and what it holds meanwhile is the pages, not the processes. Only
/// auto-archive keeps its distance — Today tabs go past their day in here as they do
/// anywhere, pinned rows never do.
struct Stash {
    /// The non-favourite tabs, in strip order: the Pinned rows, then Today's.
    var tabs: [Tab]
    /// The two sections' folders, the splits, and the tab the Space was left on — everything
    /// `switchTo` would otherwise have to rebuild from disk.
    var pins: Pins
    var todayShape: Pins
    var splits: [Split]
    var current: Tab.ID?
    /// What `saveCurrentSpace` had just written for this Space, read back off the disk. It is
    /// checked again on the way in: anything that edited the Space from somewhere else — Move
    /// to Space, a Library edit, another window saving it — moves this on, and a stash that no
    /// longer describes what is on disk is thrown away rather than drawn over the top of it.
    var fingerprint: String

    /// Which tabs leave the strip when a window leaves a Space: everything that is not a
    /// favourite, in the order they were drawn. The grid is the profile's and is in every
    /// Space, so it does not so much as blink on a switch.
    ///
    /// Pure, over kinds, so `selfcheck --pure` can prove that without a `Tab`.
    nonisolated static func leaving<T>(_ strip: [(id: T, kind: TabKind)]) -> [T] {
        strip.filter { $0.kind != .favourite }.map(\.id)
    }

    /// And the strip a Space comes back as: the favourites that never left, then the tabs
    /// that did. The sections are contiguous runs in favourite–pinned–Today order (see
    /// `clampedDestination`), so putting the stash back on the end is all it takes.
    nonisolated static func entering<T>(_ strip: [(id: T, kind: TabKind)], stashed: [T]) -> [T] {
        strip.filter { $0.kind == .favourite }.map(\.id) + stashed
    }

    /// One tab leaves while its Space is put away — the auto-archive sweep is the only thing
    /// that reaches in here. It goes out of the order, out of both folder shapes, and out of
    /// whatever split it was a pane of; a split down to one pane stops being a split, exactly
    /// as `dropPane` decides it on screen.
    @MainActor mutating func remove(_ id: Tab.ID) -> Tab? {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: i)
        pins.remove(tab: id.uuidString)
        todayShape.remove(tab: id.uuidString)
        todayShape.removeEmptyFolders()
        if let j = splits.firstIndex(where: { $0.contains(id) }) {
            if let shrunk = splits[j].removing(id) { splits[j] = shrunk } else { splits.remove(at: j) }
        }
        if current == id { current = nil }
        return tab
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
    /// Arc's multi-select: which rows are ticked, and which section they are in. Per window,
    /// like the sidebar itself. See Selection.swift — everything done with it is there.
    @Published var selection = Selection()
    /// Arc's Folders: the shape of the Pinned section — which tabs sit in which folder, and
    /// the order the rows are drawn in. `tabs` still holds the tabs themselves; this only
    /// says how they are arranged. See `Pins` in Folders.swift.
    @Published var pins = Pins()
    /// The same, for Today — which is where a tidy's folders go. A second instance of the
    /// same value rather than a section field on every row, so a tab in a folder here stays
    /// an ordinary Today tab: it keeps auto-archiving, ⌘W archives it, and Clear takes it.
    /// See `TabStore.shape(of:)`, which is what tells the shared rows which one they are on.
    @Published var todayShape = Pins()
    /// The folder whose row is a name field right now, the way `renamingTab` is for a tab.
    @Published var renamingFolder: UUID? {
        didSet { if renamingFolder != nil { renamingTab = nil } }
    }
    /// The live folder whose "Live Folder Created" callout is up. Per window, like the
    /// command bar: the folder was made by a click in this one, and a second window showing
    /// the same Space is not where anybody is looking. See `LiveFolderCallout`.
    @Published var announcing: UUID?
    /// The window's split views: 2–4 of the tabs above shown side by side in one page card
    /// and as one sidebar row. Ids, not tabs, so a split survives its panes moving section,
    /// being renamed or being suspended. Everything done to them is in SplitView.swift.
    @Published var splits: [Split] = []
    /// Counts the archives that land in one burst, so Clear can sweep rows out one after
    /// another. See `archive`.
    private let bursts = Motion.Burst()
    @Published var current: Tab.ID? {
        didSet {
            // Selecting a tab is what wakes it, and it has to happen here rather than in a
            // Task: SwiftUI reads `tab.web` on this same turn of the run loop.
            if let t = tabs.first(where: { $0.id == current }) { t.lastActive = .now; t.resume() }
            // The tab being left behind starts its idle clock now, not when it was opened.
            if let old = tabs.first(where: { $0.id == oldValue }) {
                old.lastActive = .now
                old.closeChooser(.tabSwitch)   // a list anchored to a page nobody is looking at
            }
            // Selecting a pane by any route at all — ⌘1–9, ⌃⇥, ⌥⌘↑↓, a favourite tile, the
            // command bar — is what the split means by "the active pane". Keeping it here
            // rather than in each of those callers is the only way the two cannot drift.
            if let id = current, let i = splits.firstIndex(where: { $0.contains(id) }) {
                splits[i] = splits[i].focusing(id)
            }
            // Arc's auto picture-in-picture: the video in the tab you left follows you out,
            // and goes back into the page when you come back to it.
            if oldValue != current {
                PictureInPicture.enterIfPlaying(tabs.first { $0.id == oldValue })
                PictureInPicture.exitIfAuto(tabs.first { $0.id == current })
            }
            extensions.sync()
        }
    }
    /// Per window: hiding the sidebar in one window must not hide it in the next.
    @Published var sidebarShown = true
    /// The command bar. Set to open it in a mode, nil to close. Per window: two windows can
    /// each have their own open. `.address` is what ⌘L, ⌘T and clicking the address pill
    /// open — the place to type a url or a search.
    @Published var palette: PaletteMode?
    /// “Open “Zoom”?” — a link in this window that leads out of the browser, waiting for
    /// an answer. Per window, like the command bar: the card is anchored to the page that
    /// asked, so a background window’s `zoommtg:` link cannot put a sheet over whatever is
    /// being read in front. See ExternalApps.swift.
    @Published var externalApp: ExternalApps.Prompt?
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
        // Favourites are the one thing every Space shares, so they come from the profile
        // whether this window is in a Space or not. `Spaces.favourites` also folds any
        // per-space grid an older spaces.json still carries into that one list.
        // A Little Arc has no sidebar to put either section in, and nothing it does may
        // move the profile's grid — so it starts with the one page it was handed.
        let favourites = isPrivate || isLittle ? [] : Spaces.favourites(for: profileID)
        // Pinned rows belong to the Space, full stop: a browser window always has one, and a
        // Little Arc or a private window has neither a Space nor rows to restore.
        let pinned = space?.pinnedTabURLs ?? []
        // A space carries its own per-tab state in a sidecar; a window restore is handed one.
        // Merged rather than swapped, the sidecar winning: on the launch that migrates a
        // profile into its first Space there is no sidecar yet, and the session's own titles
        // and scroll offsets are all there is.
        let parked = space.map {
            Suspension.SpaceState.load(space: $0.id, profileID: profileID, in: Store.directory)
                .merging(parked) { sidecar, _ in sidecar }
        } ?? parked
        restore(favourites, as: .favourite, parked: parked)
        // The Pinned section is not a list any more but a shape — folders and the tabs in
        // them — so its tabs come up in the order the folders draw them.
        restorePins(urls: pinned, parked: parked)
        let kept = Set(favourites + pinned)
        let rest = urls.filter { !kept.contains($0) }
        // Today is a shape too — its folders are where a tidy puts its groups — so the tabs
        // are collected on the way past and handed the shape the Space was left in.
        adoptTodayShape(tabs: rest.map { url in
            let t = newBlankTab()
            t.open(url, parked: parked[url.absoluteString])
            // Named by the url it was opened with, not the one it has: with suspension off
            // `open` hands it straight to `go` and there is no `currentURL` yet.
            return (url: url, tab: t)
        })
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

    /// Just the id, for a caller that already has the profile's Spaces in hand —
    /// `Spaces.resolve`, which would otherwise re-read spaces.json to hand one straight back.
    nonisolated static func lastSpaceID(for profileID: UUID,
                                        defaults: UserDefaults = .vane) -> UUID? {
        defaults.string(forKey: lastSpaceKey(profileID)).flatMap(UUID.init(uuidString:))
    }

    static func lastSpace(for profileID: UUID) -> Space? {
        guard let id = lastSpaceID(for: profileID) else { return nil }
        return ProfileManager.shared.spaces(for: profileID).first { $0.id == id }
    }

    private func rememberSpace() {
        // A Little Arc is in no Space, and must not be read as "the user left this profile
        // outside every Space" — that would clear the Space the next window comes up in.
        guard !isPrivate, !isLittle else { return }
        let key = TabStore.lastSpaceKey(profileID)
        if let id = currentSpaceID {
            UserDefaults.vane.set(id.uuidString, forKey: key)
        } else {
            UserDefaults.vane.removeObject(forKey: key)
        }
    }

    /// One section's tabs, in order, all parked. Never loaded eagerly whatever
    /// `Prefs.suspendTabs` says: a favourite tile or a pinned row is a place to go, and
    /// eight of them at launch are eight processes for pages nobody is looking at.
    /// `parked` may carry the state each one was last on.
    @discardableResult
    func restore(_ urls: [URL], as kind: TabKind, parked: [String: Parked]) -> [Tab] {
        // Unfocused, and into its own run of the strip: `newBlankTab` has both now, and a
        // restore wants both. Every caller sets `current` itself, once, when the strip is
        // built — being walked through thirty pages on the way there was only ever noise.
        urls.map { url in
            let t = newBlankTab(focus: false, as: kind)
            t.park(url: url, parked[url.absoluteString] ?? Parked())
            return t
        }
    }

    var active: Tab? { tabs.first { $0.id == current } }
    /// What the card is drawing: the active tab, or every pane of its split.
    var onScreenTabs: [Tab] {
        let ids = activeSplit?.tabs ?? [current].compactMap { $0 }
        return ids.compactMap { id in tabs.first { $0.id == id } }
    }

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
        if isLittle { LittleArc.open(url, isPrivate: isPrivate); return }
        if let url {
            newBlankTab().go(url)
        } else {
            openPalette(.newTab)
        }
    }

    /// ⌘T, ⌘L and the pill: opening the bar over a bar that is already up closes it instead
    /// (Arc v0.107). `Palette.toggled` is where that decision is written down.
    func openPalette(_ mode: PaletteMode) {
        palette = Palette.toggled(current: palette, pressed: mode)
        // ⌘L over an open bar closes it, and the page has to get the keyboard back with it.
        if palette == nil { focusPage() }
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

    /// `focus` and `as` are for the one caller that is not the user: a live folder filling
    /// itself. Every other caller takes the defaults and behaves exactly as before — a Today
    /// tab at the end of the strip, shown.
    ///
    /// Focus is a parameter rather than something to undo afterwards because `current`'s
    /// `didSet` is not a no-op: it dismisses the old tab's password chooser and pops a
    /// playing video out of Picture in Picture. Setting it and setting it back still does
    /// both, and a folder refreshing in the background must do neither.
    @discardableResult
    func newBlankTab(focus: Bool = true, as kind: TabKind = .today) -> Tab {
        let t = Tab(isPrivate: isPrivate, profileID: profileID)
        wire(t)
        t.kind = kind
        // Into its own section, not onto the end of the strip: the sections are contiguous
        // runs (see `clampedDestination`), and a pinned row appended past the Today tabs
        // breaks ⌘1…9, ⌃⇥ and the next drag's clamp.
        Motion.list {
            tabs.insert(t, at: TabStore.clampedDestination(others: tabs.map(\.kind),
                                                           moving: kind, to: tabs.count))
            // Today is drawn from its shape, so a tab the shape has never heard of would be
            // a row nothing draws. `sync` takes it in at the end of the section — which is
            // where the strip has just put it, and outside every folder.
            syncShapes()
        }
        if focus { current = t.id }
        extensions.sync()
        return t
    }

    /// Everything a tab asks its window for. Split out of `newBlankTab` because one tab is
    /// not made here at all: a popup, whose web view WebKit builds and hands to the
    /// delegate. It needs exactly the same wiring, and a second copy of this list is how
    /// popups would quietly stop peeking, or stop opening beside, a release later.
    func wire(_ t: Tab) {
        t.onNewTab = { [weak self] u in self?.newTab(u) }
        // A popup or a `target=_blank` link belongs next to the page that opened it, not at
        // the bottom of a list of thirty tabs — and it is what the user just asked for, so
        // it takes focus where a ⌘-click does not. Out of a Little Arc there is no list to
        // be beside, and a page that escaped into the sidebar is not what was clicked.
        t.onOpenBeside = { [weak self] u, focus in
            guard let self else { return }
            if isLittle { LittleArc.open(u, isPrivate: isPrivate) } else { openBeside(u, focus: focus) }
        }
        // A Peek floats over a window with a sidebar in it. A Little Arc — or a Peek itself —
        // is already one floating page, so a link in it has nothing to float over and simply
        // navigates.
        if !isLittle {
            t.onPeek = { [weak self, weak t] u in
                guard let self, let t else { return }
                Peek.open(u, from: t, in: self)
            }
        }
        // `window.open` and `target=_blank`: WebKit's own web view, put in a window of
        // Vane's choosing. See Popups.swift.
        t.onPopup = { [weak self, weak t] cfg, placement in
            guard let self else { return nil }
            return popup(cfg, placement: placement, opener: t?.id)
        }
        // `window.close()`. Deferred a turn: WebKit is inside this web view's own delegate
        // call, and closing the tab drops the view — freeing it under the frame that is
        // still running is how a page that closes itself becomes a crash report.
        t.onClose = { [weak self, weak t] in
            guard let self, let t else { return }
            let id = t.id
            Task { @MainActor [weak self] in self?.closedByScript(id) }
        }
    }

    /// Close a tab — or, for a favourite, close its *page*: the tile stays, parked back at
    /// its home url, and only Unpin ever takes it out of the grid. Closing the last tab
    /// leaves an empty window, not no window: the sidebar stays and the page area shows the
    /// glass, the way Arc's does.
    /// ⌘W, and what the auto-archive sweep does: remember the page so it can be brought
    /// back from the Library, then close it. A favourite or a pinned tab is written down
    /// already and stays exactly where it is — `close` parks it — so nothing is archived
    /// for it either; that is the whole difference between the sections.
    ///
    /// `asPane` is a caller that knows this tab is a pane even when `splits` no longer says
    /// so — see `closeSplit`, which takes a whole split down one tab at a time and so asks
    /// for the last one after the split has already collapsed under it.
    func archive(_ id: Tab.ID, asPane: Bool = false) {
        // Several archives in one synchronous burst — Clear, Archive Tabs Below, the
        // auto-archive sweep — leave one after another, the way Arc sweeps Today away,
        // rather than all in the same frame. A lone ⌘W is a burst of one and goes at once.
        let delay = Motion.sweepDelay(bursts.next(), reduced: Motion.reduced)
        guard delay > 0 else { archiveNow(id, asPane: asPane); return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.archiveNow(id, asPane: asPane)   // a no-op if the tab has gone meanwhile
        }
    }

    private func archiveNow(_ id: Tab.ID, asPane: Bool = false) {
        // Not only the strip: the auto-archive sweep reaches a Space this window is keeping
        // alive behind the one it is showing, and a day-old tab in one is a day old.
        let stashed = space(stashing: id)
        guard let tab = everyTab.first(where: { $0.id == id }) else { return }
        if tab.kind == .today, !isPrivate, let u = tab.currentURL,
           u.scheme?.hasPrefix("http") == true {
            // The Space it was in and whether it was a Little Arc go down with it, so the
            // Library can put it back where it came from and filter on where it came from.
            Archive.shared(for: profileID).add(url: u, title: TidyTitles.title(for: tab),
                                               space: stashed ?? currentSpaceID, littleArc: isLittle)
        }
        // `close` works on the strip, and a stashed tab is not on it.
        //
        // ponytail: the Space's own url list on disk keeps the archived page until the next
        // `saveCurrentSpace`, which is also what the stash is checked against, so the two
        // stay in step. Ceiling: quitting in between brings the page back at the next launch.
        if let stashed { stashes[stashed]?.remove(id)?.tearDown() }
        else { close(id, asPane: asPane) }
    }

    /// A row in the Library's Archived Tabs list, clicked: open it again and take it out of
    /// the archive, because it is not archived any more. Arc v1.17: it goes back to the
    /// Space it was archived from, not to whichever Space this window happens to be showing.
    func unarchive(_ entry: Archive.Entry) {
        Archive.shared(for: profileID).remove(entry.id)
        guard let u = URL(string: entry.url) else { return }
        // A private window, a Little Arc, or a window that is in no Space has no Space to go
        // back to — and switching one that is in none would tear its Today tabs down without
        // anywhere to have saved them. The page simply opens here.
        guard !isPrivate, !isLittle, currentSpaceID != nil else { newTab(u); return }
        if let target = Library.restoreTarget(entry, spaces: spaces.map(\.id), current: currentSpaceID),
           target != currentSpaceID, let space = spaces.first(where: { $0.id == target }) {
            switchTo(space: space)
        }
        newTab(u)
    }

    /// Whether a tab that is going leaves its url behind on the ⇧⌘T stack.
    ///
    /// Three kinds of close leave no trace, for three different reasons. A favourite or a
    /// pinned tab is not closed at all — it is parked in place — so there is nothing to
    /// reopen. A private tab is never written down anywhere. And a popup that called
    /// `window.close()` on itself is the last frame of an OAuth flow: offering the user
    /// Reopen Closed Tab on a sign-in window they never chose to open would hand them back
    /// a dead redirect url. Pure, so `selfcheck --pure` can prove all three.
    nonisolated static func remembersClosed(keep: Bool, byScript: Bool, isPrivate: Bool) -> Bool {
        !keep && !byScript && !isPrivate
    }

    /// Put a row back on the page it stands for, and say whether it moved. The page it
    /// wandered to goes, and so does that wander's back/forward list — that is what makes
    /// this a *reset* rather than an unload, and it is why the `Parked` handed over carries
    /// no state. `suspend` first, and only then park: a park with a live web view still on
    /// the old page would leave `currentURL` reading that page. `suspend` declines a tab
    /// that is already parked, which is exactly the row this is most often called for.
    ///
    /// False for every row that has nowhere to go — a Today tab, one pinned while it was
    /// still blank, one already at home — which is the "park in place" every row did before.
    @discardableResult
    private func sendHome(_ tab: Tab) -> Bool {
        guard let home = TabStore.goesHome(home: tab.homeURL, at: tab.currentURL) else { return false }
        tab.suspend()
        tab.park(url: home, Parked(title: TabStore.homeTitle(
            known: tab.history.title(for: home), url: home)))
        return true
    }

    /// `byScript` is a popup dismissing itself — see `closedByScript`. Everything else about
    /// the close is the same; only the trace it leaves differs.
    ///
    /// `asPane` is the caller insisting this is a pane close whatever `splits` currently says
    /// — see `closeSplit` and `TabRowGlyph.isPane`.
    func close(_ id: Tab.ID, byScript: Bool = false, asPane: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        // A pinned row's × — and ⌘W on it — is a two-step, and this is the one place that
        // decides which step it is: the page goes first, the pin only after that. See
        // `TabRowGlyph`, which draws exactly this decision.
        //
        // A pane is asked first and is never a two-step: closing a pane is closing a *pane*,
        // whatever section the tab behind it is in, so it falls through to `dropPane` below.
        // Without that, ⌃⇧−, the split row's ×, its "Close Pane" action and Remove Split all
        // unloaded or unpinned a pinned pane and left it on screen — a split you could not
        // get out of.
        //
        // The two pinned cases return here rather than falling through on purpose, and that
        // is also the fix for the × that felt slow on a pinned tab: the old path kept the tab
        // and then reassigned `current` to the most recently used Today tab, and `current`'s
        // didSet *resumes* whatever it lands on — so one click on a pinned row's × swapped
        // the window's web view, woke a suspended tab and reloaded its page, all on the main
        // actor before the click returned. Unloading in place moves nothing and wakes
        // nothing.
        //
        // `tab.suspended` alone, and not "or it has no url": `resume` hands the web view a
        // load and clears `parkedURL` before `WKWebView.url` has caught up with it, so for
        // the width of that gap a tab that is very much alive has no url to show — and a ×
        // pressed right after clicking a parked pinned row read that as "nothing left to
        // unload" and took the pin off in one click.
        let asPaneClose = TabRowGlyph.isPane(inSplit: split(containing: id) != nil, forced: asPane)
        switch TabRowGlyph.decide(kind: tab.kind, suspended: tab.suspended,
                                  pane: asPaneClose, atHome: tab.atHome) {
        case .close:
            // The grid follows the same rule as the Pinned rows: a favourite's × parks the
            // tile back on the page it was favourited at rather than wherever it was left.
            // Not for a pane — a pane's × closes the pane — and it still falls through, so
            // the window hands over to a Today tab and the tile stops showing, which is
            // what closing a favourite has always done.
            if tab.stays, !asPaneClose { sendHome(tab) }
        case .unload:
            // Arc's rule: a pinned row remembers the url it was pinned at, and this press
            // puts it back there. It is the middle step of three — page → home → unpin.
            if sendHome(tab) { return }
            tab.suspend()
            // `suspend` parks a *page*, and a pinned row that has never been given one has
            // none to park — a press that did nothing at all would be worse than the second
            // step arriving early, so it takes the pin off instead. But "no page to park" is
            // also true for the width of the resume gap, where the tab has a page on its way
            // in, and unpinning *that* loses the row to a press that asked to unload. See
            // `Tab.hasEverLoaded`.
            if !tab.suspended,
               TabRowGlyph.unpinsWithNothingParked(hasEverLoaded: tab.hasEverLoaded) {
                unpin(id)
            }
            return
        case .unpin:
            unpin(id)
            return
        }
        let outcome = TabStore.closing(i, kinds: tabs.map(\.kind), lastActive: tabs.map(\.lastActive))
        // A favourite or a pinned tab is the same tab, only moved into its section: closing
        // it leaves it exactly as it is, and only Unfavourite/Unpin ever takes it out.
        // Nothing is "closed", so nothing is pushed for Reopen Closed Tab either.
        if !outcome.keep {
            if TabStore.remembersClosed(keep: outcome.keep, byScript: byScript,
                                        isPrivate: isPrivate) { ClosedTabs.push(tab.currentURL) }
            Motion.list { _ = tabs.remove(at: i) }
            TabAudio.forget(id)        // else the maps grow by one per tab ever opened
            pins.remove(tab: id.uuidString)      // a folder outlives the tabs that left it
            // A Today folder does not: it is a grouping of tabs that are still archiving
            // themselves, so the last one leaving — swept, closed or cleared — ends it.
            todayShape.remove(tab: id.uuidString)
            todayShape.removeEmptyFolders()
            MediaState.shared.forget(id)
            // Closing GitHub's consent page by hand is abandoning the sign-in: the next
            // "New Live Folder…" starts a fresh one rather than pointing at a tab that has
            // gone. A no-op for every other tab, which is nearly all of them — and
            // `existing`, not `shared`: a closing tab is no reason to make a live folders
            // instance for a profile that never signed in.
            LiveFolders.existing(for: profileID)?.forget(authTab: id)
        }
        if renamingTab == id { renamingTab = nil }
        // A selection may only ever name tabs that exist: one closed under it — by ⌘W, by a
        // bulk archive, by the auto-archive sweep — drops out of it here rather than
        // lingering as an id no row will ever be drawn for.
        selection.keep(tabs.map(\.id))
        extensions.sync()
        // A split loses a pane with the tab, and a split down to one pane is a plain tab
        // again. Its remaining pane is a better answer than "the neighbouring row": the user
        // is looking at the rest of the split, not at the list.
        let pane = dropPane(id)
        if current == id { current = pane ?? outcome.next.map { tabs[$0].id } }
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
    /// `nonisolated` for the same reason `pinOrder` is: it is index arithmetic over value
    /// types, and a live folder's rows landing in the wrong section is worth proving offline.
    nonisolated static func clampedDestination(others: [TabKind], moving: TabKind, to: Int) -> Int {
        let low = others.firstIndex { $0 >= moving } ?? others.count
        let high = others.lastIndex { $0 <= moving }.map { $0 + 1 } ?? 0
        return min(max(to, low), max(low, high))
    }

    /// The strip put back in section order, as a permutation of its indices: every favourite
    /// ahead of every pinned tab, every pinned tab ahead of every Today tab, and nothing
    /// moved *within* a section. `clampedDestination` keeps that invariant one move at a
    /// time; this is what restores it after a batch that was not each clamped — Tidy's undo
    /// puts a whole strip's order back at once, and a tab the user pinned by hand while the
    /// tidy was thinking is in it with a section the saved order knows nothing about.
    ///
    /// `nonisolated`, and over kinds rather than tabs, for the same reason
    /// `clampedDestination` is: it is arithmetic, and the invariant is worth proving offline.
    nonisolated static func sectionOrder(_ kinds: [TabKind]) -> [Int] {
        // Stable by hand: `sorted(by:)` is not, and a section whose rows shuffle whenever
        // this runs would be a worse bug than the one it fixes.
        kinds.indices.sorted { kinds[$0] == kinds[$1] ? $0 < $1 : kinds[$0] < kinds[$1] }
    }

    /// The same, applied. Cheap and a no-op on a strip that is already sorted, which is
    /// every strip every other route leaves behind.
    func normaliseSections() {
        let order = TabStore.sectionOrder(tabs.map(\.kind))
        guard order != Array(order.indices) else { return }
        tabs = order.map { tabs[$0] }
    }

    /// Move a tab into a section. It lands at the end of Favourites or Pinned — where Arc
    /// drops one — and at the head of Today, so an unpinned tab appears right under the
    /// New Tab row rather than at the bottom of a long list.
    ///
    /// It used to take a `batched` flag, for a caller moving a run of tabs at once and doing
    /// the write and the retitling itself at the end. The one caller was Tidy, which does not
    /// move tabs between sections any more — its folders are Today's — so the flag went with
    /// it rather than sitting here explaining a run that no longer happens.
    func move(_ id: Tab.ID, to kind: TabKind) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].kind != kind else { return }
        Motion.list {
            let tab = tabs.remove(at: i)
            setKind(tab, kind)
            let dest = TabStore.clampedDestination(others: tabs.map(\.kind), moving: kind,
                                                   to: kind == .today ? 0 : tabs.count)
            tabs.insert(tab, at: dest)
        }
        syncShapes()          // a tab leaving a section leaves its folder with it
        // The strip put it at the head of Today; `sync` takes a row it has not seen at the
        // *end*, so the shape is told the same thing — at the top, and in no folder, which
        // is where an un-pinned tab and one moved in from another Space both belong.
        if kind == .today { todayShape.put(id.uuidString, at: Pins.Spot(parent: nil, index: 0)) }
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

    /// The second half of a pinned row's ×: the pin comes off and the tab drops into Today.
    ///
    /// It says so, with an Undo, because it is one click and it is the *common* click — a
    /// pinned tab comes up from disk parked (see `park`), so the state the × meets most
    /// mornings is the one that unpins rather than the one that unloads. Losing the row you
    /// arranged, its folder and its place in it to a stray press on a glyph that looks like
    /// every other × in the app is not something to find out about afterwards.
    func unpin(_ id: Tab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        // Both halves of "where it was": this row's own place in the section — which folder
        // it sat in and how far down it — and the strip's order, because different parts of
        // the sidebar read each.
        //
        // One row's place, not a copy of the whole section: a snapshot of `pins` put back
        // wholesale would also take back the folder the user made, the row they dragged and
        // the folder they renamed while the toast was still up — and then write all of it to
        // disk. An undo undoes the thing it is offered for and nothing else.
        let spot = pins.spot(of: id.uuidString), order = tabs.map(\.id)
        togglePinned(id)
        Toasts.show("Unpinned", action: ("Undo", { [weak self] in
            self?.repin(id, spot: spot, order: order)
        }), in: self)
    }

    /// Undo, for the toast `unpin` puts up. A no-op if the tab has gone in the meantime, and
    /// tabs opened since keep their places — `TidyTabs.restore` is the same "put back exactly
    /// what is still here" the tidy's undo uses.
    private func repin(_ id: Tab.ID, spot: Pins.Spot?, order: [Tab.ID]) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        move(id, to: .pinned)          // which also `syncShapes`, so the row exists to place
        // Back in its folder at the index it had, and nothing else in the section touched.
        // A folder that has gone in the meantime takes the row to the end of the section
        // rather than dragging a deleted folder back with it — see `Pins.put`.
        if let spot { pins.put(id.uuidString, at: spot) }
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Motion.list {
            tabs = TidyTabs.restore(saved: order, current: tabs.map(\.id)).compactMap { byID[$0] }
            // The saved order names every tab that was on the strip when the pin came off,
            // in the sections they had then — so a tab the user pinned *while the toast was
            // up* goes back among the Today tabs it was sitting in, below every pinned row.
            // That breaks the one strip invariant, so the sections are settled again before
            // anything reads the strip. `TidyTabs.undo` does the same, for the same reason.
            normaliseSections()
            applyOrder(.pinned)
            // Today has just been handed a whole order at once, so there the shape follows
            // the strip rather than the strip following the shape. See `Pins.relay`.
            todayShape.relay(tabs.map(\.id.uuidString))
        }
        savePins()
        axAnnounce("Pinned again.")
    }

    /// A tab has changed section, and the row it draws is asked for a name again — a page
    /// with no title of its own reads differently as a chip than as a full row.
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
        Motion.list {
            let tab = tabs.remove(at: from)
            setKind(tab, want)
            let dest = TabStore.clampedDestination(
                others: tabs.map(\.kind), moving: want,
                to: TabStore.insertionIndex(from: from, target: to, after: after))
            tabs.insert(tab, at: min(dest, tabs.count))
        }
        placeInShape(id, onto: target, after: after)
        // Always. This used to skip the write for a drop that stayed inside Today, on the
        // grounds that nothing written down had changed; Today's order and its folders are
        // in the shape now, so a reorder there is exactly what has to be saved.
        savePins()
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

    /// Where the Favourites grid is written: UserDefaults, deliberately not session.json —
    /// the session is per-window and is rewritten by whichever window closed last, while
    /// the grid has to outlive all of them. Ceiling: one grid per profile, so favouriting
    /// in two windows at once means last writer wins.
    ///
    /// The default profile keeps the un-suffixed `pinnedTabs` key for its *favourites*: that
    /// key predates the split between Favourites and Pinned, and pointing it anywhere else
    /// would drop every existing user's grid on the floor for the sake of a tidier name.
    ///
    /// `.pinned` names the old `pinnedRows` key, which nothing writes any more: Pinned rows
    /// belong to a Space, and every browser window is in one. `ProfileManager.ensureSpaces`
    /// is the last reader — it migrates that key into the profile's first Space and deletes
    /// it. ponytail: the key name stays here rather than moving, so there is one place that
    /// says what a profile's defaults are called.
    static func defaultsKey(_ kind: TabKind, _ profileID: UUID) -> String {
        ProfileManager.defaultsKey(kind == .favourite ? "pinnedTabs" : "pinnedRows", profileID)
    }

    /// What is written down for a favourite or a pinned tab: the page it is on. Only web
    /// pages; a blank or file tab is not a place to come back to.
    static func pinURL(_ current: URL?) -> String? {
        guard let s = current?.absoluteString, s.hasPrefix("http") else { return nil }
        return s
    }

    /// The home a row takes on when it changes section: the page it is on as it enters
    /// Favourites or Pinned — that is the url it is being pinned *at* — and none at all
    /// when it leaves for Today, where a row stands for nothing but itself. A tab pinned
    /// while it is still blank gets nil and behaves exactly as every row did before.
    nonisolated static func home(entering kind: TabKind, at: URL?) -> URL? {
        kind == .today ? nil : at
    }

    /// What a favourite or a pinned row is written down as — see `Tab.pinnedURL`, and the
    /// two callers that must agree, `savePins` and `saveCurrentSpace`.
    nonisolated static func pinned(home: URL?, at: URL?) -> URL? { home ?? at }

    /// Where a favourite or a pinned row's × leaves it: the page it was pinned at, or nil
    /// for "park in place", which is what every row did before and what a row with no home
    /// still does. A row whose whereabouts are unknown — the gap between `resume` handing
    /// the view a load and `WKWebView.url` catching up, where `currentURL` is nil — has not
    /// wandered anywhere as far as anyone can tell, and is left exactly where it is.
    ///
    /// Pure, so `selfcheck --pure` can drive it with no tab: it is the same rule the glyph
    /// (`Tab.atHome` → `TabRowGlyph.decide`) and `close` both read, and those two drifting
    /// apart is a row whose × does not do what it says.
    nonisolated static func goesHome(home: URL?, at: URL?) -> URL? {
        guard let home, let at, home != at else { return nil }
        return home
    }

    /// What a row says once it has been sent home. The page it wandered to has gone, so its
    /// title has too — leaving "Some Article" on a row that is now google.com is a row
    /// lying about where it goes. History's last title for the page is the honest answer,
    /// and its host is the fallback for a page this profile has never been to.
    nonisolated static func homeTitle(known: String?, url: URL) -> String {
        if let known, !known.isEmpty { return known }
        return url.host ?? url.absoluteString
    }

    /// A favourite or a pinned tab that navigated is still itself, now pointing where it
    /// went.
    ///
    /// ponytail: `tabs`, not `everyTab`, and finding nothing is the right answer. `savePins`
    /// writes the Pinned rows of the Space the window is *showing*; a pinned page navigating
    /// inside a Space kept alive behind it would have its new url written into the wrong
    /// Space's list. Its rows were written on the way out and the live tab comes back on the
    /// page it actually reached, so the only cost is a stale url on disk until that Space is
    /// on screen again.
    static func savePins(owning tab: Tab) {
        all.first { $0.tabs.contains { $0 === tab } }?.savePins()
    }

    func savePins() {
        // A Little Arc holds no favourites and no pinned rows; writing its empty lists down
        // would erase the profile's.
        guard !isPrivate, !isLittle else { return }
        saveShape()          // the folders around the urls; see Folders.swift
        // `pinnedURL`, not `currentURL`: what is written down is the page the row stands
        // for. A pinned row browsed away from its page used to write the page it wandered
        // to into the Space, so the next launch came up on it — see `Tab.homeURL`.
        //
        // ponytail: `saveShape` (Folders.swift) still names the rows of the *folder* shape
        // by `pinURL(currentURL)`, so a row inside a folder that is wandered at the moment
        // of a save writes one url into the shape and another into this list, and
        // `pinOrder` cannot match the two: after a relaunch that one row comes back loose
        // at the end of Pinned rather than in its folder. Left alone because that file had
        // a PR in flight; the fix is the same expression there, `$0.pinnedURL`.
        func urls(_ kind: TabKind) -> [String] {
            tabs.filter { $0.kind == kind }.compactMap { TabStore.pinURL($0.pinnedURL) }
        }
        let favourites = urls(.favourite), pinned = urls(.pinned)
        // Arc: the only thing Spaces share is Favourites. The grid belongs to the profile and
        // is written there from every window; the Pinned rows belong to the Space this window
        // is showing — and it is always showing one, so there is no profile-level fallback.
        UserDefaults.vane.set(favourites, forKey: TabStore.defaultsKey(.favourite, profileID))
        guard let id = currentSpaceID, var space = spaces.first(where: { $0.id == id })
        else { return }
        space.pinnedURLs = []          // migrated out; see Spaces.favourites
        space.pinnedTabURLs = pinned.compactMap(URL.init(string:))
        ProfileManager.shared.updateSpace(space)
    }

    // MARK: Spaces

    /// Every space in this window's profile. A space belongs to exactly one profile, so this
    /// is the complete list a window can ever switch between.
    var spaces: [Space] {
        var all = ProfileManager.shared.spaces(for: profileID)
        if let live = previewSpace, let i = all.firstIndex(where: { $0.id == live.id }) {
            all[i] = live
        }
        return all
    }

    /// The space this window is showing. Answers from `previewSpace` without touching the
    /// disk at all when that is the one being asked for, which is what lets the theme
    /// editor repaint the window on every frame of a drag for free.
    var currentSpace: Space? {
        if let live = previewSpace, live.id == currentSpaceID { return live }
        return spaces.first { $0.id == currentSpaceID }
    }

    /// A space being edited right now and not yet written down. The theme editor puts every
    /// frame of a drag here so the window's ground follows the fingers, and writes the space
    /// once when they leave: spaces.json is not a place to put sixty frames a second, and
    /// the slider this replaced wrote it on every tick.
    ///
    /// ponytail: an override, not a cache — `spaces` still reads the file, so a space another
    /// window changed still shows up on the next redraw. Ceiling: while a drag is live, a
    /// redraw of the footer dots decodes the file once, which is what it always did.
    @Published var previewSpace: Space?

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

    /// How far sideways the Space-owned sidebar sections are being held right now, in points;
    /// 0 when nothing is happening. A two-finger swipe writes the fingers' travel here and the
    /// sidebar reads it, which is what makes the strip follow the fingers instead of waiting
    /// for them to finish. See `Spaces.Swipe`.
    @Published var spaceDrag: CGFloat = 0

    /// True from the moment a Space swipe claims the strip until its spring has settled.
    ///
    /// Not simply `spaceDrag != 0`: the commit hands the incoming Space's sections the offset
    /// its preview was already sitting at and springs *that* to zero, so the one update in
    /// which `currentSpaceID` changes must still know a swipe is what changed it — otherwise
    /// the sidebar's own slide transition plays on top of a slide that has already happened.
    @Published var spaceSwiping = false

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
        // Whatever a drag was previewing has just been written down, or superseded.
        if previewSpace?.id == space.id { previewSpace = nil }
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
        // `pinnedURL` — the same expression `savePins` writes, and it has to be: these two
        // write the same two lists, the Space fingerprint is taken off what they leave on
        // disk, and a fingerprint that moves on its own tears the Space down on the way
        // back in. A Today tab has no home, so for those it is `currentURL` exactly as
        // before. See `Tab.homeURL`.
        func urls(_ keep: (Tab) -> Bool) -> [URL] {
            tabs.filter(keep).compactMap(\.pinnedURL).filter { $0.scheme?.hasPrefix("http") == true }
        }
        space.tabURLs = urls { $0.kind == .today }
        space.pinnedURLs = []              // Favourites are the profile's; see `savePins`
        space.pinnedTabURLs = urls { $0.kind == .pinned }
        saveShape()                        // and the folders those urls are arranged in
        ProfileManager.shared.updateSpace(space)
        UserDefaults.vane.set(urls { $0.kind == .favourite }.map(\.absoluteString),
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
        // And which tab the Space is being left on, so switching back lands on it rather
        // than on whatever is first. Written here rather than in `switchTo` so the swipe
        // commit, the Spaces menu, ⌥⌘←/→ and ⌃1–9 all get it — every one of them saves
        // first. Only a web page is worth coming back to (see `Spaces.rememberTab`), and
        // never a favourite: the grid is the profile's, so every Space would remember the
        // same tile and land on it. See `Spaces.landing`.
        let leftOn = active.flatMap { $0.kind == .favourite ? nil : $0.currentURL }
        Spaces.rememberTab(leftOn.flatMap {
            $0.scheme?.hasPrefix("http") == true ? $0.absoluteString : nil
        }, in: id)
    }

    /// The Spaces this window has been in and is keeping alive behind the one it is showing,
    /// by Space id. See `Stash`.
    private var stashes: [UUID: Stash] = [:]

    /// Every tab this window is holding: the strip, plus the Spaces kept alive behind it.
    ///
    /// The idle-suspension and auto-archive sweeps run over this rather than over `tabs` — a
    /// stashed page is still one of the user's pages, and a stash no sweep could see would be
    /// the one place in the app where a tab is never unloaded and never archived. The media
    /// tray reads it too, because a page you swiped away from carries on playing.
    ///
    /// Everything else stays on `tabs` and is meant to: the tab switcher, ⌘1–9, the command
    /// bar, the extension host and `saveCurrentSpace` are all about the strip in front of the
    /// user, and a Space that is not being shown has no rows in it.
    var everyTab: [Tab] { tabs + stashes.values.flatMap(\.tabs) }

    /// Which Space this window is keeping `id` alive for, if it is not on the strip.
    func space(stashing id: Tab.ID) -> UUID? {
        stashes.first { $0.value.tabs.contains { $0.id == id } }?.key
    }

    /// Show a tab: select it, and go to its Space first if it is one this window is keeping
    /// alive behind the one on screen. The media tray is the only thing that can name a tab
    /// the window is not showing — the page still playing in the Space you swiped off.
    func reveal(_ id: Tab.ID) {
        if let held = space(stashing: id), let space = spaces.first(where: { $0.id == held }) {
            switchTo(space: space)
        }
        // The stash does not always survive the switch: a Space something else edited while
        // it was away is rebuilt from disk and this tab was torn down on the way. Naming a
        // tab the strip does not have leaves a window drawing nothing, so it lands where the
        // switch itself would have.
        current = TabStore.revealed(id, strip: tabs.map(\.id),
                                    landing: currentSpaceID.flatMap(landing(in:)))
    }

    /// Which row `reveal` ends on. Pure, so `selfcheck --pure` can prove the fallback without
    /// a Space to edit out from under a stash.
    nonisolated static func revealed<T: Equatable>(_ id: T, strip: [T], landing: T?) -> T? {
        strip.contains(id) ? id : landing
    }

    /// Let a Space's kept-alive tabs go: the pages down, the stash gone. Never touches the
    /// strip — this is only ever about a Space the window is not showing.
    func drop(stash id: UUID) {
        stashes.removeValue(forKey: id)?.tabs.forEach { $0.tearDown() }
    }

    /// Every one of them, because the window itself is going. See `windowWillClose`.
    func dropStashes() {
        stashes.values.flatMap(\.tabs).forEach { $0.tearDown() }
        stashes.removeAll()
    }

    /// A Space has been deleted, so no window may keep its pages alive behind a strip that
    /// can never show them again. See `Spaces.delete`, the one place a Space goes.
    static func forgetStashes(space: UUID, profileID: UUID) {
        for store in TabStore.all where store.profileID == profileID { store.drop(stash: space) }
    }

    /// What is on disk for `space` this moment, as one string: both url lists and both folder
    /// shapes, bytes and all. Any edit at all moves it on, which is exactly the question a
    /// stash has to answer on the way back in.
    ///
    /// Pure, so `selfcheck --pure` can prove the rule with no Space to write.
    nonisolated static func fingerprint(tabURLs: [URL], pinnedTabURLs: [URL],
                                        shapes: [Data?]) -> String {
        (tabURLs.map(\.absoluteString) + ["\u{1}"] + pinnedTabURLs.map(\.absoluteString)
            + ["\u{1}"] + shapes.map { $0?.base64EncodedString() ?? "" }).joined(separator: "\n")
    }

    /// The same, read off this profile's disk. A Space that is not there at all — deleted, or
    /// another profile's — fingerprints as an empty one, which no stash with anything in it
    /// can match.
    private func fingerprint(of id: UUID) -> String {
        let space = spaces.first { $0.id == id }
        return TabStore.fingerprint(tabURLs: space?.tabURLs ?? [],
                                    pinnedTabURLs: space?.pinnedTabURLs ?? [],
                                    shapes: TabStore.shapeData(space: id, profileID: profileID))
    }

    /// The tab showing a Space lands on: the one it was left on, else the ladder down through
    /// the first Today tab and the first pinned row in `Spaces.landing`.
    private func landing(in space: UUID) -> Tab.ID? {
        Spaces.landing(on: tabs.map { ($0.currentURL?.absoluteString, $0.kind) },
                       last: Spaces.lastTab(in: space)).map { tabs[$0].id }
    }

    /// Save the outgoing space, then show the incoming one. A window shows one space at a
    /// time, and keeps the ones behind it alive: leaving parks the strip in a `Stash` and
    /// coming back puts the same loaded tabs straight back, so a Space no longer reloads
    /// every page the first time you click one.
    ///
    /// The rebuild from disk is still here and is what runs whenever the stash cannot be
    /// trusted — nothing kept for this Space, or something edited the Space from elsewhere
    /// while it was away. Then each tab's interactionState comes back out of the sidecar, so
    /// even a rebuild lands on the same page, scroll offset and back/forward list, and only
    /// the tab that becomes current actually loads.
    func switchTo(space: Space) {
        // A space's profileID is the only link to its profile, so refusing here is what keeps
        // a window from ever showing another profile's tabs. A Little Arc is in no Space and
        // has no strip to rebuild — switching one would throw the page away and leave an
        // empty window claiming to be in a Space. Every route into here is shared with the
        // browser window (the palette's Space rows, ⌃1–9, ⌥⌘←/→, the Spaces menu), so the
        // refusal belongs here rather than at each of them.
        // A private window is spaceless the way Arc's incognito is: letting one switch would
        // put a Space's tabs in a window that writes nothing back, and claim in the footer
        // to be showing a Space it can never save.
        guard !isLittle, !isPrivate, space.profileID == profileID,
              space.id != currentSpaceID else { return }
        saveCurrentSpace()
        // Which way the strip slides. Set before the switch so the sidebar's transition and
        // the tint cross-fade are already pointing the right way when the list changes.
        spaceDirection = direction(to: space)
        // Not close(): that pushes onto the reopen stack and closes the window on the last tab.
        // Favourites are the profile's, not the Space's, so their tabs stay exactly as they
        // are — Arc's grid does not so much as blink when you swipe between Spaces.
        let leaving = Stash.leaving(tabs.map { (id: $0, kind: $0.kind) })
        // The `current` didSet stamps the tab you leave behind *within* a Space; leaving the
        // Space itself goes around it. Without this the page you were reading, and every pane
        // beside it, would be stashed carrying an idle clock that started when it was first
        // selected, and the next sweep could unload it minutes after you swiped away.
        let onScreen = Set([current].compactMap { $0 } + (activeSplit?.tabs ?? []))
        for tab in leaving where onScreen.contains(tab.id) { tab.lastActive = .now }
        if let id = currentSpaceID, spaces.contains(where: { $0.id == id }) {
            // A split of the Space's own tabs travels whole — nothing is leaving it, the
            // whole thing is being put away. One with a favourite in it is not the Space's
            // to keep: the tile stays behind in the grid, so that pane leaves its split the
            // way a closing tab does. Otherwise `splits` would keep ids of tabs the strip no
            // longer has, and a split holding a favourite would draw one pane and a divider
            // into nothing.
            let mine = Set(leaving.map(\.id))
            let travelling = splits.filter { $0.tabs.allSatisfy(mine.contains) }
            for tab in leaving where !travelling.contains(where: { $0.contains(tab.id) }) {
                dropPane(tab.id)
            }
            splits.removeAll { travelling.contains($0) }
            drop(stash: id)             // an older stash for the same Space, superseded
            stashes[id] = Stash(tabs: leaving, pins: pins, todayShape: todayShape,
                                splits: travelling,
                                // Never a favourite: the grid is the profile's, so every
                                // Space would come back on the same tile. See `landing`.
                                current: tabs.first { $0.id == current && $0.kind != .favourite }?.id,
                                fingerprint: fingerprint(of: id))
        } else {
            // A Space that is not on disk any more — deleted from another window, or the
            // stale one `resolveStaleSpace` is walking out of — has nothing to come back
            // from and nothing to check a stash against, so its pages simply go.
            for tab in leaving { dropPane(tab.id) }
            leaving.forEach { $0.tearDown() }
        }
        tabs.removeAll { $0.kind != .favourite }
        // The one place tabs leave the strip without `close` — and so without
        // `selection.keep`. A selection left pointing at the Space we just walked out of
        // names rows that are not there: ⌘W finds none of them and quietly does nothing,
        // and the bulk menu counts tabs the window no longer has.
        selection.clear()
        currentSpaceID = space.id
        applySpaceAppearance()          // the new space may be pinned to light or dark
        if let kept = stashes[space.id], kept.fingerprint == fingerprint(of: space.id) {
            // Nothing has edited this Space since we walked out of it, so the tabs we walked
            // out with are still what it is: the same objects, still loaded, in the same
            // order, with their folders, their splits and the row they were left on.
            stashes.removeValue(forKey: space.id)
            tabs = Stash.entering(tabs.map { (id: $0, kind: $0.kind) }, stashed: kept.tabs)
            pins = kept.pins
            todayShape = kept.todayShape
            splits += kept.splits
            current = kept.current ?? landing(in: space.id)
        } else {
            drop(stash: space.id)       // somebody else edited the Space; start again from disk
            let parked = Suspension.SpaceState.load(space: space.id, profileID: profileID, in: Store.directory)
            restorePins(urls: space.pinnedTabURLs ?? [], parked: parked)
            adoptTodayShape(tabs: space.tabURLs.map { url in
                let t = newBlankTab()
                t.open(url, parked: parked[url.absoluteString])
                // Named by the url it was opened with, not the one it has: with suspension off
                // `open` hands it straight to `go` and there is no `currentURL` yet.
                return (url: url, tab: t)
            })
            // Arc lands on the tab this Space was left on; `Spaces.landing` is the ladder down
            // to the first Today tab, the first pinned row, and finally an empty pill.
            current = landing(in: space.id)
        }
        // Only when the landing found nothing at all. A Space of pinned rows and no Today
        // tabs lands on a row, and the command bar over the page it just opened would be a
        // bar nobody asked for.
        if current == nil { openPalette(.newTab) }
        rememberSpace()
        extensions.sync()
    }

    /// A Space deleted from another window, from Settings or from the Library leaves this
    /// window pointing at one that is not on disk. An ordinary window always shows a Space,
    /// so it falls into a survivor rather than drawing a sidebar with no heading and a
    /// Pinned section it can never save. The tabs it was showing went to the Archive with
    /// the Space, which is where `switchTo` emptying the strip leaves the user looking.
    func resolveStaleSpace() {
        guard !isPrivate, !isLittle, currentSpace == nil, let first = spaces.first else { return }
        switchTo(space: first)
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

    /// Create a space in this window's profile and move this window into it, leaving the
    /// tabs that are already open behind in the Space they belong to — Arc's new Space is
    /// empty. Returns nil for a private window, which has no profile storage to write to.
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
        // Switching into it is what empties the strip; moving `currentSpaceID` by hand would
        // have written this window's open tabs into the new Space as well as leaving them in
        // the old one, so they showed up in both. There is no second branch for a window
        // outside every Space any more — an ordinary window is always in one.
        switchTo(space: space)
        palette = nil                      // the editor is the thing to look at, not the bar
        rememberSpace()
        editingSpace = space.id            // opens the inline name/icon/colour editor
        Toasts.show("New Space created", in: self)
        return spaces.first { $0.id == space.id } ?? space
    }
}
