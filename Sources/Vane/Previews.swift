import AppKit
import WebKit

/// Hover a link, see where it goes — as a live mini render of the destination plus the
/// metadata the page already ships, with the on-device summary layered on top when it
/// arrives.
///
/// The shape of this file is decided by three measurements, all taken on this machine
/// through this class against real urls, not guessed:
///
///   * **The mini render is the content.** An offscreen WKWebView at a real viewport, with
///     the profile's data store and the content blocker attached, hands back its first
///     non-blank `takeSnapshot` 320ms–4.1s after `request` — typically under 2s. A re-hover
///     comes out of the cache in 0–2ms. That is inside the window where a hover still feels
///     like a hover, so the picture is what fills the card.
///   * **The metadata is free.** `og:description` arrives at documentEnd, measured at
///     420ms–2.7s, at or before the first paint. On a large slice of the web it is a better
///     one-liner than anything a 3B model will write about the same page, and it costs one
///     small string over the script bridge.
///   * **The model is a passenger, and it is not something you can promise a time for.**
///     First streamed element measured at 6–15s after the hover. That is not this file
///     being slow: the same two-sentence summary of the same 777-character text, run
///     standalone in a process with no WebKit in it, measured anywhere from **0.70s to
///     10.26s** across a dozen consecutive runs. The on-device model's latency on this Mac
///     varies by more than an order of magnitude for identical input, so the summary is
///     started promptly (220ms debounce), streamed as it grows, and announced honestly via
///     `summarizing` — but nothing is ever allowed to wait on it.
///
/// ponytail: no prefetch, no speculative warming of the *next* link, no disk cache. Hover
/// previews are speculative work paid for by pointer movement; the budget here is one web
/// view, one load at a time, one in-memory cache, and aggressive cancellation. Ceiling: a
/// second hover on a *different* profile rebuilds the web view and pays a process launch.
@MainActor final class Previews: ObservableObject {
    static let shared = Previews()

    /// Everything a preview card can draw. Published as one value so a view redraws once
    /// per change instead of once per field.
    ///
    /// `image` is the live mini render — the whole point. `imageURL` is `og:image`, for a
    /// card that would rather show the page's own hero art than a shrunken screenshot;
    /// nothing here fetches it, that is the drawing code's call.
    struct Preview {
        var url: URL
        var title = ""
        /// `og:description` where the page has one. Present within milliseconds of the DOM.
        var description = ""
        /// The mini render. Nil until the destination has painted something.
        var image: NSImage?
        var favicon: NSImage?
        /// The model's text so far. Cumulative — never append to this, assign it.
        var summary = ""
        /// True while the model is generating, so a card can say "summarising…" honestly
        /// rather than sitting there looking hung. False also covers "never asked".
        var summarizing = false
        /// Still loading: the image may still improve. Lets a card show a subtle progress
        /// hint without owning any of the loading state itself.
        var loading = true
        /// `og:image`, resolved against the destination.
        var imageURL: URL?
    }

    @Published private(set) var current: Preview?

    /// Off is a real preference; on is the default because a preview is the feature.
    static var enabled: Bool {
        get { UserDefaults.vane.object(forKey: "linkPreviews") as? Bool ?? true }
        set { UserDefaults.vane.set(newValue, forKey: "linkPreviews") }
    }

    // MARK: - Dials
    //
    // Every number here was either measured or is a deliberate ceiling.

    /// A real desktop viewport. Smaller and the destination lays itself out as a phone,
    /// which is not what the user is about to click on.
    static let viewport = NSSize(width: 1000, height: 700)
    /// Point width of the snapshot handed to the UI. 360pt at 2x is ~1.1MB of bitmap; the
    /// cache cap below is chosen against that number.
    static let snapshotWidth = 360.0
    /// ponytail: 12 × ~1.1MB ≈ 13MB of images held live. Cheap for what it buys — a
    /// re-hover is instant — and bounded. Ceiling: no disk tier, so the cache dies with the
    /// process, which is correct for something this speculative.
    static let cacheCap = 12
    /// Five minutes. Long enough that going back and forth across a page of links never
    /// re-loads anything; short enough that a preview never shows a headline that has since
    /// changed.
    static let cacheTTL: TimeInterval = 300
    /// Long enough that a pointer sweeping across a paragraph of links does not fire the
    /// neural engine once per link; short enough that it is not a "hold still" gesture.
    /// 220ms is roughly one deliberate pause.
    static let summaryDebounce = Duration.milliseconds(220)
    /// Stop asking for snapshots after this. A page that has painted nothing by now is
    /// broken, blocked, or a login wall, and none of those improve with more polling.
    static let paintDeadline = Duration.seconds(4)
    static let paintInterval = Duration.milliseconds(150)
    /// The model gets the top of the article, not all of it.
    ///
    /// This is the one lever on the wait that is actually ours: the wait is mostly prefill —
    /// the model reading — and prefill scales with the input. Measured end to end through
    /// this class, handing `summarizeStream` a full 8000-character page (AppleAI's own input
    /// budget) put the first streamed element **22.6s** away; the same pages cut to 1200
    /// characters measured 6–15s. A two-sentence hover card wants the lede regardless, so
    /// the cut costs nothing anyone can see.
    /// ponytail: a character count, not a section detector. Ceiling: a page that buries its
    /// point below a 1200-character preamble gets summarised on the preamble.
    static let summaryBudget = 1_200
    /// documentEnd, then one retry at didFinish. A framework-rendered page has an empty
    /// body at documentEnd and everything by didFinish; anything still empty after two
    /// looks has no article in it and never will.
    static let summaryTryLimit = 2

