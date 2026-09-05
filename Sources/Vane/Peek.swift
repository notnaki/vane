import AppKit
import SwiftUI

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
/// ⌘Z brings back.
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

    /// Whether two urls are the same site, which is the same question `WKWebsiteDataRecord`
    /// answers: the registrable domain, so `mail.example.com` and `example.com` are one site
    /// and `example.com` and `example.org` are two.
    ///
    /// ponytail: the last two labels, with no public suffix list. That reads `a.co.uk` and
    /// `b.co.uk` as one site, so a link between them navigates instead of peeking — the
    /// direction that does nothing surprising, since navigating is what every browser did
    /// before this existed. Upgrade path: ship the PSL and key this on it, the way
    /// `SiteControl.covers` would also then be spelled.
    nonisolated static func sameSite(_ a: URL, _ b: URL) -> Bool {
        guard let x = registrable(a), let y = registrable(b) else { return false }
        return x == y
    }

    nonisolated static func registrable(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    // MARK: - The live Peek

    /// One at a time. Held here rather than on the window so ⌘O, Escape and the scrim all
    /// act on the same thing without walking AppKit's window list.
    private(set) static var live: Session?

    /// True for the store behind the Peek that is up. `LittleArc.stores` asks, because a
    /// Peek is built on the same one-page store and must not be answered for by ⌘O's
    /// "hand this to a Space" or by Window ▸ Hide All Little Arc Windows.
    static func owns(_ store: TabStore) -> Bool { live?.store === store }

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

    /// Split View is not merged yet. When it is, it sets this and the Peek's bar grows the
    /// button Arc has there; until then there is nothing to add a pane to, and a button that
    /// cannot work is worse than no button.
    static var addToSplit: ((URL) -> Void)?

    // MARK: - Opening

    /// Put `url` over the window `source` lives in. `parked` is set only when a closed Peek
    /// is being brought back, so it returns on the page it was left on rather than reloading.
    static func open(_ url: URL, from source: Tab, in parent: TabStore, parked: Parked? = nil) {
        guard let host = parent.window else { return }
        close(animated: false)                      // one at a time

        let store = LittleArc.floatingStore(parked == nil ? url : nil, profileID: parent.profileID)
        if let parked { store.tabs.first?.park(url: url, parked); store.tabs.first?.resume() }

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
        live = session

        // `.above` and a child of the browser window: it travels with it across Spaces and
        // desktops, and stays over it without a level that would also put it over every
        // other app.
        host.addChildWindow(window, ordered: .above)
        window.setFrame(host.frame, display: true)
        window.makeKeyAndOrderFront(nil)

        // The window covers the parent exactly, so a resize has to be followed; a *move* is
        // AppKit's job once the window is a child. The parent closing takes the Peek with it.
        let centre = NotificationCenter.default
        session.watchers = [
            centre.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { _ in
                MainActor.assumeIsolated { live?.window.setFrame(host.frame, display: true) }
            },
            centre.addObserver(forName: NSWindow.willCloseNotification, object: host, queue: .main) { _ in
                MainActor.assumeIsolated { close(animated: false) }
            },
        ]

        withAnimation(Motion.reduced ? nil : Look.list) { session.shown.on = true }
        axAnnounce("Peeking \(url.host() ?? url.absoluteString). Press Escape to close, "
                   + "\u{2318}O to open it as a tab.")
    }

    /// Where the Peek came from and what was in it, kept so ⌘Z can put it back. Cleared once
    /// it is stale — see `Look.peekReopen`.
    private static var lastClosed: (url: URL, page: Parked, source: Tab.ID,
                                    parent: TabStore, at: Date)?

    // MARK: - Closing

    /// Springs out, then really goes. `animated: false` is for the paths where there is
    /// nothing left to animate over: the parent window closing, or a second Peek replacing
    /// this one.
    static func close(animated: Bool = true) {
        guard let session = live else { return }
        live = nil
        session.watchers.forEach(NotificationCenter.default.removeObserver)
        if let tab = session.store.active, let url = tab.currentURL {
            lastClosed = (url, tab.snapshot, session.source, session.parent, .now)
        }
        guard animated, !Motion.reduced else { return dismantle(session) }
        withAnimation(Look.appear) { session.shown.on = false }
        Task {
            try? await Task.sleep(for: .seconds(Look.appearDuration))
            dismantle(session)
        }
    }

    /// Take the page down and let go of the window. Everything `LittleArc.Delegate` does on
    /// close, minus the traffic lights a borderless window does not have.
    private static func dismantle(_ session: Session) {
        session.store.tabs.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === session.store }
        session.window.parent?.removeChildWindow(session.window)
        session.window.close()
    }

    // MARK: - ⌘O

    /// Arc's "Open as tab": the page becomes a real tab beside the one the link was clicked
    /// in, on the same page with the same back/forward list — `park` + `resume`, the hand-off
    /// `LittleArc.move` uses.
    static func openAsTab() {
        guard let session = live, let page = LittleArc.page(of: session.store) else { return }
        let target = session.parent
        let moved = target.newTabBeside(session.source)
        live = nil                                  // the hand-off closes it; don't re-arm ⌘Z
        session.watchers.forEach(NotificationCenter.default.removeObserver)
        LittleArc.hand(page, into: moved, of: target, from: session.store, saying: "Opened as a tab.")
        dismantle(session)
    }

    // MARK: - ⌘Z / ⇧⌘T

    /// Bring the last Peek back, if it was closed a moment ago. Arc's undo is exactly that
    /// narrow: it is for the Escape you did not mean, not a history of everything you have
    /// ever peeked.
    static func reopen() -> Bool {
        guard let last = lastClosed, Date.now.timeIntervalSince(last.at) < Look.peekReopen,
              let source = last.parent.tabs.first(where: { $0.id == last.source })
        else { return false }
        lastClosed = nil
        open(last.url, from: source, in: last.parent, parked: last.page)
        return true
    }

    // MARK: - Keys

    /// Escape and ⌘O inside a Peek, plus ⌘Z / ⇧⌘T just after one closed. Taken before the
    /// keybinding registry, the way `LittleArc.handleKey` is, because all four mean
    /// something else in a window with a sidebar. ⌘W is not here: `TabStore.closeOrArchive`
    /// already calls `performClose`, which `PeekWindow` overrides.
    ///
    /// ponytail ceiling: ⌘Z within `Look.peekReopen` seconds of a close reopens the Peek
    /// rather than undoing whatever the page's own editor was doing. Arc collides the same
    /// way; the guard is the grace period, and a text field that owns the responder chain
    /// keeps its own undo.
    static func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if live != nil {
            if event.keyCode == 53, mods.isEmpty, isKey { close(); return true }
            if key == "o", mods == [.command], isKey { openAsTab(); return true }
        }
        guard mods == [.command] && key == "z" || mods == [.command, .shift] && key == "t",
              !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
        return reopen()
    }

    /// True while the Peek is the window the keys are going to. A key pressed in another
    /// window is not aimed at the Peek, however far in front it is drawn.
    private static var isKey: Bool { live?.window.isKeyWindow == true }
}

