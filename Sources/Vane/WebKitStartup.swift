import Foundation
import WebKit

/// Registry class methods need WebKit's main run loop initialized even when no window
/// has opened yet. A nonpersistent store does this without a page or a disk-backed store.
@MainActor enum WebKitStartup {
    // Older engines can leave extension IPC receivers behind when a native
    // process context retires. Public initialized configurations retain that
    // context. Keep a separate owner per normal profile, including its hidden
    // visited-link state; private profiles load no extensions.
    private static var extensionConfigurations: [UUID: WKWebViewConfiguration] = [:]

    static func extensionConfiguration(from defaults: WKWebViewConfiguration,
                                       profileID: UUID) -> WKWebViewConfiguration {
        guard profileID != Profile.incognito.id else { return defaults }
        let owner: WKWebViewConfiguration
        if let existing = extensionConfigurations[profileID] { owner = existing }
        else {
            let empty = defaults.copy() as! WKWebViewConfiguration
            empty.websiteDataStore = .nonPersistent()
            empty.webExtensionController = nil
            empty.userContentController = WKUserContentController()
            empty.preferences = WKPreferences()
            empty.defaultWebpagePreferences = WKWebpagePreferences()
            owner = WKWebView(frame: .zero, configuration: empty).configuration
            extensionConfigurations[profileID] = owner
        }
        let result = owner.copy() as! WKWebViewConfiguration
        result.websiteDataStore = defaults.websiteDataStore
        result.webExtensionController = defaults.webExtensionController
        result.userContentController = defaults.userContentController
        result.preferences = defaults.preferences
        result.defaultWebpagePreferences = defaults.defaultWebpagePreferences
        result.applicationNameForUserAgent = defaults.applicationNameForUserAgent
        return result
    }

    private static let initialized: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

    static func prepare() { _ = initialized }
}