    // MARK: - Eligibility

    /// The cache key, and the identity a preview is compared by: the url without its
    /// fragment. Two links into the same document differ only in where they scroll to, and
    /// previewing that twice would be two loads of one page.
    static func key(for url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return (parts?.url ?? url).absoluteString
    }

    /// What may be previewed at all. Deliberately unconditional — the Shift variant in the
    /// script below widens which *links* get reported, never these rules.
    ///
    /// `onPage` is the tab's current url: previewing the page you are already looking at is
    /// a whole page load to show the user a picture of what is behind the popover.
    static func eligible(_ url: URL, onPage: URL?) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return key(for: url) != onPage.map(key(for:))
    }

    // MARK: - Requesting

    private var cache = Cache()
    /// Monotonic. Every publish carries the id of the request that produced it, so a reply
    /// arriving after the pointer moved is dropped rather than flashed on screen.
    private var latest = 0
    /// What `current` is about, so re-entering the same link mid-load is a no-op instead of
    /// a restart.
    private var showing: String?

    private var debounceTask: Task<Void, Never>?
    private var paintTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    /// Both have to be true before the model is worth starting: the pointer has settled,
    /// and there is a parsed DOM to take text out of.
    private var settled = false
    private var domReady = false
    private var summaryTries = 0
    /// The request whose page has actually committed. Until then the web view is still
    /// showing the *last* preview, and snapshotting it would put the previous link's
    /// screenshot under this link's title — measured, and exactly what happened before this
    /// existed: every preview after the first "painted" in 160ms because it was a picture of
    /// the one before it.
    private var committed = 0

    /// Start (or instantly re-show) a preview of `url`. Safe to call on every hover event —
    /// the same link twice in a row costs nothing.
    func request(_ url: URL, from tab: Tab) {
        guard Previews.enabled else { return }
        guard Previews.eligible(url, onPage: tab.currentURL) else { cancel(); return }
        let key = Previews.key(for: url)
        if showing == key { return }

        stop()
        let id = begin()
        showing = key

        // Re-hover: everything, image included, straight back out of memory in this turn of
        // the run loop. This is the whole reason the cache exists.
        if let hit = cache.lookup(key) {
            var p = hit
            p.summarizing = false
            p.loading = false
            publish(p, for: id)
            return
        }

        var p = Preview(url: url)
        p.title = url.host ?? url.absoluteString      // something to draw before the DOM lands
        // A private window never writes a favicon to disk — an icon in the cache directory
        // is a record that the host was visited. `Favicons.icon(for:)` has no read-only
        // door, so private previews simply go without one.
        p.favicon = tab.isPrivate ? nil : tab.favicons.icon(for: url)
        publish(p, for: id)

        let web = webView(for: tab)
        web.load(URLRequest(url: url))

        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Previews.summaryDebounce)
            guard !Task.isCancelled, let self, self.latest == id else { return }
            self.settled = true
            self.startSummary(id: id)
        }
        paintTask = Task { [weak self] in await self?.paint(id: id, web: web) }
    }

    /// The pointer left. Everything stops: the load, the snapshots, the inference.
    func cancel() {
        stop()
        current = nil
        // about:blank rather than tearing the view down — a fresh WKWebView costs a
        // WebContent process launch, and this is a thing the user does dozens of times a
        // minute. Blanking is what actually stops a video, an animation and a timer.
        if let web, web.url != nil { web.load(URLRequest(url: URL(string: "about:blank")!)) }
    }

    /// Everything cancel() does except clearing the screen, so `request` can reuse it.
    private func stop() {
        latest += 1
        showing = nil
        settled = false
        domReady = false
        summaryTries = 0
        debounceTask?.cancel(); debounceTask = nil
        paintTask?.cancel(); paintTask = nil
        // Cancelling the consumer is what cancels the inference: AppleAI's stream cancels
        // its work and retires its session from `onTermination`.
        summaryTask?.cancel(); summaryTask = nil
        web?.stopLoading()
    }

    // internal, not private: `check()` drives the publish gate directly.
    func begin() -> Int { latest += 1; return latest }

    /// True when this reply belongs to a request that has since been superseded or cancelled.
    static func stale(request: Int, latest: Int) -> Bool { request != latest }

    func publish(_ p: Preview, for id: Int) {
        guard !Previews.stale(request: id, latest: latest) else { return }
        current = p
        // Only a preview with a picture is worth remembering; caching the empty shell would
        // make the *next* hover instantly show nothing.
        if p.image != nil { cache.store(p, key: Previews.key(for: p.url)) }
    }

    private func edit(_ id: Int, _ change: (inout Preview) -> Void) {
        guard !Previews.stale(request: id, latest: latest), var p = current else { return }
        change(&p)
        publish(p, for: id)
    }

    // MARK: - The mini render

    private var web: WKWebView?
    private var host: NSWindow?
    private var bridge: Bridge?
    /// The web view is built against one profile's data store; a hover from another window
    /// rebuilds it. Reused otherwise, which is what keeps the warm numbers warm.
    private var builtFor: (profile: UUID, isPrivate: Bool)?

    private func webView(for tab: Tab) -> WKWebView {
        if let web, builtFor?.profile == tab.profileID, builtFor?.isPrivate == tab.isPrivate {
            return web
        }
        web?.removeFromSuperview()

        // The tab's own configuration: its profile's persistent data store, so a page the
        // user is logged into previews as logged in, and — the part that matters more — the
        // compiled content blocker, without which a preview loads the ads the browser
        // exists to not load. A private tab gets `.nonPersistent()`, a fresh ephemeral store
        // that writes nothing to disk and is not the private *window's* store either, so a
        // preview cannot drop a cookie into the session the user is browsing in.
        let cfg = Tab.configuration(isPrivate: tab.isPrivate, profileID: tab.profileID)
        // A preview is not a tab. Extensions must not see it, script into it, or count it.
        cfg.webExtensionController = nil
        // Tab.configuration allows autoplay, which is right for a tab and wrong for a
        // picture of one.
        cfg.mediaTypesRequiringUserActionForPlayback = .all

        let b = Bridge(self)
        bridge = b
        cfg.userContentController.addUserScript(
            WKUserScript(source: Previews.metaScript, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        cfg.userContentController.add(b, name: Previews.metaMessageName)

        let w = WKWebView(frame: NSRect(origin: .zero, size: Previews.viewport), configuration: cfg)
        w.customUserAgent = Settings.userAgent
        w.navigationDelegate = b
        w.uiDelegate = b

        // WebKit will not run a page for a view that was never hosted — same trick
        // DRMCheck uses. Borderless so it never shows up in Mission Control, parked far
        // enough off-screen to miss any plausible display arrangement.
        let win = host ?? NSWindow(contentRect: w.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        win.contentView = w
        if host == nil {
            win.isExcludedFromWindowsMenu = true
            win.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
            win.orderFront(nil)
            host = win
        }

        web = w
        builtFor = (tab.profileID, tab.isPrivate)
        return w
    }

    /// Poll for a snapshot until one of them is not a blank rectangle, then keep refreshing
    /// it while the page is still arriving. Polling rather than waiting for didFinish is
    /// most of the win: measured across five real urls, the first usable frame landed at
    /// 320ms–4.1s while didFinish was 0.6–2.2s behind it on the slower ones. Pages paint
    /// long before they finish, and the first thing painted is the thing worth showing.
    private func paint(id: Int, web: WKWebView) async {
        let deadline = ContinuousClock.now + Previews.paintDeadline
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: Previews.paintInterval)
            guard !Task.isCancelled, latest == id else { return }
            // Not until this request's own page is on screen — see `committed`.
            guard committed == id, let img = await snapshot(of: web),
                  Previews.meaningful(img) else { continue }   // still a white box
            edit(id) { $0.image = img }
            // One more once the page says it is done, to catch web fonts and hero images
            // that land right after the first paint. Then stop — this is a preview.
            if !web.isLoading { break }
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, latest == id, committed == id, let img = await snapshot(of: web),
              Previews.meaningful(img) else {
            edit(id) { $0.loading = false }
            return
        }
        edit(id) { $0.image = img; $0.loading = false }
    }

    private func snapshot(of web: WKWebView) async -> NSImage? {
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: Previews.snapshotWidth)
        return try? await web.takeSnapshot(configuration: cfg)
    }

    /// "Usable" means "not one flat colour". A snapshot taken before the first paint is a
    /// perfectly uniform white (or black) rectangle, and showing that is worse than showing
    /// nothing. Samples a coarse grid; three distinct colours means something rendered.
    /// ponytail: a real page that is genuinely two colours in its first 400 rows is judged
    /// blank and waits for the next poll. Cheap failure, 150ms.
    static func meaningful(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let bits = NSBitmapImageRep(data: tiff),
              bits.pixelsWide > 8, bits.pixelsHigh > 8 else { return false }
        var seen = Set<UInt32>()
        for x in stride(from: 2, to: bits.pixelsWide, by: max(1, bits.pixelsWide / 20)) {
            for y in stride(from: 2, to: bits.pixelsHigh, by: max(1, bits.pixelsHigh / 20)) {
                guard let c = bits.colorAt(x: x, y: y) else { continue }
                seen.insert(UInt32(c.redComponent * 255) << 16
                            | UInt32(c.greenComponent * 255) << 8
                            | UInt32(c.blueComponent * 255))
                if seen.count >= 3 { return true }
            }
        }
        return false
    }

    // MARK: - Metadata, straight off the DOM

    fileprivate func committed(_ web: WKWebView) {
        guard web === self.web, showing != nil else { return }
        committed = latest
    }

    /// Deliberately keyed on "is there a live request", not on the url matching the one that
    /// was asked for: github.com/apple/swift is a 301 to github.com/swiftlang/swift, and
    /// comparing urls threw away the metadata of every redirecting link — measured, the card
    /// kept the bare hostname as its title.
    fileprivate func received(meta html: String, from web: WKWebView) {
        let id = latest
        guard web === self.web, let url = web.url, showing != nil else { return }
        let m = Previews.meta(from: html)
        edit(id) {
            if !m.title.isEmpty { $0.title = m.title }
            if !m.description.isEmpty { $0.description = m.description }
            if !m.image.isEmpty { $0.imageURL = URL(string: m.image, relativeTo: url)?.absoluteURL }
        }
        // documentEnd: the DOM is parsed, so there is text to summarise even though the
        // images and the stylesheets are still arriving.
        domReady = true
        startSummary(id: id)
    }

    fileprivate func finished(_ web: WKWebView) {
        guard web === self.web else { return }
        domReady = true
        startSummary(id: latest)
    }

    fileprivate func failed(_ web: WKWebView) {
        guard web === self.web else { return }
        edit(latest) { $0.loading = false }
    }

    // MARK: - The model

    /// Runs once both gates are open: the pointer settled, and the DOM parsed. Whichever
    /// arrives second starts it.
    private func startSummary(id: Int) {
        guard settled, domReady, summaryTask == nil, AppleAI.ready,
              summaryTries < Previews.summaryTryLimit,
              !Previews.stale(request: id, latest: latest), let web else { return }
        summaryTries += 1
        edit(id) { $0.summarizing = true }
        summaryTask = Task { [weak self] in await self?.summarize(id: id, web: web) }
    }

    private func summarize(id: Int, web: WKWebView) async {
        // Reader's extraction, not innerText: it is the one piece of code in this app that
        // already knows how to find the article and leave the navigation behind, and a
        // summary of a nav bar is worse than no summary.
        guard let e = await Reader.extract(from: web), latest == id else {
            edit(id) { $0.summarizing = false }
            if latest == id { summaryTask = nil }      // let didFinish have the retry
            return
        }
        let whole = (e.title + "\n\n" + Reader.plainText(e.nodes))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // AppleAI.truncate cuts at a sentence end where it can, so the model is never handed
        // half a clause. See `summaryBudget` for why this is cut at all.
        let text = AppleAI.truncate(whole, limit: Previews.summaryBudget)

        // Two sentences, not three: this is a hover card, and two is ~30% less generation.
        var fold = Fold()
        for await element in AppleAI.summarizeStream(text, sentences: 2) {
            guard latest == id else { return }        // pointer left; publish nothing more
            let carryOn = fold.take(element)
            edit(id) { $0.summary = fold.text }
            if !carryOn { break }                     // the empty final element: retracted
        }
        guard latest == id else { return }
        // An empty stream means the model was never called — nothing was shown and nothing
        // needs retracting, so the card just stops saying it is summarising.
        edit(id) { $0.summarizing = false; $0.summary = fold.text }
        // Nothing came back, which on a framework-rendered page usually means the body was
        // still empty at documentEnd. Clear the slot so didFinish gets the one retry
        // `summaryTryLimit` allows.
        if !fold.ran { summaryTask = nil }
    }

    /// The stream contract, as a value, so it can be asserted without a neural engine.
    ///
    /// `AppleAI.summarizeStream` yields **cumulative** snapshots: each element is the whole
    /// answer so far. So `take` assigns and never appends. A **final empty element** is the
    /// retraction signal — the completed answer failed validation and everything already
    /// shown must be discarded — so it clears the text and reports "stop". A stream with no
    /// elements at all means the model was never called, which is a different thing from an
    /// answer that was withdrawn: `ran` tells them apart.
    struct Fold {
        private(set) var text = ""
        private(set) var ran = false
        private(set) var discarded = false

        /// Returns false when the stream should not be read any further.
        @discardableResult
        mutating func take(_ element: String) -> Bool {
            ran = true
            guard !element.isEmpty else { text = ""; discarded = true; return false }
            text = element
            return true
        }
    }

    static func fold(_ elements: [String]) -> Fold {
        var f = Fold()
        for e in elements {
            if !f.take(e) { break }
        }
        return f
    }

    // MARK: - Cache

    /// url → preview, capped and time-limited. ponytail: a dictionary and a counter. No LRU
    /// list, no cost accounting — eviction is oldest-inserted-first, which for a hover cache
    /// is indistinguishable from LRU because nothing is ever re-inserted without being
    /// re-fetched. Ceiling: a preview you keep re-hovering still ages out at the TTL.
    /// @MainActor because a type nested in an isolated one does not inherit its isolation,
    /// and the caps above are main-actor state.
    @MainActor struct Cache {
        private struct Entry {
            var preview: Preview
            var at: Date
            var seq: Int
        }
        private var entries: [String: Entry] = [:]
        private var seq = 0

        var count: Int { entries.count }

        mutating func store(_ p: Preview, key: String, now: Date = .now) {
            seq += 1
            entries[key] = Entry(preview: p, at: now, seq: seq)
            while entries.count > Previews.cacheCap {
                guard let oldest = entries.min(by: { $0.value.seq < $1.value.seq })?.key else { break }
                entries[oldest] = nil
            }
        }

        mutating func lookup(_ key: String, now: Date = .now) -> Preview? {
            guard let e = entries[key] else { return nil }
            guard now.timeIntervalSince(e.at) < Previews.cacheTTL else {
                entries[key] = nil
                return nil
            }
            return e.preview
        }
    }

    // MARK: - The hover script
    //
    // Injected into every tab; `messageName` is the channel it posts on.

    static let messageName = "vanepreview"

    /// A hover, reported after a short dwell, or immediately with Shift held.
    ///
    /// Two shapes on the wire:
    ///   `{url, shift, x, y, w, h}`  — preview this, the rect is viewport coordinates
    ///   `{gone: true}`              — the pointer left; cancel
    ///
    /// Shift is the "preview *any* link" variant: it skips the dwell and drops the filters
    /// that normally keep the popover out of the way — in-page anchors and links back to the
    /// page you are already on. Those still can't be previewed (see `eligible`), but the
    /// app gets told about them, which is what lets a UI say "you are already here" instead
    /// of silently doing nothing.
    ///
    /// ponytail: two document-level listeners in the capture phase and one timer. No
    /// per-link binding, no MutationObserver — a page that rewrites its links is handled for
    /// free because the lookup happens at mouseover time. Ceiling: a link inside a
    /// cross-origin iframe is never seen (this is main-frame only), and a link inside a
    /// closed shadow root is not reachable from `closest()`.
    static let script = """
    (function () {
      var DWELL = 190;
      var timer = null, at = null;

      function link(node) {
        while (node && node.nodeType !== 1) { node = node.parentNode; }
        return node && node.closest ? node.closest('a[href]') : null;
      }
      // `a.href` is resolved and normalised by the DOM, so this is the real destination.
      function web(a) { return /^https?:/i.test(a.href); }
      function samePage(a) {
        if ((a.getAttribute('href') || '').charAt(0) === '#') { return true; }
        return a.href.split('#')[0] === location.href.split('#')[0];
      }
      function send(a) {
        var r = a.getBoundingClientRect();
        webkit.messageHandlers.\(messageName).postMessage({
          url: a.href, shift: !!shifted,
          x: r.left, y: r.top, w: r.width, h: r.height
        });
      }
      function gone() {
        if (timer) { clearTimeout(timer); timer = null; }
        if (!at) { return; }
        at = null;
        webkit.messageHandlers.\(messageName).postMessage({ gone: true });
      }
      function enter(a) {
        if (a === at) { return; }
        gone();
        at = a;
        if (shifted) { send(a); return; }
        timer = setTimeout(function () { timer = null; if (at === a) { send(a); } }, DWELL);
      }

      var shifted = false;

      document.addEventListener('mouseover', function (e) {
        var a = link(e.target);
        if (!a || !web(a)) { return; }
        if (!shifted && samePage(a)) { return; }
        enter(a);
      }, true);

      document.addEventListener('mouseout', function (e) {
        var a = link(e.target);
        if (!a || a !== at) { return; }
        // Moving between two children of the same <a> is not leaving it.
        var to = link(e.relatedTarget);
        if (to === at) { return; }
        gone();
      }, true);

      // Holding Shift over a link that was filtered out promotes it there and then, and
      // skips the dwell for one that was merely still waiting.
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Shift' || shifted) { return; }
        shifted = true;
        var hovered = document.querySelector('a[href]:hover');
        if (hovered && web(hovered)) { at = null; enter(hovered); }
      }, true);
      document.addEventListener('keyup', function (e) {
        if (e.key === 'Shift') { shifted = false; }
      }, true);

      // Anything that moves the page out from under the popover retracts it.
      window.addEventListener('scroll', gone, true);
      window.addEventListener('blur', gone);
      window.addEventListener('pagehide', gone);
      document.addEventListener('mousedown', gone, true);
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') { gone(); }
      }, true);
    })();
    """

    /// The preview web view's own channel: the head, filtered down to the tags a card needs,
    /// posted the moment the DOM is parsed. `outerHTML` rather than the values themselves so
    /// attribute escaping is WebKit's problem and the Swift parser below has exactly one
    /// input format — the same one `check()` feeds it.
    fileprivate static let metaMessageName = "vanepreviewmeta"

    fileprivate static let metaScript = """
    (function () {
      var out = [], t = document.querySelector('title');
      if (t) { out.push(t.outerHTML); }
      var m = document.querySelectorAll('meta[property],meta[name]');
      for (var i = 0; i < m.length; i++) { out.push(m[i].outerHTML); }
      webkit.messageHandlers.\(metaMessageName).postMessage(out.join(''));
    })();
    """

    // MARK: - Metadata parsing
    //
    // Plain Swift over a markup fragment, which is what makes it assertable offline against
    // a real page's real head. The web's og tags are written by hand, by templates, and by
    // plugins, so the parser assumes nothing: any quoting, any attribute order, any casing.

    struct Meta: Equatable {
        var title = ""
        var description = ""
        var image = ""
    }

    static func meta(from html: String) -> Meta {
        let s = Array(html)
        var docTitle = ""
        var og = Meta(), twitter = Meta()
        var nameDescription = ""
        var i = 0
        while i < s.count {
            guard s[i] == "<" else { i += 1; continue }
            var j = i + 1
            if j < s.count, s[j] == "/" { j += 1 }
            var name = ""
            while j < s.count, s[j].isLetter || s[j].isNumber { name.append(s[j]); j += 1 }
            let tag = name.lowercased()

            if tag == "script" || tag == "style" {
                // A page's inline scripts are full of strings that look exactly like meta
                // tags — GitHub's head ships 5KB of them. Skip the element's contents whole,
                // and land *past* the closing tag: landing on it would re-enter this branch
                // and swallow the rest of the head.
                let (_, end) = attributes(s, from: j)
                let close = find("</" + tag, in: s, from: end)
                (_, i) = attributes(s, from: min(close + tag.count + 2, s.count))
                continue
            }
            if tag == "title" {
                let (_, end) = attributes(s, from: j)
                var k = end, text = ""
                while k < s.count, s[k] != "<" { text.append(s[k]); k += 1 }
                if docTitle.isEmpty { docTitle = clean(text) }
                i = k
                continue
            }
            if tag == "meta" {
                let (a, end) = attributes(s, from: j)
                let key = (a["property"] ?? a["name"] ?? "")
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let content = clean(a["content"] ?? "")
                if !content.isEmpty {
                    // Exact keys only: `og:image:alt` is a description of the picture, not a
                    // picture, and matching it by prefix is how a card ends up showing the
                    // word "Screenshot of the app" where the art should be.
                    switch key {
                    case "og:title":            if og.title.isEmpty { og.title = content }
                    case "og:description":      if og.description.isEmpty { og.description = content }
                    case "og:image", "og:image:url", "og:image:secure_url":
                                                if og.image.isEmpty { og.image = content }
                    case "twitter:title":       if twitter.title.isEmpty { twitter.title = content }
                    case "twitter:description": if twitter.description.isEmpty { twitter.description = content }
                    case "twitter:image":       if twitter.image.isEmpty { twitter.image = content }
                    case "description":         if nameDescription.isEmpty { nameDescription = content }
                    default: break
                    }
                }
                i = end
                continue
            }
            i = max(j, i + 1)
        }
        // og first, always. It is the line the publisher wrote to be quoted elsewhere, which
        // is exactly what a preview card is; `<title>` is the line they wrote for a tab and
        // is usually carrying a site name it does not need here.
        func first(_ options: String...) -> String { options.first { !$0.isEmpty } ?? "" }
        return Meta(title: first(og.title, twitter.title, docTitle),
                    description: first(og.description, twitter.description, nameDescription),
                    image: first(og.image, twitter.image))
    }

    /// Reads `name=value` pairs from `i` up to the tag's unquoted `>`. Handles double
    /// quotes, single quotes and no quotes, tolerates a valueless attribute, and stops at
    /// the end of the input rather than running off it — a truncated head is a normal thing
    /// to be handed, not an error.
    ///
    /// Returns the attributes with lowercased names, and the index just past the `>`.
    static func attributes(_ s: [Character], from i: Int) -> ([String: String], Int) {
        var attrs: [String: String] = [:]
        var j = i
        while j < s.count {
            while j < s.count, s[j].isWhitespace { j += 1 }
            guard j < s.count else { break }
            if s[j] == ">" { j += 1; break }
            if s[j] == "/" { j += 1; continue }

            var name = ""
            while j < s.count, !s[j].isWhitespace, s[j] != "=", s[j] != ">" {
                name.append(s[j]); j += 1
            }
            var after = j
            while after < s.count, s[after].isWhitespace { after += 1 }
            guard after < s.count, s[after] == "=" else {
                if !name.isEmpty { attrs[name.lowercased()] = "" }   // a bare attribute
                continue
            }
            j = after + 1
            while j < s.count, s[j].isWhitespace { j += 1 }
            var value = ""
            if j < s.count, s[j] == "\"" || s[j] == "'" {
                let quote = s[j]
                j += 1
                while j < s.count, s[j] != quote { value.append(s[j]); j += 1 }
                if j < s.count { j += 1 }
            } else {
                while j < s.count, !s[j].isWhitespace, s[j] != ">" { value.append(s[j]); j += 1 }
            }
            if !name.isEmpty { attrs[name.lowercased()] = value }
        }
        return (attrs, j)
    }

    /// Index of `needle` (case-insensitively) at or after `from`, or the end of the input.
    private static func find(_ needle: String, in s: [Character], from: Int) -> Int {
        let n = Array(needle.lowercased())
        guard !n.isEmpty, s.count >= n.count else { return s.count }
        var i = max(0, from)
        // Compare as Strings, not Characters: `Character.lowercased()` can return more than
        // one character (İ), and `Character(_: String)` traps when handed those.
        let lowered = n.map(String.init)
        while i + n.count <= s.count {
            var k = 0
            while k < n.count, s[i + k].lowercased() == lowered[k] { k += 1 }
            if k == n.count { return i }
            i += 1
        }
        return s.count
    }

    /// Attribute values arrive escaped and often wrapped across source lines. A card wants
    /// one tidy line of prose.
    static func clean(_ s: String) -> String {
        var out = ""
        var space = false
        for ch in unescape(s) {
            if ch.isWhitespace { space = !out.isEmpty; continue }
            if space { out.append(" "); space = false }
            out.append(ch)
        }
        return out
    }

    /// ponytail: the five named entities that actually turn up in an og:description, plus
    /// numeric references. Not an entity table — `&hellip;` survives as `&hellip;`, which is
    /// a cosmetic wart on a hover card and not worth 250 lines of HTML5 named references.
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "&",
                  let semi = s[i...].firstIndex(of: ";"),
                  s.distance(from: i, to: semi) <= 10 else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            let body = String(s[s.index(after: i)..<semi])
            let replacement: String?
            switch body.lowercased() {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "nbsp": replacement = " "
            default:
                if body.hasPrefix("#") {
                    let digits = body.dropFirst()
                    let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                        ? UInt32(digits.dropFirst(), radix: 16)
                        : UInt32(digits)
                    replacement = value.flatMap { Unicode.Scalar($0).map { String(Character($0)) } }
                } else {
                    replacement = nil
                }
            }
            guard let replacement else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            out += replacement
            i = s.index(after: semi)
        }
        return out
    }

    // MARK: - Bridge
    //
    // WKUserContentController retains its handlers and WKWebView's delegates are the same
    // object here, so this holds Previews weakly — the same reason WeakHandler exists.

    @MainActor private final class Bridge: NSObject, WKNavigationDelegate, WKUIDelegate,
                                           WKScriptMessageHandler {
        weak var owner: Previews?
        init(_ owner: Previews) { self.owner = owner }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let html = m.body as? String, let web = m.webView else { return }
            owner?.received(meta: html, from: web)
        }

        func webView(_ w: WKWebView, didCommit n: WKNavigation!) { owner?.committed(w) }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { owner?.finished(w) }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { owner?.failed(w) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!,
                     withError e: Error) { owner?.failed(w) }

        /// A preview follows redirects and nothing else. No mailto:, no custom scheme
        /// handing the click to another app, no popup.
        func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction)
            async -> WKNavigationActionPolicy {
            let scheme = action.request.url?.scheme?.lowercased() ?? ""
            return scheme == "http" || scheme == "https" ? .allow : .cancel
        }

        /// Never turn a preview into a download. Engine.swift routes an attachment to the
        /// download manager; here it is simply not previewable.
        func webView(_ w: WKWebView, decidePolicyFor response: WKNavigationResponse)
            async -> WKNavigationResponsePolicy {
            let http = response.response as? HTTPURLResponse
            let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            return disposition.hasPrefix("attachment") || !response.canShowMIMEType ? .cancel : .allow
        }

        func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                     for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        /// A page that opens an alert during a preview would put a modal on screen for
        /// something the user only pointed at.
        func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                     initiatedByFrame f: WKFrameInfo) async {}
        func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String,
                     initiatedByFrame f: WKFrameInfo) async -> Bool { false }
    }

    // MARK: - Checks

    /// Offline assertions. No network, no window server, no model — everything here is the
    /// pure half: the head parser, the eligibility rules, the cache, the stream contract and
    /// the publish gate.
    static func check() -> [(String, Bool)] {
        let u = { (s: String) in URL(string: s)! }

        // A real head. Trimmed from https://github.com/apple/swift, kept exactly as served:
        // og:image ahead of og:title, the og:image:* siblings that a prefix match would trip
        // over, an inline <script>, an ampersand entity, and a <title> carrying a site name.
        let real = """
        <meta charset="utf-8">
        <script type="application/json" data-target="react-app.embeddedData">\
        {"og:description":"POISONED, this is inside a script tag"}</script>
        <title>GitHub - swiftlang/swift: The Swift Programming Language &amp; more · GitHub</title>
        <meta name="twitter:image" content="https://opengraph.githubassets.com/a3d0/swiftlang/swift" />
        <meta name="twitter:site" content="@github" />
        <meta name="twitter:card" content="summary_large_image" />
        <meta name="twitter:title" content="GitHub - swiftlang/swift: The Swift Programming Language" />
        <meta name="twitter:description" content="Contribute to swiftlang/swift development." />
        <meta property="og:image" content="https://opengraph.githubassets.com/a3d0/swiftlang/swift" />
        <meta property="og:image:alt" content="The Swift Programming Language. Contribute to swiftlang/swift." />
        <meta property="og:image:width" content="1200" />
        <meta property="og:image:height" content="600" />
        <meta property="og:site_name" content="GitHub" />
        <meta property="og:type" content="object" />
        <meta property="og:title" content="GitHub - swiftlang/swift: The Swift Programming Language" />
        <meta property="og:description" content="The Swift Programming Language &amp; friends.
              Contribute to swiftlang/swift development by creating an account on GitHub." />
        """
        let hit = meta(from: real)

        // The same page with the og block deleted — the common case on a personal site.
        let bare = """
        <meta charset="utf-8">
        <title>  Notes on   suspending tabs \u{2014} vane  </title>
        <meta name="description" content="A short note about WKWebView memory.">
        """
        let plain = meta(from: bare)

        // Nothing at all.
        let empty = meta(from: "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">")

        // Malformed, all of it seen in the wild: single quotes, content before property,
        // upper-case attribute names, an unquoted value, a meta with no content at all, and
        // a tag that is never closed because the response was truncated mid-head.
        let malformed = """
        <meta property='og:title' content='Single quoted &#39;title&#39;'>
        <META CONTENT="Reversed and shouty" PROPERTY="OG:DESCRIPTION">
        <meta property="og:site_name">
        <meta property=og:image content=https://e.test/a.png>
        <meta name="twitter:title" content="should lose to og:title"
        """
        let odd = meta(from: malformed)

        // A page whose og:description is declared but empty must fall through, not win.
        let hollow = meta(from: """
        <meta property="og:description" content="">
        <meta name="twitter:description" content="the real one">
        """)

        // Eligibility.
        let onPage = u("https://example.com/article")

        // Cache.
        var cache = Cache()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func shot(_ s: String) -> Preview {
            // A cache entry only ever holds a preview that has an image; NSImage() is enough
            // to stand in for one here and needs no window server.
            Preview(url: u(s), title: s, image: NSImage())
        }
        cache.store(shot("https://a.test/1"), key: "https://a.test/1", now: t0)
        let readback = cache.lookup("https://a.test/1", now: t0.addingTimeInterval(1))
        let live = cache.lookup("https://a.test/1", now: t0.addingTimeInterval(cacheTTL - 1)) != nil
        let expired = cache.lookup("https://a.test/1", now: t0.addingTimeInterval(cacheTTL + 1)) == nil
        // The expired lookup dropped it, so re-store before filling up.
        var full = Cache()
        for n in 0...cacheCap { full.store(shot("https://a.test/\(n)"), key: "k\(n)", now: t0) }
        let capped = full.count == cacheCap
        let evictedOldest = full.lookup("k0", now: t0) == nil
        let keptNewest = full.lookup("k\(cacheCap)", now: t0) != nil
        var repeated = Cache()
        repeated.store(shot("https://a.test/x"), key: "k", now: t0)
        repeated.store(shot("https://a.test/x"), key: "k", now: t0)

        // The publish gate. A scratch instance, so `shared` is untouched.
        let cancelled = Previews()
        let cancelledID = cancelled.begin()
        cancelled.cancel()
        cancelled.publish(shot("https://a.test/z"), for: cancelledID)

        let superseded = Previews()
        let firstID = superseded.begin()
        let secondID = superseded.begin()
        superseded.publish(shot("https://a.test/first"), for: firstID)
        let afterStale = superseded.current
        superseded.publish(shot("https://a.test/second"), for: secondID)

        let cleared = Previews()
        let clearedID = cleared.begin()
        cleared.publish(shot("https://a.test/y"), for: clearedID)
        let wasShowing = cleared.current != nil
        cleared.cancel()

        return [
            // --- metadata, real fixture
            ("og:title beats the <title> tag",
             hit.title == "GitHub - swiftlang/swift: The Swift Programming Language"),
            ("og:description is picked up across a wrapped attribute value",
             hit.description == "The Swift Programming Language & friends. Contribute to "
                + "swiftlang/swift development by creating an account on GitHub."),
            ("og:image is the image, not og:image:alt",
             hit.image == "https://opengraph.githubassets.com/a3d0/swiftlang/swift"),
            ("&amp; in an attribute value is decoded",
             hit.description.contains("Language & friends")),
            ("a meta tag written inside an inline <script> is not parsed",
             !hit.description.contains("POISONED")),

            // --- metadata, og absent
            ("with no og tags the <title> is the title",
             plain.title == "Notes on suspending tabs \u{2014} vane"),
            ("whitespace in a title is collapsed and trimmed",
             !plain.title.contains("  ") && !plain.title.hasPrefix(" ")),
            ("name=description stands in for og:description",
             plain.description == "A short note about WKWebView memory."),
            ("no image is an empty string, not a placeholder", plain.image.isEmpty),
            ("a head with nothing in it yields empty fields, not junk", empty == Meta()),

            // --- metadata, malformed
            ("single-quoted attributes parse", odd.title == "Single quoted 'title'"),
            ("&#39; numeric entities decode", odd.title.contains("'title'")),
            ("content before property parses, and the key is case-insensitive",
             odd.description == "Reversed and shouty"),
            ("an unquoted attribute value parses", odd.image == "https://e.test/a.png"),
            ("a meta declaring a property with no content at all is skipped, and does not "
             + "derail the tags after it", odd.image == "https://e.test/a.png"),
            ("a tag left unterminated by a truncated response does not eat the earlier tags",
             !odd.title.isEmpty && !odd.description.isEmpty),
            ("an og tag declared empty loses to the twitter one that has content",
             hollow.description == "the real one"),

            // --- eligibility
            ("an https link is previewable", eligible(u("https://b.test/x"), onPage: onPage)),
            ("an http link is previewable", eligible(u("http://b.test/x"), onPage: onPage)),
            ("javascript: is not", eligible(u("javascript:alert(1)"), onPage: onPage) == false),
            ("mailto: is not", eligible(u("mailto:ada@example.com"), onPage: onPage) == false),
            ("file: is not", eligible(u("file:///etc/hosts"), onPage: onPage) == false),
            ("data: is not",
             eligible(u("data:text/html,<b>x</b>"), onPage: onPage) == false),
            ("a url with no host is not", eligible(u("https:///x"), onPage: onPage) == false),
            ("the page you are already on is not previewable",
             eligible(onPage, onPage: onPage) == false),
            ("an anchor into the page you are on is not previewable",
             eligible(u("https://example.com/article#part2"), onPage: onPage) == false),
            ("a different query on the same path is previewable",
             eligible(u("https://example.com/article?page=2"), onPage: onPage)),
            ("with no current page everything http is previewable",
             eligible(u("https://b.test/x"), onPage: nil)),

            // --- cache
            ("the cache key drops the fragment",
             key(for: u("https://a.test/p#one")) == key(for: u("https://a.test/p#two"))),
            ("the cache key keeps the query",
             key(for: u("https://a.test/p?a=1")) != key(for: u("https://a.test/p?a=2"))),
            ("a stored preview reads straight back", readback?.title == "https://a.test/1"),
            ("an entry just inside the TTL is a hit", live),
            ("an entry past the TTL is a miss", expired),
            ("the cache never grows past its cap", capped),
            ("eviction drops the oldest entry", evictedOldest),
            ("eviction keeps the newest entry", keptNewest),
            ("re-storing the same key does not grow the cache", repeated.count == 1),

            // --- the stream contract
            ("stream elements are cumulative: they replace, never append",
             fold(["The", "The Swift", "The Swift Programming Language"]).text
                == "The Swift Programming Language"),
            ("a final empty element discards everything already shown",
             fold(["The Swift", "The Swift Programming Language", ""]).text.isEmpty),
            ("a discarded answer is marked as discarded",
             fold(["something", ""]).discarded),
            ("a completed answer is not marked discarded",
             fold(["something", "something whole"]).discarded == false),
            ("an empty stream means the model was never called",
             fold([]).ran == false && fold([]).text.isEmpty),
            ("a stream that yielded anything is marked as having run", fold(["a"]).ran),
            ("an empty element stops the stream being read any further",
             { var f = Fold(); return f.take("partial") && !f.take("") }()),
            ("a stream that is only the empty element still counts as having run",
             fold([""]).ran && fold([""]).text.isEmpty),

            // --- the publish gate
            ("a cancelled request publishes nothing", cancelled.current == nil),
            ("a superseded request publishes nothing", afterStale == nil),
            ("the live request does publish", superseded.current?.title == "https://a.test/second"),
            ("a stale id is refused without cancelling anything",
             stale(request: 1, latest: 2) && !stale(request: 2, latest: 2)),
            ("cancel clears what was already on screen",
             wasShowing && cleared.current == nil),
        ]
    }
}
