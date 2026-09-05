import AppKit
import SwiftUI
import WebKit

/// Arc's Peek: a link clicked in a Favourite or a Pinned tab that leads somewhere *else*
/// opens in a floating page over the window instead of navigating the tab.
///
/// The reason is what those two sections are for. A favourite or a pinned tab is a place —
/// Gmail, Linear, the team's Notion — and it is supposed to still be on that place when you
/// come back to it tomorrow. Following a link out of one and letting it navigate turns the
/// place into a page: the tile that said "Gmail" now says "some article somebody linked",
/// and the only way back is the back button. So the link is shown *over* the window, the
/// tab stays where it was, and the user chooses: read it and press Escape, or ⌘O and keep
/// it as a real tab. A link to the same site is not that — clicking a message inside Gmail
/// is using Gmail — so same-site links navigate the way they always did.
///
/// ponytail: one Peek at a time, a child window rather than a sheet or an in-window overlay.
/// A child window gets a real WKWebView with its own first responder, moves with the parent
/// for free (`addChildWindow`), and is the same shape as `LittleArc` — which is why the two
/// share this file's neighbour rather than each growing their own hand-off. Ceiling: two
/// Peeks cannot be open at once; opening a second replaces the first, and the first is what
/// Reopen Last Peek brings back.
@MainActor enum Peek {

    /// Where the Settings › Links toggle is written. `Prefs.peekLinks` reads it; the pane's
    /// `@AppStorage` writes it. One spelling, so the two cannot drift.
    static let prefKey = "peekLinks"

    // MARK: - Routing

    /// What a link click does.
    enum Decision: Equatable, Sendable {
        /// The tab goes there, the way every link always has.
        case navigate
        /// It opens over the window instead.
        case peek
    }

