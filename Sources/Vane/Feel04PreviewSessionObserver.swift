import WebKit

/// Cookie changes retire ordinary preview pixels as well as favourite snapshots.
/// Each renderer observes only its current persistent profile; private stores never attach.
@MainActor final class Feel04PreviewSessionObserver: NSObject, WKHTTPCookieStoreObserver {
    private let store: WKHTTPCookieStore
    private var changed: (@MainActor () -> Void)?
    init(profileID: UUID, changed: @escaping @MainActor () -> Void) {
        store = ProfileManager.dataStore(for: profileID).httpCookieStore
        self.changed = changed
        super.init()
        store.add(self)
    }
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.changed?() }
    }
    func detach() { changed = nil; store.remove(self) }
    isolated deinit { store.remove(self) }
}
