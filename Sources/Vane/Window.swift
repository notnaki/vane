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

    @discardableResult
    static func open(isPrivate: Bool = false, urls: [URL] = []) -> TabStore {
        let store = TabStore(isPrivate: isPrivate, urls: urls)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = isPrivate ? "Vane — Private" : "Vane"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed          // Vane draws its own tabs
        window.contentView = NSHostingView(rootView: BrowserWindow().environmentObject(store))
        window.setFrameAutosaveName(isPrivate ? "" : "VaneMain")
        if TabStore.all.count > 1 { window.cascadeTopLeft(from: NSPoint(x: 40, y: 40)) } else { window.center() }

        let delegate = WindowDelegate(store)
        delegates.append(delegate)
        window.delegate = delegate
        store.window = window
        window.makeKeyAndOrderFront(nil)
        return store
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
@MainActor enum Session {
    private static var file: URL { Store.directory.appendingPathComponent("session.json") }

    static func save() {
        let open = TabStore.all.filter { !$0.isPrivate }.map { store in
            store.tabs.compactMap { $0.web.url?.absoluteString }
                      .filter { $0.hasPrefix("http") }
        }.filter { !$0.isEmpty }
        try? JSONSerialization.data(withJSONObject: open).write(to: file)
    }

    /// Returns false when there was nothing to restore, so the caller opens a fresh window.
    @discardableResult
    static func restore() -> Bool {
        guard let data = try? Data(contentsOf: file),
              let windows = try? JSONSerialization.jsonObject(with: data) as? [[String]],
              !windows.isEmpty
        else { return false }
        for urls in windows {
            Windows.open(urls: urls.compactMap(URL.init(string:)))
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
