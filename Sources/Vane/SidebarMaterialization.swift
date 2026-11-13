import AppKit
import Combine

/// Rendering only. Store, snapshot, protection and input ownership still publish normally.
@MainActor final class SidebarMaterialization: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var owner: UUID?
    private var releasedOwner: UUID?
    private var spaceID: UUID?
    private(set) var generation: UInt64 = 0
    private(set) var generationID: UUID?
    private(set) var renderedID: UUID?
    private(set) var favoritesHeight: CGFloat = 0
    private(set) var rowsExtent: CGFloat = 0
    private var rememberedRowsExtent: CGFloat = 0

    var isDeferred: Bool { owner != nil }

    @discardableResult
    func acquire(owner token: UUID, spaceID: UUID?, favoritesHeight: CGFloat,
                 minimumRowsExtent: CGFloat) -> UUID {
        if owner == token, self.spaceID == spaceID, let generationID { return generationID }
        owner = token
        releasedOwner = nil
        self.spaceID = spaceID
        generation &+= 1
        let identity = UUID()
        generationID = identity
        renderedID = nil
        self.favoritesHeight = max(0, favoritesHeight)
        rowsExtent = max(rememberedRowsExtent, max(0, minimumRowsExtent))
        // A completed rendering publication; observers never see half of this lease.
        objectWillChange.send()
        return identity
    }

    @discardableResult
    func release(owner token: UUID) -> Bool {
        guard owner == token else { return false }
        owner = nil
        releasedOwner = token
        #if DEBUG
        ResizeTimingDiagnostics.recordState("profile.materialization.release", fields: ["generation": String(generation)])
        #endif
        objectWillChange.send()
        return true
    }

    func belongs(to token: UUID, generation identity: UUID) -> Bool {
        generationID == identity && (owner == token || owner == nil && releasedOwner == token)
    }

    @discardableResult
    func didRender(_ identity: UUID?) -> Bool {
        guard !isDeferred, identity == generationID else { return false }
        #if DEBUG
        if renderedID != identity {
            ResizeTimingDiagnostics.recordState("profile.materialization.rendered", fields: ["generation": String(generation)])
        }
        #endif
        renderedID = identity
        return true
    }

    func rememberRowsExtent(_ value: CGFloat) {
        guard !isDeferred, value.isFinite else { return }
        rememberedRowsExtent = max(0, value)
    }
}
