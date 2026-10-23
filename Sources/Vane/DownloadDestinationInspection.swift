import Foundation

/// One scope start balanced with its exact URL. A worker resolves bookmarks and starts
/// access; a published row retains the lease until replacement/removal. Unpublished late
/// results release their lease without touching UI or another row's grant.
final class DownloadDestinationLease: @unchecked Sendable {
    let url: URL
    private let started: Bool
    init?(_ bookmark: Data) {
        var stale = false
        guard let resolved = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)) else { return nil }
        url = resolved
        started = resolved.startAccessingSecurityScopedResource()
        // Unsandboxed local builds can read ordinary bookmarks without an extension.
        guard started || !NSHomeDirectory().contains("/Library/Containers/") else { return nil }
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