    /// The whole rule, as a pure function of the click. `nonisolated` so `selfcheck --pure`
    /// can prove the table without a window server.
    ///
    /// - `enabled` is Settings › Links. Off means off: no link peeks, ⇧-click included, so
    ///   the toggle has one meaning rather than "mostly off".
    /// - Only http(s) can peek. A `mailto:` or a custom scheme is handed to the system by
    ///   the layer above; putting it in a browser window would show an error page.
    /// - ⇧-click is the explicit gesture and beats the same-site rule: it is how you peek a
    ///   link that would otherwise have navigated.
    /// - A Today tab is a page you are already reading, not a place you keep. Its links
    ///   navigate, cross-site or not — this is the difference the sections exist for.
    nonisolated static func route(sourceKind: TabKind, from: URL, to: URL,
                                  modifiers: NSEvent.ModifierFlags, enabled: Bool) -> Decision {
        guard enabled, let scheme = to.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .navigate }
        if modifiers.contains(.shift) { return .peek }
        guard sourceKind != .today else { return .navigate }
        return sameSite(from, to) ? .navigate : .peek
    }

    /// Whether two urls are the same site — the question `WKWebsiteDataRecord` answers, and
    /// the one that decides whether a link is still "inside" the place a tab is kept on.
    /// It is a comparison of hosts, not of origins: the scheme and the port are deliberately
    /// ignored, so http→https and `:8000`→`:8001` are the same site and stay in the tab.
    /// A url with no host is nobody's site, itself included.
    nonisolated static func sameSite(_ a: URL, _ b: URL) -> Bool {
        guard let x = registrable(a), let y = registrable(b) else { return false }
        return x == y
    }

    /// The registrable domain of a url's host: `mail.example.com` → `example.com`.
    ///
    /// ponytail: the last two labels, with no public suffix list. That reads `a.co.uk` and
    /// `b.co.uk` as one site, so a link between them navigates instead of peeking — the
    /// direction that does nothing surprising, since navigating is what every browser did
    /// before this existed. Upgrade path: ship the PSL and key this on it, the way
    /// `SiteControl.covers` would also then be spelled.
    ///
    /// An address literal has no labels to trim: `127.0.0.1` is a host, not a subdomain of
    /// `0.1`, and trimming it made every port on the loopback a different site from every
    /// other. Testing for all-numeric labels catches IPv4; IPv6 arrives bracketed, with no
    /// dots to split on, and falls out of the label count.
    nonisolated static func registrable(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count > 2, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    // MARK: - The live Peek

    /// One at a time. Held here rather than on the window so ⌘O, Escape and the scrim all
    /// act on the same thing without walking AppKit's window list.
    private(set) static var live: Session?

    /// True for a store whose window is a Peek. `LittleArc.stores` asks, because a Peek is
    /// built on the same one-page store and must not be answered for by ⌘O's "hand this to
    /// a Space" or by Window ▸ Hide All Little Arc Windows.
    ///
    /// Asked of the window rather than of `live`, which is already nil through the 150ms a
    /// Peek spends springing out — long enough for the store it belongs to to look, briefly,
    /// like a Little Arc.
    static func owns(_ store: TabStore) -> Bool { store.window is PeekWindow }

    /// Everything a Peek needs to put its page back where it came from.
    @MainActor final class Session {
        /// The one-page store, exactly as a Little Arc's.
        let store: TabStore
        /// The window it floats over, and the tab the link was clicked in — ⌘O puts the
        /// page beside that tab, not at the bottom of the list.
        let parent: TabStore
        let source: Tab.ID
        let window: PeekWindow
        /// Drives the spring: false for the first frame and again on the way out.
        let shown = Shown()
        var watchers: [NSObjectProtocol] = []
        init(store: TabStore, parent: TabStore, source: Tab.ID, window: PeekWindow) {
            self.store = store; self.parent = parent; self.source = source; self.window = window
        }
    }

    /// The one bit of state SwiftUI has to see. A class so `Peek` can set it from outside the
    /// view tree — which is what makes the close animation run before the window goes.
    @MainActor final class Shown: ObservableObject { @Published var on = false }

    /// Split View is not merged yet. When it is, it sets `addToSplit` and the Peek's bar
    /// grows the button Arc has there; until then there is nothing to add a pane to, and a
    /// button that cannot work is worse than no button.
    ///
    /// Published rather than a bare `static var`: a plain one read inside `body` is not a
    /// dependency of anything, so a Peek already on screen when Split View wires itself up
    /// would never redraw its bar.
    @MainActor final class Splitting: ObservableObject {
        @Published var add: ((URL) -> Void)?
    }
    static let splitting = Splitting()
    static var addToSplit: ((URL) -> Void)? {
        get { splitting.add }
        set { splitting.add = newValue }
    }

    // MARK: - Opening

    /// Put `url` over the window `source` lives in. `parked` is set only when a closed Peek
    /// is being brought back, so it returns on the page it was left on rather than reloading.
    static func open(_ url: URL, from source: Tab, in parent: TabStore, parked: Parked? = nil) {
        guard let host = parent.window else { return }
        close(animated: false)                      // one at a time

        // A Peek is a page of the window it floats over, so it is private exactly when that
        // window is: nothing peeked out of a Private Window reaches history or the disk.
        let store = LittleArc.floatingStore(parked == nil ? url : nil,
                                            profileID: parent.profileID,
                                            isPrivate: parent.isPrivate)
        // A store made with no url comes up empty with the new-tab bar over it, which is
        // right for ⌘T and wrong here: the page is not new, it is the one being put back.
        if let parked {
            let tab = store.newBlankTab()
            tab.park(url: url, parked)
            tab.resume()
            store.palette = nil
        }

        let window = PeekWindow(contentRect: host.frame, styleMask: [.borderless, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false         // see LittleArc.open: ARC over-releases it
        window.isOpaque = false
        window.backgroundColor = .clear
        // The card draws its own shadow, inset from the window's edges; the window's would
        // be a rectangle around the scrim.
        window.hasShadow = false
        window.animationBehavior = .none            // the spring below is the animation

        let session = Session(store: store, parent: parent, source: source.id, window: window)
        window.contentView = NSHostingView(rootView: PeekView(shown: session.shown)
            .environmentObject(store)
            .environmentObject(ProfileManager.shared))
        store.window = window
        // The window tears its own page down when it closes, whoever closed it — so a Peek
        // taken away by AppKit (the parent going, the app quitting) leaves no WebContent
        // process and no stray store behind.
        window.delegate = window
        live = session

        // `.above` and a child of the browser window: it travels with it across Spaces and
        // desktops, and stays over it without a level that would also put it over every
        // other app.
        host.addChildWindow(window, ordered: .above)
        window.setFrame(host.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        // The window covers the parent exactly, so a resize has to be followed; a *move* is
        // AppKit's job once the window is a child. The parent closing takes the Peek with it.
        //
        // `queue: nil`, not `.main`: a queued block runs on some later turn of the run loop,
        // by which time the window that posted `willClose` is gone and there is nothing left
        // to take the Peek off. Synchronous delivery on the poster's thread — which is the
        // main thread, since these are AppKit notifications — is the whole point here.
        let centre = NotificationCenter.default
        session.watchers = [
            centre.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: nil) { _ in
                MainActor.assumeIsolated { live?.window.setFrame(host.frame, display: true) }
            },
            centre.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: nil) { _ in
                MainActor.assumeIsolated {
                    close(animated: false)
                    // …and there is no longer a window to put one back into.
                    lastClosed = nil
                }
            },
        ]

        withAnimation(Motion.reduced ? nil : Look.list) { session.shown.on = true }
        axAnnounce("Peeking \(url.host() ?? url.absoluteString). Press Escape to close, "
                   + "\u{2318}O to open it as a tab.")
    }

    /// Where the Peek came from and what was in it, kept so it can be put back.
    ///
    /// The parent is held **weakly**. A strong one outlived every window it named: a closed
    /// Peek pinned the whole browser window's store — its tabs, their WebContent processes,
    /// its history handle — for as long as the app ran, because nothing ever cleared this.
    /// Weak plus the three places that nil it (the parent going, ⌘O handing the page over,
    /// and the grace running out) means the last Peek costs a url and a snapshot.
    private struct Closed {
        let url: URL
        let page: Parked
        let source: Tab.ID
        weak var parent: TabStore?
        let at: Date
    }
    private static var lastClosed: Closed?

    // MARK: - Closing

    /// Springs out, then really goes. `animated: false` is for the paths where there is
    /// nothing left to animate over: the parent window closing, or a second Peek replacing
    /// this one.
    static func close(animated: Bool = true) {
        guard let session = live else { return }
        live = nil
        session.watchers.forEach(NotificationCenter.default.removeObserver)
        if let tab = session.store.active, let url = tab.currentURL {
            lastClosed = Closed(url: url, page: tab.snapshot, source: session.source,
                                parent: session.parent, at: .now)
        }
        guard animated, !Motion.reduced else { return dismantle(session) }
        withAnimation(Look.appear) { session.shown.on = false }
        Task {
            try? await Task.sleep(for: .seconds(Look.appearDuration))
            dismantle(session)
        }
    }

    /// Let go of the window. The page is taken down by `tearDown`, which the window's own
    /// `windowWillClose` calls — so it happens on this path and on every path AppKit takes
    /// without asking us first.
    private static func dismantle(_ session: Session) {
        session.window.parent?.removeChildWindow(session.window)
        session.window.close()
    }

    /// Everything `LittleArc.Delegate` does when its window closes, minus the traffic lights
    /// a borderless window does not have. Idempotent: the second call finds no store.
    static func tearDown(_ window: PeekWindow) {
        if live?.window === window {
            live?.watchers.forEach(NotificationCenter.default.removeObserver)
            live = nil
        }
        guard let store = TabStore.all.first(where: { $0.window === window }) else { return }
        store.tabs.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
    }

    /// A Peek whose navigation was cancelled before anything committed — the link turned out
    /// to be a download, or WebKit refused it — has an empty card and no way to fill it.
    /// Called from `Tab`'s download and failure delegates.
    static func dismissIfBlank(_ tab: Tab) {
        guard let live, live.store.tabs.contains(where: { $0 === tab }), tab.web.url == nil
        else { return }
        close(animated: false)
        lastClosed = nil          // never a page; reopening would only bring the blank back
    }

    // MARK: - ⌘O

    /// Arc's "Open as tab": the page becomes a real tab beside the one the link was clicked
    /// in, on the same page with the same back/forward list — `park` + `resume`, the hand-off
    /// `LittleArc.move` uses.
    static func openAsTab() {
        guard let session = live, let page = LittleArc.page(of: session.store) else { return }
        let target = session.parent
        let moved = target.newTabBeside(session.source)
        live = nil                                  // the hand-off closes it; don't re-arm reopen
        session.watchers.forEach(NotificationCenter.default.removeObserver)
        // The page is not gone, it is a tab — so there is nothing to bring back, and
        // nothing here to keep the parent's store alive after the tab already does.
        lastClosed = nil
        LittleArc.hand(page, into: moved, of: target, from: session.store, saying: "Opened as a tab.")
        dismantle(session)
    }

    // MARK: - Reopen

    /// Whether Archive ▸ Reopen Last Peek has anything to do: one was closed a moment
    /// ago, none is up now, and the window and tab it belongs to are both still there.
    static var canReopen: Bool { recoverable != nil }

    /// The record, if it is still good for anything — and dropped where it is not, so a
    /// stale one never sits there holding on to a window it can no longer use.
    private static var recoverable: (Closed, TabStore, Tab)? {
        guard let last = lastClosed, live == nil else { return nil }
        guard let parent = last.parent, Date.now.timeIntervalSince(last.at) < Look.peekReopen,
              let source = parent.tabs.first(where: { $0.id == last.source })
        else { lastClosed = nil; return nil }
        return (last, parent, source)
    }

    /// Bring the last Peek back. Arc's undo is exactly this narrow: it is for the Escape you
    /// did not mean, not a history of everything you have ever peeked.
    ///
    /// ponytail: a menu item with no key equivalent, where Arc has ⌘Z and ⇧⌘T. ⇧⌘T is
    /// Reopen Closed Tab and is not ours to take. ⌘Z inside a browser window is almost
    /// always the page's: a WKWebView owns the responder chain the whole time a page is on
    /// screen, so "only when nothing is being typed into" cannot be answered synchronously
    /// from a key event, and the honest version of that guard swallowed the undo of every
    /// draft anyone was writing. Ceiling: it stays a menu item until something tracks the
    /// page's own editing focus; Settings ▸ Shortcuts can bind a key to it meanwhile.
    @discardableResult
    static func reopen() -> Bool {
        guard let (last, parent, source) = recoverable else { return false }
        lastClosed = nil
        open(last.url, from: source, in: parent, parked: last.page)
        return true
    }

    // MARK: - Keys

    /// Escape and ⌘O, and only inside a Peek that is the key window. Taken before the
    /// keybinding registry, the way `LittleArc.handleKey` is, because both mean something
    /// else in a window with a sidebar. ⌘W is not here: `TabStore.closeOrArchive` already
    /// calls `performClose`, which `PeekWindow` overrides.
    ///
    /// Nothing here fires while no Peek is up, so this costs one comparison on the app's
    /// key path and can never take a key away from anything else. Reopening is a menu item
    /// rather than a shortcut — see `reopen`.
    static func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let session = live, session.window.isKeyWindow
        else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // The browser window's own order, kept: Escape stops a page that is still coming
        // in, and only closes the thing it is in once there is nothing left to stop.
        if event.keyCode == 53, mods.isEmpty {
            if !TabActions.stopLoading(in: session.window) { close() }
            return true
        }
        if mods == [.command], event.charactersIgnoringModifiers?.lowercased() == "o" {
            openAsTab()
            return true
        }
        return false
    }
}

