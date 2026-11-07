import WebKit
import ExtensionResourceBridge

/// Registry class methods need WebKit's main run loop initialized even when no window
/// has opened yet. A nonpersistent store does this without a page or a disk-backed store.
@MainActor enum WebKitStartup {
    private static let browserOwner = VaneWebProcessPoolOwner()
    private static let extensionOwner = VaneWebProcessPoolOwner()

    static func configureBrowser(_ configuration: WKWebViewConfiguration) {
        if #unavailable(macOS 27) { browserOwner.configure(configuration) }
    }

    static func configureExtensionPages(_ configuration: WKWebViewConfiguration) {
        if #unavailable(macOS 27) { extensionOwner.configure(configuration) }
    }

    private static let initialized: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

    static func prepare() { _ = initialized }
}
