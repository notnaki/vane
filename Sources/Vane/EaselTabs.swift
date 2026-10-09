import AppKit
import SwiftUI

/// A local document address, persisted by the existing tab/session/Space machinery.
/// It carries no filesystem path and resolves only inside the tab's own profile.
enum EaselAddress {
    static func url(_ id: UUID) -> URL {
        URL(string: "vane://easel/\(id.uuidString)")!
    }

    static func boardID(_ url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "vane", url.host?.lowercased() == "easel",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// Addresses that can return in a saved browser tab. Files and arbitrary custom
/// schemes remain transient; an Easel is a profile-local document, not a web page.
enum TabAddress {
    static func restorable(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            || EaselAddress.boardID(url) != nil
    }
}

extension TabStore {
    /// Opening an existing board focuses its tab in this Space; a new board is pinned.
    @discardableResult func openEasel(_ boardID: UUID? = nil, create: Bool = false) -> Tab? {
        guard !isPrivate, !isLittle else { return nil }
        let repository = EaselStore.shared(profileID: profileID, directory: Store.directory)
        do {
            let id: UUID
            if create { id = try repository.create().id }
            else if let boardID { id = boardID }
            else if let recent = tabs.compactMap(\.easelSession).first?.selected ?? repository.boards.first?.id {
                id = recent
            } else { id = try repository.create().id }
            guard repository.board(id) != nil else { throw EaselStore.Failure.missing }
            let tab = tabs.first { $0.easelID == id }
                ?? newBlankTab(focus: false, as: .pinned, loading: EaselAddress.url(id))
            libraryOpen = false
            palette = nil
            findOpen = false
            current = tab.id
            savePins()
            saveCurrentSpace()
            focusPage()
            return tab
        } catch {
            Toasts.show(error.localizedDescription)
            return nil
        }
    }

    /// Local canvases use AppKit's native responder chain, not a dummy WKWebView.
    var activePageResponder: NSView? {
        guard let tab = active, ownsPage(tab), !tab.needsRecovery else { return nil }
        if let session = tab.easelSession {
            return EaselHostingView.find(session, in: window?.contentView)
        }
        return tab.web
    }
}

/// Reuse the same editor and Edit-menu responder inside a browser page card.
struct EaselTabPage: NSViewRepresentable {
    let session: EaselSession
    let store: TabStore

    func makeNSView(context: Context) -> EaselHostingView {
        EaselHostingView(rootView: EaselWorkspace(session: session, browser: store))
    }
    func updateNSView(_ view: EaselHostingView, context: Context) {
        view.rootView = EaselWorkspace(session: session, browser: store)
    }
    static func dismantleNSView(_ view: EaselHostingView, coordinator: ()) {
        view.session.liveItems.removeAll()
    }
}
