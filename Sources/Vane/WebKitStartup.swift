import WebKit
import ExtensionResourceBridge

/// Registry class methods need WebKit's main run loop initialized even when no window
/// has opened yet. A nonpersistent store does this without a page or a disk-backed store.
@MainActor enum WebKitStartup {
    // Legacy WebKit can retain extension IPC receivers after controller retirement.
    // Keep both browser and extension pool owners at application lifetime instead of
    // destroying one per host. Stores and controllers still provide profile isolation.
    static let processPool = VaneWebProcessPoolOwner(extensionResourceRevalidation: true)
    static let extensionProcessPool = VaneWebProcessPoolOwner(extensionResourceRevalidation: true)

    static var revalidatesExtensionResources: Bool {
        processPool.revalidatesExtensionResources
            && extensionProcessPool.revalidatesExtensionResources
    }

    private static let initialized: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

    static func prepare() { _ = initialized }
}
