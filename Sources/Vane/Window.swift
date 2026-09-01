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
                     profile: Profile? = nil, space: Space? = nil) -> TabStore {
        let profile = profile ?? space.flatMap { s in
            ProfileManager.shared.profiles.first { $0.id == s.profileID }
        } ?? ProfileManager.shared.active
        let store = TabStore(isPrivate: isPrivate, urls: urls, profileID: profile.id, space: space)
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
        window.tabbingMode = .disallowed          // Vane draws its own tabs
        // ProfileManager is in the environment so chrome can show the profile/space it is in
        // and redraw when the list changes; a view that does not want it simply ignores it.
        window.contentView = NSHostingView(rootView: BrowserWindow()
            .environmentObject(store)
            .environmentObject(ProfileManager.shared))
        window.setFrameAutosaveName(isPrivate ? "" : "VaneMain")
        if TabStore.all.count > 1 { window.cascadeTopLeft(from: NSPoint(x: 40, y: 40)) } else { window.center() }

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

    /// Every profile's open windows, each into its own file. A profile whose windows are all
    /// closed keeps the session it already had — only profiles with a live window are
    /// rewritten, so quitting from profile B does not erase profile A's session.
    static func save() {
        var byProfile: [UUID: [[String]]] = [:]
        for store in TabStore.all where !store.isPrivate {
            store.saveCurrentSpace()
            let urls = store.tabs.compactMap { $0.web.url?.absoluteString }
                                 .filter { $0.hasPrefix("http") }
            byProfile[store.profileID, default: []].append(urls)
        }
        for (profileID, windows) in byProfile {
            let open = windows.filter { !$0.isEmpty }
            try? JSONSerialization.data(withJSONObject: open).write(to: file(profileID))
        }
    }

    /// Returns false when there was nothing to restore, so the caller opens a fresh window.
    @discardableResult
    static func restore(profile: Profile? = nil) -> Bool {
        let profile = profile ?? ProfileManager.shared.active
        guard let data = try? Data(contentsOf: file(profile.id)),
              let windows = try? JSONSerialization.jsonObject(with: data) as? [[String]],
              !windows.isEmpty
        else { return false }
        for urls in windows {
            Windows.open(urls: urls.compactMap(URL.init(string:)), profile: profile)
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
