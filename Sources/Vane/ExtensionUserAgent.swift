import Foundation
import WebKit

/// Configures WebKit-owned extension views, including views created after a Develop
/// change. A controller copies its configuration; its web-view configuration copies
/// retain these preferences until WebKit snapshots them for an individual page.
/// MV3 workers have separate WebKit initialization and can start with a different UA.
@MainActor final class ExtensionUserAgent {
    private let preferences = WKWebpagePreferences()
    private let views = NSHashTable<WKWebView>.weakObjects()
    private var current = Settings.userAgent
    private var hasCustomPreference = false
    private static let setter = NSSelectorFromString("_setCustomUserAgent:")

    /// Public WebKit only exposes an appended application-name token on configurations.
    /// Full Firefox/iPhone/custom identities require this guarded WebKit preference.
    /// If it disappears, retain the public Safari suffix for extension views and
    /// disclose the unavailable custom-view configuration. Selector availability
    /// does not establish successful propagation into a separately created worker.
    var limitation: String? {
        preferences.responds(to: Self.setter) ? nil
            : "This WebKit version does not support custom user agents for extension web views. Vane uses its default Safari configuration for those views."
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
        // Default Safari uses the public configuration suffix and native view setter.
        // A full-UA policy is needed only for explicit Develop identities. When returning
        // to Safari, clear the same policy object retained by the controller's seed copies.
        let custom = current != safariUA
        guard custom || hasCustomPreference, preferences.responds(to: Self.setter) else { return }
        _ = preferences.perform(Self.setter, with: custom ? current : "")
        hasCustomPreference = custom
    }
}
