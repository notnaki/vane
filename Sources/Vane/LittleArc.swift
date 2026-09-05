import AppKit
import SwiftUI

/// Arc's "Little Arc": a link from another app opens in a small floating window with one
/// page and one row of chrome, instead of landing as a tab in whatever window happened to
/// be in front. The bet is that most links from Mail, Slack or Terminal are read once and
/// closed — putting them in the sidebar makes the user tidy up after every message they
/// read. ⌘W throws it away; "Open in ▸" is the one gesture that says "actually, keep this",
/// and only then does it become a tab in a Space.
///
/// It is the same browser: the same profile, cookies, history and extensions. What it is
/// not is a *window of the profile* — it restores no favourites, holds no Space, and is
/// never written into the session (`TabStore.isLittle`), so closing it leaves nothing
/// behind and quitting with three of them open does not bring three of them back.
///
/// ponytail: `VaneWindow` unchanged rather than a subclass — everything it does (holding
/// the traffic lights on `Look.lightsCentre`, dragging by bare ground, Escape stopping a
/// load) is exactly what this window wants, and Little Arc's own row is laid out to put
/// its pill on that same line. A window is identified as a Little Arc by its store, not by
/// its class.
@MainActor enum LittleArc {

    // MARK: - Routing

    /// Where a url from another app goes.
    enum Route: Equatable, Sendable {
        case little
        /// A tab in the window that is already open.
        case tab
        /// Nothing is open — the link is the reason to open a window at all.
        case newWindow
    }

    /// The whole decision, as a pure function of the preference and whether there is an
    /// ordinary window to add a tab to. `nonisolated` so `selfcheck --pure` can prove the
    /// table without a window server.
    ///
    /// Little Arc does not care whether a window is open: it is a window of its own, and
    /// Arc opens one either way. "Current Space" does — with nothing open there is no
    /// current Space, and the link becomes the window's first tab.
    nonisolated static func route(preferLittle: Bool, hasWindow: Bool) -> Route {
        if preferLittle { return .little }
        return hasWindow ? .tab : .newWindow
    }

    // MARK: - Opening

