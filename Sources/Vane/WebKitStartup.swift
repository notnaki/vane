import WebKit

/// Registry class methods need WebKit's main run loop initialized even when no window
/// has opened yet. A nonpersistent store does this without a page or a disk-backed store.
@MainActor enum WebKitStartup {
    private static let initialized: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

    static func prepare() { _ = initialized }
}
