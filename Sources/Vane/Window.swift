import AppKit
import SwiftUI

/// The window, only so the traffic lights can be nailed to the sidebar's top row.
///
/// AppKit picks where the lights go from the titlebar's height, and it re-picks after every
/// resize, every key/resign-key and every restored frame. An empty compact toolbar gets that
/// metric *close* to `Look.lightsCentre` — measured 19.75 against a row centred on 19 — but
/// close is what the user saw as "the traffic lights aren't in the same place as the others".
/// So the buttons are moved back onto the line after every layout pass, whatever AppKit did.
final class VaneWindow: NSWindow {
    /// Where a light's frame origin has to sit for its centre to land `Look.lightsCentre`
    /// below the window's top edge. `top` is that top edge in the button's superview's own
    /// (unflipped, y-up) coordinates, so this is the same arithmetic whatever titlebar view
    /// AppKit happens to have parented the buttons to.
    /// Pure, so `selfcheck --pure` can prove it without a window server.
    nonisolated static func lightOriginY(windowTop top: CGFloat, buttonHeight h: CGFloat,
                                         peeking: Bool = false) -> CGFloat {
        top - lightsCentre(peeking: peeking) - h / 2
    }

    /// The line the lights sit on, which is the sidebar's top row — and the peeked sidebar is
    /// not the same sidebar. With ⌘S the docked one is gone and the panel that slides in from
    /// the edge is inset by `Look.inset` on every side, so its top row is that much lower and
    /// that much further right. Leaving the lights on the docked line put them 8pt above and
    /// 8pt left of the row they are supposed to belong to.
    /// This is `Look.inset + Look.lightsCentre` written out: `Look.check` already pins
    /// `lightsCentre == topInset + topRow / 2`, and spelling it in the parts makes it obvious
    /// that the number follows the panel's own padding rather than being a second constant.
    nonisolated static func lightsCentre(peeking: Bool) -> CGFloat {
        peeking ? Look.inset + Look.topInset + Look.topRow / 2 : Look.lightsCentre
    }

    /// How far right of AppKit's own x the lights sit. Zero docked — AppKit's x already
    /// matches Arc's, 18.75pt from the window edge and 23pt apart — and the panel's inset
    /// while peeking.
    nonisolated static func lightsOffsetX(peeking: Bool) -> CGFloat {
        peeking ? Look.inset : 0
    }

    /// True while the sidebar is hidden *and* the pointer has peeked the floating panel back.
    /// Set from `BrowserWindow`, which is the only thing that knows.
    var peekingSidebar = false {
        didSet { if peekingSidebar != oldValue { centreTrafficLights() } }
    }

    /// AppKit's own x for each light, captured the first time we see it. Read once and kept:
    /// after the first shift the button's own frame is no longer AppKit's answer, and AppKit
    /// puts it back to this on its own relayouts, so a delta from "wherever it is now" drifts
    /// by 8pt every time the peek opens.
    private var baseX: [NSWindow.ButtonType: CGFloat] = [:]