    /// One url, one window. Called once per url, so three links arriving together are three
    /// Little Arcs — which is what Arc does, and what "one page per window" means.
    /// `url` is nil for a Little Arc opened with nothing in it — ⌘T from inside one, which
    /// comes up empty with the search bar over it, the same as a new window does.
    @discardableResult
    static func open(_ url: URL?) -> TabStore {
        let profile = ProfileManager.shared.active
        let store = floatingStore(url, profileID: profile.id)

        let window = VaneWindow(
            contentRect: NSRect(x: 0, y: 0, width: Look.littleWidth, height: Look.littleHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Little Arc"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Same trick as `Windows.open`: an empty compact toolbar gets AppKit's own idea of
        // where the lights go near enough to `Look.lightsCentre` that the first frame does
        // not jump before `centreTrafficLights` runs.
        window.toolbar = NSToolbar(identifier: "VaneEmpty")
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        // A window made in code is `isReleasedWhenClosed` by default, which under ARC is an
        // over-release: closing one crashed in `-[_NSWindowTransformAnimation dealloc]`,
        // the close animation reaching a window that had already been freed. `SettingsWindow`
        // turns it off for the same reason.
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        window.contentView = NSHostingView(rootView: LittleArcView()
            .environmentObject(store)
            .environmentObject(ProfileManager.shared))
        // Centred, and cascading from there once there is more than one — deliberately no
        // frame autosave: a Little Arc is not a window the user arranges, it is one that
        // appears in the middle of the screen with the thing they clicked in it.
        window.center()
        // Two links from the same message must not land exactly on top of each other, and
        // the tenth must not be off the bottom of the screen: the step is dropped as soon as
        // the whole window would no longer fit, which starts the pile again from the centre.
        // ponytail: not `cascadeTopLeft(from:)` — that puts the window *at* the point it is
        // given, so handing it the last window's corner stacked the two exactly.
        if let previous = windows.last, let screen = window.screen ?? NSScreen.main {
            let step = Look.inset * 3
            let next = NSPoint(x: previous.frame.minX + step, y: previous.frame.maxY - step)
            let landing = NSRect(x: next.x, y: next.y - window.frame.height,
                                 width: window.frame.width, height: window.frame.height)
            if screen.visibleFrame.contains(landing) { window.setFrameTopLeftPoint(next) }
        }

        let delegate = Delegate(store)
        keptDelegates.append(delegate)
        window.delegate = delegate
        store.window = window
        window.makeKeyAndOrderFront(nil)
        // The Window menu names what its toggle will do, and that just changed.
        rebuild()
        return store
    }

    // MARK: - One page, no furniture

    /// The store behind a floating one-page window: no sidebar, no Space, nothing written
    /// into the session. Shared with Peek, which is the same window with different chrome.
    /// `url` is nil for one opened empty, and for one whose page is about to be `park`ed
    /// back in from a snapshot.
    ///
    /// `isPrivate` is passed, never defaulted, by anything that floats over an existing
    /// window: a Peek over a Private Window that quietly took the persistent data store
    /// would write the peeked page into history and keep its cookies — the one thing that
    /// window exists not to do. A Little Arc comes from another app, where there is no
    /// window to inherit from, so it takes the default.
    static func floatingStore(_ url: URL?, profileID: UUID, isPrivate: Bool = false) -> TabStore {
        let store = TabStore(isPrivate: isPrivate, urls: url.map { [$0] } ?? [],
                             profileID: profileID, isLittle: true)
        // `WebCard` leaves its leading edge bare for a docked sidebar. There isn't one, so
        // this is what gives the page the same gap on all four sides.
        store.sidebarShown = false
        return store
    }

    // MARK: - Which windows are ours

    /// A Peek is built on the same one-page store, but it is not a Little Arc: its ⌘O means
    /// "beside the tab I came from" rather than "hand this to a Space", and Window ▸ Hide
    /// All Little Arc Windows has no business miniaturising something that is a child of the
    /// window it floats over.
    static var stores: [TabStore] { TabStore.all.filter { $0.isLittle && !Peek.owns($0) } }
    static var windows: [NSWindow] { stores.compactMap(\.window) }

    static func store(of window: NSWindow?) -> TabStore? {
        guard let window else { return nil }
        return stores.first { $0.window === window }
    }

    /// True while every Little Arc is up and on screen — which is what makes the menu item
    /// say "Hide" rather than "Show". False with none open, so the item reads "Show".
    static var allShowing: Bool {
        let all = windows
        return !all.isEmpty && all.allSatisfy { $0.isVisible && !$0.isMiniaturized }
    }

    /// Window ▸ Show / Hide All Little Arc Windows. Arc's item is a toggle, and so is this:
    /// they come to the front together, or they all get out of the way together.
    static func toggleAll() {
        let all = windows
        guard !all.isEmpty else { return }
        if allShowing {
            all.forEach { $0.miniaturize(nil) }
        } else {
            for w in all {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.orderFront(nil)
            }
            all.last?.makeKeyAndOrderFront(nil)
        }
        rebuild()          // the item's own title is the thing that just changed
    }

    // MARK: - Open in ▸

    /// ⌘O and the "Open in" button's default: the Space the browser window is showing.
    static func openInCurrentSpace(_ store: TabStore) {
        move(store, to: Windows.current(in: store.profileID)?.currentSpace)
    }

    /// Hand the page over to an ordinary window and close the Little Arc. The tab arrives on
    /// the same page with the same back/forward list and scroll offset — `park` + `resume`
    /// is the same pair a Space switch goes through — rather than as a fresh load of the
    /// url, which would lose wherever the user had clicked to.
    ///
    /// ponytail: the page is re-created in the target window rather than the live `Tab`
    /// being moved between stores. Moving it would keep the WebContent process, but every
    /// callback on that tab is bound to the store it was made in, so it is a rebind and a
    /// hand-off either way. Ceiling: the page reloads from its interaction state, so an
    /// unsubmitted form goes with it but a video restarts.
    static func move(_ store: TabStore, to space: Space?) {
        // Nothing to hand over yet — ⌘O pressed before the first navigation committed. The
        // window stays, because closing it here would throw the link away.
        guard let page = page(of: store) else { return }
        // With no browser window the url goes into the one being opened for it, so it comes
        // up on the page instead of behind the new-tab bar; an existing window gets a tab.
        let existing = Windows.current(in: store.profileID)
        let target = existing ?? Windows.open(urls: [page.url], profile: store.profile, space: space)
        if let space, target.currentSpaceID != space.id { target.switchTo(space: space) }
        let moved = existing == nil
            ? (target.tabs.first { $0.currentURL == page.url } ?? target.newBlankTab())
            : target.newBlankTab()
        hand(page, into: moved, of: target, from: store,
             saying: "Moved to \(space?.name ?? "the browser window").")
        store.window?.performClose(nil)
    }

    /// What a floating window is showing, as the pair `Tab.park` wants. Nil before the first
    /// navigation committed. Peek asks the same question of its own store.
    static func page(of store: TabStore) -> (url: URL, snapshot: Parked)? {
        guard let tab = store.active, let url = tab.currentURL else { return nil }
        return (url, tab.snapshot)
    }

    /// Put `page` into a tab of an ordinary window and go there. The two halves of the
    /// hand-off that neither caller varies — Peek's ⌘O differs only in *where* the tab is
    /// placed, which is why that is the caller's job and this is not.
    static func hand(_ page: (url: URL, snapshot: Parked), into moved: Tab,
                     of target: TabStore, from store: TabStore, saying: String) {
        moved.park(url: page.url, page.snapshot)
        moved.resume()
        target.current = moved.id
        target.window?.makeKeyAndOrderFront(nil)
        axAnnounce(saying)
    }

    /// ⌥⌘O and the button: the Spaces this page can be dropped into, the current one ticked.
    /// ponytail: an NSMenu popped up by hand rather than a SwiftUI `Menu`, so the button and
    /// the shortcut open exactly the same list — SwiftUI has no way to open a `Menu` from a
    /// key press.
    static func pickSpace(_ store: TabStore) {
        guard let window = store.window else { return }
        // Under the bar's trailing end, which is where the button is. In screen coordinates
        // (`in: nil`) rather than the content view's: an NSHostingView is flipped and the
        // same arithmetic would have put the menu at the other end of the window.
        let frame = window.frame
        let at = NSPoint(x: frame.maxX - Look.inset - menuWidth,
                         y: frame.maxY - Look.littleTopInset - Look.pillHeight)
        spaceMenu(store).popUp(positioning: nil, at: at, in: nil)
    }

    /// How far left of the window's trailing edge the menu is hung, so it drops under the
    /// button rather than off the side of the screen. ponytail: a number, not the button's
    /// measured frame — reading that back out of SwiftUI is an anchor preference and a
    /// coordinate space for one popover position. AppKit clamps it to the screen anyway.
    private static let menuWidth: CGFloat = 180

    static func spaceMenu(_ store: TabStore) -> NSMenu {
        let menu = NSMenu()
        // Spaces only. There is no "Open in Window" row any more: a browser window is always
        // in a Space, so "put this in a window" and "put this in a Space" are the same
        // question, and the answer this window is offering is which Space. `ensureSpaces`
        // is what makes the list never empty.
        let spaces = ProfileManager.shared.ensureSpaces(for: store.profile)
        // The main window's Space is the default, and with no window open the one the
        // profile was last left in — which is where a browser window would come up anyway.
        let showing = Windows.current(in: store.profileID)?.currentSpaceID
            ?? TabStore.lastSpaceID(for: store.profileID) ?? spaces[0].id
        for space in spaces {
            let row = entry(space.name) { move(store, to: space) }
            row.state = space.id == showing ? .on : .off
            menu.addItem(row)
        }
        return menu
    }

    /// NSMenuItem needs an ObjC target and does not retain it. Menu.swift's version of this
    /// is private to that file, and one item type is not worth exporting.
    private static func entry(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let act = MenuAction(run)
        keptActions.append(act)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = act
        return item
    }

    private static var keptActions: [MenuAction] = []
    private static var keptDelegates: [Delegate] = []

    /// The closure behind one of those items.
    @MainActor private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    // MARK: - Keys

    /// ⌘O and ⌥⌘O inside a Little Arc, taken before the global registry sees them: ⌘O is
    /// Open File everywhere else in Vane, so this is a window-local override rather than two
    /// more rebindable commands competing for the same key. ⌘W is not here — it is
    /// `TabStore.closeOrArchive`, so the menu item and the key cannot disagree.
    /// Returns true when the key was ours. Wired in main.swift, ahead of `Keybindings`.
    /// The modifier test comes first: this runs on every key the app sees, and all but a
    /// handful carry no ⌘ at all.
    static func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, mods.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "o",
              let store = store(of: NSApp.keyWindow) else { return false }
        switch mods {
        case [.command]:            openInCurrentSpace(store)
        case [.command, .option]:   pickSpace(store)
        default:                    return false
        }
        return true
    }

    // MARK: - Window bookkeeping

    /// Everything `Windows.WindowDelegate` does that applies here: take the page down,
    /// forget the store, and keep the lights on the line through a resize. Nothing is
    /// saved — a Little Arc is not in the session.
    private final class Delegate: NSObject, NSWindowDelegate {
        let store: TabStore
        init(_ store: TabStore) { self.store = store }

        @MainActor private func recentre() { (store.window as? VaneWindow)?.centreTrafficLights() }
        func windowDidResize(_ n: Notification) { recentre() }
        func windowDidEndLiveResize(_ n: Notification) { recentre() }
        func windowDidBecomeKey(_ n: Notification) { recentre() }
        func windowDidResignKey(_ n: Notification) { recentre() }
        func windowWillClose(_ n: Notification) {
            MainActor.assumeIsolated {
                store.tabs.forEach { $0.tearDown() }
                TabStore.all.removeAll { $0 === store }
                LittleArc.keptDelegates.removeAll { $0 === self }
                rebuild()
            }
        }
    }

    // MARK: - check

    /// The routing table and the bar's geometry, proved offline.
    nonisolated static func check() -> [(String, Bool)] {
        [
            ("a link opens a Little Arc when that is the preference, window or no window",
             route(preferLittle: true, hasWindow: true) == .little
                && route(preferLittle: true, hasWindow: false) == .little),
            ("\u{201C}Current Space\u{201D} with a window open adds a tab to it",
             route(preferLittle: false, hasWindow: true) == .tab),
            ("\u{201C}Current Space\u{201D} with nothing open makes the window it needs",
             route(preferLittle: false, hasWindow: false) == .newWindow),
            ("the preference is the only thing that can choose Little Arc",
             route(preferLittle: false, hasWindow: true) != .little
                && route(preferLittle: false, hasWindow: false) != .little),
            ("Little Arc never falls back to a tab",
             route(preferLittle: true, hasWindow: true) != .tab),
            ("the window is Arc's size", Look.littleWidth == 1000 && Look.littleHeight == 700),
            ("its bar puts the pill's centre on the traffic lights' line",
             Look.littleTopInset + Look.pillHeight / 2 == Look.lightsCentre),
            ("the pill is the sidebar's pill, at the sidebar's height",
             Look.pillHeight == Look.rowHeight),
        ]
    }
}

extension TabStore {
    /// ⌘W and File ▸ Archive Tab. Arc archives the tab into the sidebar; a Little Arc has no
    /// sidebar to archive into and no second tab to fall back on, so the window goes instead.
    /// One definition, so the menu item and the key equivalent cannot disagree about it.
    func closeOrArchive() {
        if isLittle { window?.performClose(nil) } else { archiveWithToast() }
    }
}

// MARK: - The window

/// A Little Arc window: the same ground as the browser window, one bar, and the page as the
/// same floating card. No sidebar, so nothing here is a list.
struct LittleArcView: View {
    @EnvironmentObject var store: TabStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WindowGlass()
            SpaceGround()
            VStack(spacing: 0) {
                LittleArcBar()
                WebCard()
            }
            // Last, so ⌘L's bar composites over the bar as well as the page.
            if let mode = store.palette {
                PaletteView(mode: mode) { store.palette = nil }
                    .transition(.opacity)
            }
        }
        // `.fullSizeContentView` still leaves SwiftUI a titlebar-sized safe area, which
        // would push the bar below the traffic lights instead of around them.
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : Look.appear, value: store.palette == nil)
        .onAppear { store.applySpaceAppearance() }
        // Costs no layout, and is the only thing that hears a title arrive.
        .background { if let tab = store.active { TitleSync(tab: tab) } }
    }
}