// MARK: - The window

/// Borderless, so there are no traffic lights and no title bar over the card — and key, so
/// the page inside can be typed into. A borderless NSWindow refuses key by default.
///
/// Its own delegate: the only thing a Peek's window has to hear is its own close, and one
/// object is cheaper than a kept-delegates array for something there is at most one of.
final class PeekWindow: NSWindow, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    /// ⌘W arrives here through `TabStore.closeOrArchive`, which a Peek's store answers as a
    /// Little Arc's does. AppKit's own `performClose` beeps on a window with no close button.
    override func performClose(_ sender: Any?) { MainActor.assumeIsolated { Peek.close() } }
    /// However this window came to be closing — our own close, the app quitting, AppKit
    /// taking it with its parent — the page goes down and the store stops being one of
    /// `TabStore.all`.
    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { Peek.tearDown(self) }
    }
}

// MARK: - The view

/// The scrim and the floating page over it. The window covers the parent exactly, so the
/// card's size is a fraction of this view rather than arithmetic anyone has to redo on a
/// resize.
private struct PeekView: View {
    @ObservedObject var shown: Peek.Shown
    @EnvironmentObject var store: TabStore

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dims the window behind, and is the click target that closes: everywhere
                // outside the card is "I'm done with this". A real Button, not a tap
                // gesture on a shape — a gesture is invisible to VoiceOver and to Full
                // Keyboard Access, so the trait said "button" for something nothing but a
                // mouse could press.
                Button { Peek.close() } label: {
                    Look.peekScrim.opacity(shown.on ? 1 : 0).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Peek")
                .accessibilityHint("Closes the page floating over the window.")
                card
                    .frame(width: geo.size.width * Look.peekFraction,
                           height: geo.size.height * Look.peekFraction)
                    .scaleEffect(shown.on ? 1 : Look.appearScale)
                    .opacity(shown.on ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .onAppear { store.applySpaceAppearance() }
    }

    private var card: some View {
        Group {
            if let tab = store.active {
                WebView(web: tab.web).id(tab.id)
            } else {
                Color.clear
            }
        }
        // A floating surface over the whole window, like the command bar — so it takes the
        // command bar's corner and its shadow rather than inventing a second pair.
        .clipShape(.rect(cornerRadius: Look.barRadius))
        .shadow(color: Look.barShadow, radius: Look.barShadowRadius, y: Look.barShadowY)
        // Above the card's top-right corner, over the scrim: chrome for the card, not
        // something sitting on the page the way a find bar does.
        .overlay(alignment: .topTrailing) {
            PeekBar().offset(y: -(Look.topRow + Look.inset))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Peek")
        // The window behind is dimmed and one click from being uncovered: to a screen
        // reader that is a sheet, and reading the page under it as if it were still in play
        // would be a lie about what a click does.
        .accessibilityAddTraits(.isModal)
    }
}

/// The Peek's whole chrome: open it as a tab, add it to a split once there is one, close it.
private struct PeekBar: View {
    /// Not `Peek.addToSplit` read straight: see `Peek.Splitting`.
    @ObservedObject private var splitting = Peek.splitting

    var body: some View {
        HStack(spacing: Look.inset) {
            if let addToSplit = splitting.add {
                PeekButton("square.split.2x1", "Add to Split") {
                    if let url = Peek.live?.store.active?.currentURL { addToSplit(url) }
                }
            }
            PeekButton("arrow.up.forward.app", "Open as Tab (\u{2318}O)") { Peek.openAsTab() }
            PeekButton("xmark", "Close Peek (Esc)") { Peek.close() }
        }
        .accessibilityElement(children: .contain)
    }
}

/// One glyph on that bar. The sidebar's own button: `pillFill` at rest, the selection's step
/// under the pointer, `pillRadius` around it.
private struct PeekButton: View {
    let symbol: String
    let label: String
    let act: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ symbol: String, _ label: String, _ act: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.act = act
    }

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(Look.pillGlyph)
                .foregroundStyle(Look.inkPrimary)
                .frame(width: Look.topRow, height: Look.topRow)
                .background(hovering ? Look.selected : Look.pillFill,
                            in: .rect(cornerRadius: Look.pillRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - check

extension Peek {
    /// The routing table, proved offline. These are the sentences the feature is: a place
    /// you keep stays on its page, a page you are reading follows its links.
    nonisolated static func check() -> [(String, Bool)] {
        let gmail = URL(string: "https://mail.google.com/mail/u/0")!
        let inbox = URL(string: "https://mail.google.com/mail/u/0/#inbox")!
        let drive = URL(string: "https://drive.google.com/drive/my-drive")!
        let news = URL(string: "https://example.com/story")!
        let mailto = URL(string: "mailto:ada@example.com")!
        let plain = NSEvent.ModifierFlags()
        let shift = NSEvent.ModifierFlags.shift

        func go(_ kind: TabKind, _ from: URL, _ to: URL,
                _ mods: NSEvent.ModifierFlags = plain, on: Bool = true) -> Decision {
            route(sourceKind: kind, from: from, to: to, modifiers: mods, enabled: on)
        }

        return [
            ("a link inside the same site navigates the favourite, it does not peek",
             go(.favourite, gmail, inbox) == .navigate),
            ("…and a subdomain of it is still the same site",
             go(.favourite, gmail, drive) == .navigate),
            ("a link out of a favourite to another site peeks",
             go(.favourite, gmail, news) == .peek),
            ("…and so does one out of a pinned tab",
             go(.pinned, gmail, news) == .peek),
            ("a Today tab is a page you are reading: its links navigate, same site or not",
             go(.today, gmail, news) == .navigate && go(.today, gmail, inbox) == .navigate),
            ("\u{21E7}-click peeks from any section",
             go(.today, gmail, news, shift) == .peek && go(.pinned, gmail, news, shift) == .peek),
            ("…including a link that would otherwise have navigated in place",
             go(.favourite, gmail, inbox, shift) == .peek),
            ("with the preference off nothing peeks, \u{21E7}-click included",
             go(.favourite, gmail, news, on: false) == .navigate
                && go(.favourite, gmail, news, shift, on: false) == .navigate),
            ("a mailto: link never peeks — it is the system's to open",
             go(.pinned, gmail, mailto) == .navigate
                && go(.pinned, gmail, mailto, shift) == .navigate),
            ("neither does a file: url",
             go(.pinned, gmail, URL(fileURLWithPath: "/etc/hosts")) == .navigate),
            ("http peeks as well as https — a link off a pinned tab is a link",
             go(.pinned, gmail, URL(string: "http://example.com/")!) == .peek),
            ("a port is not a site: two servers on one host stay in the tab",
             sameSite(URL(string: "http://127.0.0.1:8000/a")!,
                      URL(string: "http://127.0.0.1:8001/b")!)),
            ("…and neither is the scheme: an http→https link is not a link off the site",
             sameSite(URL(string: "http://example.com/a")!,
                      URL(string: "https://example.com/b")!)),
            ("…but two hosts are two sites, however local",
             !sameSite(URL(string: "http://127.0.0.1:8000/a")!,
                       URL(string: "http://localhost:8001/b")!)),
            ("the registrable domain is the last two labels",
             registrable(drive) == "google.com" && registrable(news) == "example.com"),
            ("a bare host is its own registrable domain",
             registrable(URL(string: "http://localhost:8000/")!) == "localhost"),
            ("an address literal is a host, not a subdomain of its last two numbers",
             registrable(URL(string: "http://127.0.0.1:8000/")!) == "127.0.0.1"),
            ("…so two addresses on one subnet are still two sites",
             !sameSite(URL(string: "http://10.0.0.1/")!, URL(string: "http://10.0.0.2/")!)),
            ("a hostname that merely starts with digits is still trimmed",
             registrable(URL(string: "http://1.cdn.example.com/")!) == "example.com"),
            ("a url with no host has none", registrable(URL(string: "about:blank")!) == nil),
            ("…and no host is never the same site as anything, itself included",
             !sameSite(URL(string: "about:blank")!, URL(string: "about:blank")!)),
            ("a peek fills most of the window but not all of it",
             Look.peekFraction > 0.5 && Look.peekFraction < 1),
            ("the offer to reopen stands for a moment, not for a session",
             Look.peekReopen > 1 && Look.peekReopen < 60),
        ]
    }
}
