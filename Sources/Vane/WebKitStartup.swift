import WebKit

/// Registry class methods need WebKit's main run loop initialized even when no window
/// has opened yet. A nonpersistent store does this without a page or a disk-backed store.
@MainActor enum WebKitStartup {
    // WebKit can retain extension IPC receiver entries after a controller is retired.
    // Keep their pool at application lifetime instead of destroying a pool per host.
    // Website data stores and extension controllers still provide profile isolation.
    static let processPool = WKProcessPool()

    private static let initialized: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

    static func prepare() { _ = initialized }
}