// MARK: - The window

/// Borderless, so there are no traffic lights and no title bar over the card — and key, so
/// the page inside can be typed into. A borderless NSWindow refuses key by default.
final class PeekWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    /// ⌘W arrives here through `TabStore.closeOrArchive`, which a Peek's store answers as a
    /// Little Arc's does. AppKit's own `performClose` beeps on a window with no close button.
    override func performClose(_ sender: Any?) { MainActor.assumeIsolated { Peek.close() } }
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
                // outside the card is "I'm done with this".
                Look.scrim
                    .opacity(shown.on ? 1 : 0)
                    .contentShape(.rect)
                    .onTapGesture { Peek.close() }
                    .accessibilityLabel("Close Peek")
                    .accessibilityAddTraits(.isButton)
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
    }
}

/// The Peek's whole chrome: open it as a tab, add it to a split once there is one, close it.
private struct PeekBar: View {
    var body: some View {
        HStack(spacing: Look.inset) {
            if Peek.addToSplit != nil {
                PeekButton("square.split.2x1", "Add to Split") {
                    if let url = Peek.live?.store.active?.currentURL { Peek.addToSplit?(url) }
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
            ("…but two hosts are two sites, however local",
             !sameSite(URL(string: "http://127.0.0.1:8000/a")!,
                       URL(string: "http://localhost:8001/b")!)),
            ("the registrable domain is the last two labels",
             registrable(drive) == "google.com" && registrable(news) == "example.com"),
            ("a bare host is its own registrable domain",
             registrable(URL(string: "http://localhost:8000/")!) == "localhost"),
            ("a url with no host has none", registrable(URL(string: "about:blank")!) == nil),
            ("…and no host is never the same site as anything, itself included",
             !sameSite(URL(string: "about:blank")!, URL(string: "about:blank")!)),
            ("a peek fills most of the window but not all of it",
             Look.peekFraction > 0.5 && Look.peekFraction < 1),
            ("\u{2318}Z's grace is a moment, not a session",
             Look.peekReopen > 1 && Look.peekReopen < 60),
        ]
    }
}