/// The window's title is the page's, so AppKit lists a Little Arc in the Window menu by
/// what is in it rather than by a row of identical "Little Arc"s. Its own view because only
/// something observing the tab hears the title land.
private struct TitleSync: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: TabStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: tab.title, initial: true) {
                store.window?.title = tab.title.isEmpty ? "Little Arc" : tab.title
            }
            .accessibilityHidden(true)
    }
}

/// Little Arc's one row of chrome: the traffic lights, the page's own back/forward, the same
/// address pill the sidebar has, and Arc's "Open in ▸". Laid out so the pill's centre lands
/// on `Look.lightsCentre` — the lights are the row, the same way they are in the sidebar.
struct LittleArcBar: View {
    @EnvironmentObject var store: TabStore

    var body: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 62)          // traffic lights
            NavButtons(tab: store.active)
            AddressPill(tab: store.active)
            OpenInButton()
        }
        .font(Look.icon)
        .foregroundStyle(Look.inkSecondary)
        .padding(.horizontal, Look.inset)
        .padding(.top, Look.littleTopInset)
        .frame(height: Look.littleTopInset + Look.pillHeight, alignment: .top)
        // The bar is this window's title bar, the way the sidebar is the browser window's.
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Little Arc")
    }
}

/// "Open in ▸": the one way a Little Arc's page becomes a tab you keep. Clicking it offers
/// the Spaces; ⌘O takes the one the browser window is already showing.
private struct OpenInButton: View {
    @EnvironmentObject var store: TabStore
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { LittleArc.pickSpace(store) } label: {
            HStack(spacing: 4) {
                Text("Open in").font(Look.text)
                Image(systemName: "chevron.right").font(Look.caption)
            }
            .foregroundStyle(Look.inkPrimary)
            .padding(.horizontal, Look.rowInset)
            .frame(height: Look.topRow)
            .background(hovering ? Look.selected : Look.pillFill,
                        in: .rect(cornerRadius: Look.pillRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Look.quick, value: hovering)
        .onHover { hovering = $0 }
        .help("Open in a Space (\u{2318}O), or pick one (\u{2325}\u{2318}O)")
        .accessibilityLabel("Open in")
        .accessibilityHint("Moves this page into a Space of the browser window.")
        .accessibilityAction(named: "Open in Current Space") { LittleArc.openInCurrentSpace(store) }
    }
}
