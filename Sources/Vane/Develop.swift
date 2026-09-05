import AppKit
import WebKit

/// Web Inspector. `isInspectable` is public and is what puts "Inspect Element" in the
/// page's context menu and exposes the view to Safari's Develop menu — that part is
/// supported and does the heavy lifting.
///
/// There is no public API to *open* the inspector from a menu item, so ⌥⌘I goes through
/// -[WKWebView _inspector] and -[_WKInspector show].
/// ponytail: SPI, so every hop is respondsToSelector-guarded and returns quietly. If Apple
/// drops it the menu item goes inert and right-click → Inspect Element still works; the
/// upgrade path is deleting this enum the day a public equivalent ships.
@MainActor enum Inspector {
    private static func object(for web: WKWebView) -> AnyObject? {
        guard web.isInspectable, web.responds(to: Selector(("_inspector"))) else { return nil }
        return web.perform(Selector(("_inspector")))?.takeUnretainedValue()
    }

    /// The inspector must be connected before it will show; calling show() on a fresh
    /// _WKInspector opens nothing at all, silently.
    private static func call(_ web: WKWebView, _ name: String) {
        let sel = Selector((name))
        guard let inspector = object(for: web), inspector.responds(to: sel) else { return }
        let connected = inspector.responds(to: Selector(("isConnected")))
            && (inspector.value(forKey: "connected") as? Bool ?? false)
        if !connected, inspector.responds(to: Selector(("connect"))) {
            _ = inspector.perform(Selector(("connect")))
        }
        _ = inspector.perform(sel)
    }

    /// WebKit persists the inspector's dock side in the host app's own defaults.
    /// 0 = bottom, 1 = right, 2 = left. Registered rather than set, so dragging the
    /// inspector somewhere else writes a real value that wins from then on.
    static func configure() {
        UserDefaults.vane.register(defaults: [
            "__WebInspectorPageGroupLevel1__.WebKit2InspectorAttachmentSide": 1
        ])
    }

    static func show(_ web: WKWebView?)        { web.map { call($0, "show") } }
    static func showConsole(_ web: WKWebView?) { web.map { call($0, "showConsole") } }

    /// True when the SPI is actually there, so the menu can disable itself rather than
    /// silently doing nothing.
    static var available: Bool { WKWebView().responds(to: Selector(("_inspector"))) }
}

/// The handful of preferences that exist so far. ponytail: UserDefaults directly, no
/// settings window and no observable settings object until there is a screen to put it on.
@MainActor enum Settings {
    static let userAgents: [(name: String, value: String)] = [
        ("Safari (default)", safariUA),
        ("Chrome", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"),
        ("Firefox", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.0; rv:135.0) Gecko/20100101 Firefox/135.0"),
        ("Safari — iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
    ]

    static var userAgent: String {
        get { UserDefaults.vane.string(forKey: "userAgent") ?? safariUA }
        set { UserDefaults.vane.set(newValue, forKey: "userAgent"); apply() }
    }

    /// Defaults on: this is a browser, and Chrome does not hide its dev tools either.
    static var inspectorEnabled: Bool {
        get { UserDefaults.vane.object(forKey: "inspector") as? Bool ?? true }
        set { UserDefaults.vane.set(newValue, forKey: "inspector"); apply() }
    }

    static func apply() {
        for store in TabStore.all {
            for tab in store.tabs {
                tab.web.customUserAgent = userAgent
                tab.web.isInspectable = inspectorEnabled
            }
        }
    }
}
