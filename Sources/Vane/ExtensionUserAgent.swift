import Foundation
import WebKit

/// Identity for WebKit-owned extension pages, including pages created after a Develop
/// change. A controller copies its configuration; its web-view configuration copies
/// retain these preferences until WebKit snapshots them for an individual page.
@MainActor final class ExtensionUserAgent {
    private let preferences = WKWebpagePreferences()
    private let views = NSHashTable<WKWebView>.weakObjects()
    private var current = Settings.userAgent
    private static let setter = NSSelectorFromString("_setCustomUserAgent:")

    /// Public WebKit only exposes an appended application-name token on configurations.
    /// Full Firefox/iPhone/custom identities require this guarded WebKit preference.
    /// If it disappears, default Safari identity still works through the public suffix;
    /// the extension manager explicitly discloses the loss of custom identity support.
    var limitation: String? {
        preferences.responds(to: Self.setter) ? nil
            : "This WebKit version does not support custom user agents for extension pages. Extension pages use the default Safari identity."
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        // Never append a full UA: WebKit already supplies its Mozilla/AppleWebKit prefix.
        configuration.applicationNameForUserAgent = safariUA.components(separatedBy: "(KHTML, like Gecko) ").last
        configuration.defaultWebpagePreferences = preferences
        updatePreferences()
    }

    private var effective: String { limitation == nil ? current : safariUA }

    func apply() {
        current = Settings.userAgent
        updatePreferences()
        for view in views.allObjects { view.customUserAgent = effective }
    }

    func track(_ view: WKWebView) {
        views.add(view)
        view.customUserAgent = effective
    }

    private func updatePreferences() {
        // ponytail: no public configuration-level full-UA override. Calling the guarded
        // selector preserves the chosen HTTP and navigator UA without rewriting scripts
        // or replacing controllers, contexts, permissions, storage or extension code.
        guard preferences.responds(to: Self.setter) else { return }
        _ = preferences.perform(Self.setter, with: current)
    }
}
