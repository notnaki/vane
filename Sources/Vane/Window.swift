import AppKit
import SwiftUI

/// Window bookkeeping + session restore. ponytail: no NSDocument, no window controller
/// hierarchy — a list of live TabStores and their NSWindows is the whole model.
@MainActor enum Windows {
    private static var delegates: [WindowDelegate] = []

    /// The window the menus act on. keyWindow is nil while a sheet or panel is up, so fall
    /// back to the most recently opened one rather than doing nothing.
    static var current: TabStore? {
        TabStore.all.first { $0.window?.isKeyWindow == true } ?? TabStore.all.last
    }

    /// The window the menus act on, restricted to one profile.
    static func current(in profileID: UUID) -> TabStore? {
        let mine = TabStore.all.filter { $0.profileID == profileID }
        return mine.first { $0.window?.isKeyWindow == true } ?? mine.last
    }

    @discardableResult
    static func open(isPrivate: Bool = false, urls: [URL] = [],
                     profile: Profile? = nil, space: Space? = nil,
                     parked: [String: Parked] = [:]) -> TabStore {
        let profile = profile ?? space.flatMap { s in
            ProfileManager.shared.profiles.first { $0.id == s.profileID }
        } ?? ProfileManager.shared.active
        let store = TabStore(isPrivate: isPrivate, urls: urls, profileID: profile.id, space: space,
                             parked: parked)
        let window = NSWindow(
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
        // which is where AppKit centres the traffic lights at `Look.lightsCentre` instead
        // of at 16pt — on the sidebar's top row rather than 3pt above it. The titlebar is
        // transparent and the toolbar has no items, so nothing of it is ever drawn.
        window.toolbar = NSToolbar(identifier: "VaneEmpty")
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed          // Vane draws its own tabs
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
        func windowWillClose(_ n: Notification) {
            MainActor.assumeIsolated {
                Session.save()
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
    }

    /// v2 is a dictionary so it is self-describing. v1 was a bare `[[String]]` of urls and
    /// is still read, because a session written by the previous build has to come back —
    /// just without the extra fidelity.
    /// ponytail: no writer for v1. Downgrading loses the session once, and a browser that
    /// can be downgraded mid-session is not a thing anyone does twice.
    static func encode(_ windows: [[Entry]]) -> Data? {
        try? JSONEncoder().encode(Disk(version: 2, windows: windows))
    }

    static func decode(_ data: Data) -> [[Entry]] {
        if let disk = try? JSONDecoder().decode(Disk.self, from: data) { return disk.windows }
        let legacy = (try? JSONSerialization.jsonObject(with: data)) as? [[String]] ?? []
        return legacy.map { $0.map { Entry(url: $0) } }
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
        var byProfile: [UUID: [[Entry]]] = [:]
        for store in TabStore.all where !store.isPrivate {
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
            byProfile[store.profileID, default: []].append(entries)
        }
        for (profileID, windows) in byProfile {
            guard let data = encode(windows.filter { !$0.isEmpty }) else { continue }
            try? data.write(to: file(profileID))
        }
    }

    /// Returns false when there was nothing to restore, so the caller opens a fresh window.
    @discardableResult
    static func restore(profile: Profile? = nil) -> Bool {
        let profile = profile ?? ProfileManager.shared.active
        guard let data = try? Data(contentsOf: file(profile.id)) else { return false }
        let windows = decode(data).filter { !$0.isEmpty }
        guard !windows.isEmpty else { return false }
        for entries in windows {
            Windows.open(urls: entries.compactMap { URL(string: $0.url) }, profile: profile,
                         parked: parked(entries))
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
