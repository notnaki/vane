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

@MainActor private enum EaselOpening {
    static var defaults: [ObjectIdentifier: Task<Tab?, Never>] = [:]
}

extension TabStore {
    /// Opening an existing board focuses its tab in this Space; a new board is pinned.
    @discardableResult func openEasel(_ boardID: UUID? = nil, create: Bool = false) -> Tab? {
        guard !isPrivate, !isLittle else { return nil }
        let repository = EaselStore.shared(profileID: profileID, directory: Store.directory)
        if repository.background && (repository.loading || create || (boardID == nil && repository.boards.isEmpty)) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await openEaselAsync(boardID, create: create)
            }
            return nil
        }
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

    @discardableResult func openEaselAsync(_ boardID: UUID? = nil, create: Bool = false) async -> Tab? {
        guard !isPrivate, !isLittle else { return nil }
        // Several UI requests can arrive while the initial library is loading. Share
        // the default-open operation so an empty library receives just one first board.
        if boardID == nil && !create {
            let key = ObjectIdentifier(self)
            if let pending = EaselOpening.defaults[key] { return await pending.value }
            let pending = Task { @MainActor [self] in await resolveEasel(nil, create: false) }
            EaselOpening.defaults[key] = pending
            let result = await pending.value
            EaselOpening.defaults[key] = nil
            return result
        }
        return await resolveEasel(boardID, create: create)
    }
    private func resolveEasel(_ boardID: UUID?, create: Bool) async -> Tab? {
        let repository = EaselStore.shared(profileID: profileID, directory: Store.directory)
        await repository.waitUntilReady()
        do {
            let id: UUID
            if create { id = try await repository.createAsync().id }
            else if let boardID { id = boardID }
            else if let recent = tabs.compactMap(\.easelSession).first?.selected ?? repository.boards.first?.id { id = recent }
            else { id = try await repository.createAsync().id }
            guard !isPrivate, !isLittle else { return nil }
            return openEasel(id)
        } catch { Toasts.show(error.localizedDescription); return nil }
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