    func centreTrafficLights() {
        let peeking = peekingSidebar
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(kind), let host = button.superview else { continue }
            // The window's top edge in base coordinates is its own height; convert that into
            // whatever space the buttons are laid out in.
            let top = host.convert(NSPoint(x: 0, y: frame.height), from: nil).y
            let wantY = Self.lightOriginY(windowTop: top, buttonHeight: button.frame.height,
                                          peeking: peeking)
            let base = baseX[kind] ?? button.frame.origin.x
            baseX[kind] = base
            let wantX = base + Self.lightsOffsetX(peeking: peeking)
            guard abs(button.frame.origin.y - wantY) > 0.01
                    || abs(button.frame.origin.x - wantX) > 0.01 else { continue }
            button.setFrameOrigin(NSPoint(x: wantX, y: wantY))
        }
    }

    /// Every AppKit relayout ends here, which makes this the one hook that catches a resize,
    /// a live-resize step, a restored frame and a first ordering-in alike.
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        centreTrafficLights()
    }

    /// Arc's sidebar *is* the window's title bar: dragging its bare ground moves the window,
    /// and dragging anything on it does that thing instead. `WindowDragGround` is SwiftUI's
    /// own answer to "is the pointer on bare ground", so this is the whole of it — and it
    /// deliberately does not use `isMovableByWindowBackground`, which cannot tell the
    /// difference and moved the window from a drag on a tab row.
    override func sendEvent(_ event: NSEvent) {
        // Escape stops a page that is still coming in — and *only* then, so a page's own
        // dialog, menu or full-screen video keeps its Escape the rest of the time.
        if event.type == .keyDown, event.keyCode == 53,
           MainActor.assumeIsolated({ TabActions.stopLoading(in: self) }) { return }
        if event.type == .leftMouseDown,
           MainActor.assumeIsolated({ WindowDragGround.shared.over }) {
            // Runs its own event loop until the button comes up, and gives us AppKit's edge
            // snapping and Spaces handling for nothing.
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    /// Becoming or resigning key swaps the buttons' images and can re-lay them without a
    /// layout pass of the window's own.
    override func becomeKey() { super.becomeKey(); centreTrafficLights() }
    override func resignKey() { super.resignKey(); centreTrafficLights() }
}

extension VaneWindow {
    /// The peeked sidebar's geometry, proved offline. `Look.check` already pins the docked
    /// numbers; these are the ones that only apply while the floating panel is showing.
    nonisolated static func check() -> [(String, Bool)] {
        [
            ("docked, the lights sit on the sidebar's own top row",
             lightsCentre(peeking: false) == Look.lightsCentre),
            ("peeked, they move down by the panel's inset",
             lightsCentre(peeking: true) == Look.lightsCentre + Look.inset),
            ("…which is the panel's padding plus its own top row",
             lightsCentre(peeking: true) == Look.inset + Look.topInset + Look.topRow / 2),
            ("docked, x is AppKit's own", lightsOffsetX(peeking: false) == 0),
            ("peeked, x moves right by the same inset", lightsOffsetX(peeking: true) == Look.inset),
            ("the y origin follows the peeked line",
             lightOriginY(windowTop: 800, buttonHeight: 14, peeking: true)
                == lightOriginY(windowTop: 800, buttonHeight: 14) - Look.inset),
            ("peeking is the only thing that moves them",
             lightOriginY(windowTop: 800, buttonHeight: 14, peeking: false)
                == lightOriginY(windowTop: 800, buttonHeight: 14)),
        ]
    }
}

/// Window bookkeeping + session restore. ponytail: no NSDocument, no window controller
/// hierarchy — a list of live TabStores and their NSWindows is the whole model.
@MainActor enum Windows {
    private static var delegates: [WindowDelegate] = []

    /// The window in front, whatever kind it is — a Little Arc included, because ⌘L, ⌘R,
    /// Find and the rest have to act on the window the user is looking at. keyWindow is nil
    /// while a sheet or panel is up, so fall back to the most recently opened one rather
    /// than doing nothing; the fallback skips Little Arcs, since a menu item fired with no
    /// key window meant the browser.
    /// Anything that moves rows around a sidebar, a Space or the archive wants `main`.
    static var current: TabStore? {
        TabStore.all.first { $0.window?.isKeyWindow == true } ?? main
    }

    /// The frontmost ordinary browser window, never a Little Arc. What a link from another
    /// app opens a tab in, what a Little Arc hands its page over to, and what every menu
    /// item that needs a sidebar acts on. See LittleArc.swift.
    static var main: TabStore? {
        let ordinary = TabStore.all.filter { !$0.isLittle }
        return ordinary.first { $0.window?.isKeyWindow == true } ?? ordinary.last
    }

    /// The window the menus act on, restricted to one profile.
    static func current(in profileID: UUID) -> TabStore? {
        let mine = TabStore.all.filter { $0.profileID == profileID && !$0.isLittle }
        return mine.first { $0.window?.isKeyWindow == true } ?? mine.last
    }

    @discardableResult
    static func open(isPrivate: Bool = false, urls: [URL] = [],
                     profile: Profile? = nil, space: Space? = nil,
                     parked: [String: Parked] = [:]) -> TabStore {
        let profile = profile ?? space.flatMap { s in
            ProfileManager.shared.profiles.first { $0.id == s.profileID }
        } ?? ProfileManager.shared.active
        // Arc's rule: every tab in a browser window lives in a Space, so an ordinary window
        // always resolves to one — the Space it was asked for, else the profile's last-used
        // one, else its first, and the profile is given a first one if it has none. A
        // private window is Arc's incognito: no Space, nothing written down.
        let space = isPrivate ? nil : Spaces.resolve(space, for: profile)
        let store = TabStore(isPrivate: isPrivate, urls: urls, profileID: profile.id, space: space,
                             parked: parked)
        let window = VaneWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // The profile name is in the title because there is otherwise nothing on screen that
        // says which set of logins this window is using.
        let named = profile.isDefault ? "" : " — " + profile.name
        window.title = isPrivate ? "Vane — Private" : "Vane" + named
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar, never shown: it only exists to make the titlebar 38pt tall,
        // which puts AppKit's own idea of where the lights go within a point of the
        // sidebar's top row instead of 3pt above it — so the one frame that is drawn before
        // `VaneWindow.centreTrafficLights` first runs is already near enough not to jump.
        // The titlebar is transparent and the toolbar has no items, so nothing of it is
        // ever drawn. `VaneWindow` is what actually holds the lights on the line.
        window.toolbar = NSToolbar(identifier: "VaneEmpty")
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed          // Vane draws its own tabs
        // A window made in code is `isReleasedWhenClosed` by default, which under ARC is an
        // over-release — the close animation reaching a window ARC has already freed. See
        // `LittleArc.open`, where it crashed, and `SettingsWindow`, which turns it off too.
        window.isReleasedWhenClosed = false
        // The window itself draws nothing: `WindowGlass` inside the content view is the
        // only ground, so the desktop shows through the sidebar and the gap around the page
        // card. An opaque window would paint over it before SwiftUI ever ran.
        window.isOpaque = false
        // Not `.clear`: a non-opaque window lets the pointer fall through wherever its
        // pixels are fully transparent, and the behind-window blur is drawn by the window
        // server, not into our pixels — so hover over the sidebar's ground came and went
        // with the glyphs under it. A hair of alpha makes the whole window hit-testable and
        // draws nothing anyone can see.
        window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        // ProfileManager is in the environment so chrome can show the profile/space it is in
        // and redraw when the list changes; a view that does not want it simply ignores it.
        window.contentView = NSHostingView(rootView: BrowserWindow()
            .environmentObject(store)
            .environmentObject(ProfileManager.shared))
        // Position first, autosave second, as SettingsWindow does: `setFrameUsingName`
        // says whether there was a saved frame, and centring after it would throw the
        // saved position away and keep only the size — which is what every launch did.
        let name = isPrivate ? "" : "VaneMain"
        if TabStore.all.count > 1 {
            window.cascadeTopLeft(from: NSPoint(x: 40, y: 40))
        } else if name.isEmpty || !window.setFrameUsingName(name) {
            window.center()
        }
        // ponytail: AppKit writes this frame into its own defaults domain, not
        // `UserDefaults.vane`, so a `VANE_DATA_DIR` instance still inherits the real app's
        // window size. Cosmetic, and the upgrade path is saving the frame ourselves — a
        // whole second frame-restoration path for a window that opens in the right place.
        window.setFrameAutosaveName(name)

        let delegate = WindowDelegate(store)
        delegates.append(delegate)
        window.delegate = delegate
        store.window = window
        window.makeKeyAndOrderFront(nil)
        return store
    }

    /// Make a profile active and put a window for it in front: the one that is already open,
    /// else its restored session, else a fresh window. This is what a "Profiles" menu item
    /// calls.
    @discardableResult
    static func switchTo(profile: Profile) -> TabStore {
        ProfileManager.shared.active = profile
        if let existing = current(in: profile.id) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        if Session.restore(profile: profile), let restored = current(in: profile.id) { return restored }
        return open(profile: profile)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let store: TabStore
        init(_ store: TabStore) { self.store = store }
        /// Belt and braces around `VaneWindow.layoutIfNeeded`: a resize that AppKit satisfies
        /// without a full layout pass still moves the lights, and this catches it.
        /// The store's window, not the notification's: a `Notification` is not Sendable and
        /// may not cross into the main actor, while the store already holds the window.
        @MainActor private func recentre() {
            (store.window as? VaneWindow)?.centreTrafficLights()
        }
        func windowDidResize(_ n: Notification) { recentre() }
        func windowDidEndLiveResize(_ n: Notification) { recentre() }
        func windowDidBecomeKey(_ n: Notification) { recentre() }
        func windowDidResignKey(_ n: Notification) { recentre() }
        func windowDidEnterFullScreen(_ n: Notification) { recentre() }
        func windowDidExitFullScreen(_ n: Notification) { recentre() }
        func windowWillClose(_ n: Notification) {
            MainActor.assumeIsolated {
                Session.save()
                // Then take the pages down with the window: see `Tab.tearDown`.
                store.tabs.forEach { $0.tearDown() }
                TabStore.all.removeAll { $0 === store }
                delegates.removeAll { $0 === self }
            }
        }
    }
}

/// Reopen what was open last time. Private windows are deliberately never written down.
/// One file per profile — the default profile's is still `session.json`.
@MainActor enum Session {
    private static func file(_ profileID: UUID) -> URL {
        ProfileManager.sessionURL(for: profileID, in: Store.directory)
    }

    /// One tab as the session file remembers it. `state` is a base64 `interactionState`:
    /// the back/forward list, the current item and its scroll offset.
    struct Entry: Codable, Equatable {
        var url: String
        var title: String?
        var state: String?
    }

    private struct Disk: Codable {
        var version: Int
        var windows: [[Entry]]
        /// Each window's split views, as the urls of their panes. Optional, so a v2 file —
        /// written before splits existed — still decodes into a session with none.
        var splits: [[Split.Saved]]?
        /// Which Space each window was showing, aligned index-for-index with `windows`.
        /// Optional so a session written before this existed still decodes, and `""` for a
        /// window that was in none — which only a pre-migration file can contain.
        var spaces: [String]?
    }

    /// v3 adds the splits and the per-window Space. v2 is a dictionary so it is
    /// self-describing; v1 was a bare `[[String]]` of urls and is still read, because a
    /// session written by the previous build has to come back — just without the extra
    /// fidelity.
    /// ponytail: no writer for v1 or v2. Downgrading loses the session once, and a browser
    /// that can be downgraded mid-session is not a thing anyone does twice.
    static func encode(_ windows: [[Entry]], splits: [[Split.Saved]] = [],
                       spaces: [String] = []) -> Data? {
        try? JSONEncoder().encode(Disk(version: 3, windows: windows,
                                       splits: splits.contains { !$0.isEmpty } ? splits : nil,
                                       spaces: spaces.isEmpty ? nil : spaces))
    }

    static func decode(_ data: Data) -> [[Entry]] { disk(data).windows }

    /// Each window's splits, in the same order as `decode`'s windows. Empty for a file that
    /// predates them.
    static func decodeSplits(_ data: Data) -> [[Split.Saved]] { disk(data).splits ?? [] }

    /// The Space each of `decode`'s windows was in, padded to the same length so the two
    /// lists can be zipped whatever wrote the file.
    static func decodeSpaces(_ data: Data) -> [UUID?] {
        let d = disk(data)
        let ids = d.spaces ?? []
        return d.windows.indices.map { i in
            ids.indices.contains(i) ? UUID(uuidString: ids[i]) : nil
        }
    }

    private static func disk(_ data: Data)
        -> (windows: [[Entry]], splits: [[Split.Saved]]?, spaces: [String]?) {
        if let disk = try? JSONDecoder().decode(Disk.self, from: data) {
            return (disk.windows, disk.splits, disk.spaces)
        }
        let legacy = (try? JSONSerialization.jsonObject(with: data)) as? [[String]] ?? []
        return (legacy.map { $0.map { Entry(url: $0) } }, nil, nil)
    }

    /// Every page the session file holds for a profile, in window order and deduped. What
    /// the one-off migration folds into the profile's first Space: before the Space existed
    /// these tabs were the whole of "the window's tabs", written nowhere else.
    static func urls(for profileID: UUID, in dir: URL = Store.directory) -> [URL] {
        guard let data = try? Data(contentsOf: ProfileManager.sessionURL(for: profileID, in: dir))
        else { return [] }
        var seen = Set<String>()
        return decode(data).flatMap { $0 }
            .compactMap { URL(string: $0.url) }
            .filter { seen.insert($0.absoluteString).inserted }
    }

    /// url → what we knew about it, for `TabStore.init`. Entries with neither a title nor a
    /// state — i.e. every entry from a v1 file — are left out, so those tabs load eagerly
    /// exactly as they do today.
    /// ponytail: keyed by url, so the same page open in two tabs of one window comes back
    /// twice on the same scroll position. Nobody has ever noticed.
    static func parked(_ entries: [Entry]) -> [String: Parked] {
        var out: [String: Parked] = [:]
        for e in entries where e.title != nil || e.state != nil {
            out[e.url] = Parked(title: e.title ?? "",
                                state: e.state.flatMap { Data(base64Encoded: $0) })
        }
        return out
    }

    /// Every profile's open windows, each into its own file. A profile whose windows are all
    /// closed keeps the session it already had — only profiles with a live window are
    /// rewritten, so quitting from profile B does not erase profile A's session.
    static func save() {
        var byProfile: [UUID: [(entries: [Entry], splits: [Split.Saved], space: String)]] = [:]
        // Nothing private is written down, and neither is a Little Arc: it is a link
        // someone followed once, not a window to come back up in.
        for store in TabStore.all where !store.isPrivate && !store.isLittle {
            store.saveCurrentSpace()
            let entries = store.tabs.compactMap { tab -> Entry? in
                // currentURL, not web.url: a suspended tab has no live page and would
                // otherwise drop out of its own session.
                guard let u = tab.currentURL,
                      u.scheme?.hasPrefix("http") == true else { return nil }
                let snap = tab.snapshot
                return Entry(url: u.absoluteString, title: snap.title,
                             state: snap.state?.base64EncodedString())
            }
            byProfile[store.profileID, default: []]
                .append((entries, store.savedSplits, store.currentSpaceID?.uuidString ?? ""))
        }
        for (profileID, windows) in byProfile {
            // Windows are dropped as whole rows, so a window's splits and its Space never
            // end up filed under the next window's tabs.
            let kept = windows.filter { !$0.entries.isEmpty }
            guard let data = encode(kept.map(\.entries), splits: kept.map(\.splits),
                                    spaces: kept.map(\.space))
            else { continue }
            try? data.write(to: file(profileID))
        }
    }

    /// Returns false when there was nothing to restore, so the caller opens a fresh window.
    @discardableResult
    static func restore(profile: Profile? = nil) -> Bool {
        let profile = profile ?? ProfileManager.shared.active
        guard let data = try? Data(contentsOf: file(profile.id)) else { return false }
        let saved = decodeSplits(data)
        // Each window comes back into the Space it was in. `Windows.open` resolves the rest:
        // a window whose Space is gone — or a session written before Spaces were per-window —
        // lands in the profile's last-used one.
        // The one place session urls may be migrated into a Space: this is the session being
        // restored, so folding a pre-Spaces file's tabs in is right. `Spaces.resolve` — every
        // other way a window opens — passes none, or "Start Fresh" would put back exactly the
        // pages it was told not to.
        let spaces = ProfileManager.shared.ensureSpaces(
            for: profile, sessionTabs: urls(for: profile.id, in: Store.directory))
        let inSpace = decodeSpaces(data)
        let windows = decode(data).enumerated().filter { !$0.element.isEmpty }
        guard !windows.isEmpty else { return false }
        for (i, entries) in windows {
            let store = Windows.open(urls: entries.compactMap { URL(string: $0.url) },
                                     profile: profile,
                                     space: spaces.first { $0.id == inSpace[i] },
                                     parked: parked(entries))
            // After the window exists, because a split is named by its panes' urls and the
            // tabs that carry them are made by `TabStore.init`.
            store.applySplits(saved.indices.contains(i) ? saved[i] : [])
        }
        return !TabStore.all.isEmpty
    }
}

/// ⌘⇧T. ponytail: a url stack, not a full tab-state graph — reopening restores the page,
/// not its scroll position or back/forward list.
@MainActor enum ClosedTabs {
    private static var stack: [URL] = []
    static func push(_ url: URL?) {
        guard let url, url.scheme?.hasPrefix("http") == true else { return }
        stack.append(url)
        if stack.count > 32 { stack.removeFirst() }
    }
    static func pop() -> URL? { stack.popLast() }
}
