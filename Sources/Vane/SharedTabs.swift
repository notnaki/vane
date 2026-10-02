import AppKit
import WebKit

/// Windows keep their own selection and chrome, but a Space has one set of live tabs.
/// Identity, rather than URL, is the sharing boundary: two separately opened copies of a
/// page stay separate. Private and Little Vane windows keep their own pages.
@MainActor enum SharedTabs {
    private static var updating = false
    private static var pending: [TabStore] = []

    static func schedule(from store: TabStore) {
        guard store.sharingReady, store.sharesTabs, !updating, !store.sharedUpdateQueued else { return }
        store.sharedUpdateQueued = true
        pending.append(store)
        DispatchQueue.main.async { flush() }
    }

    /// Finish pending row/folder mutations before saving or leaving a Space. Coalescing
    /// keeps intermediate states of a drag, split or folder move out of other windows.
    static func flush() {
        guard !updating else { return }
        let changes = pending
        pending.removeAll()
        for store in changes {
            store.sharedUpdateQueued = false
            guard TabStore.all.contains(where: { $0 === store }) else { continue }
            synchronize(from: store)
        }
    }

    static func favourites(for store: TabStore) -> [Tab] {
        TabStore.all.first { $0 !== store && $0.sharesTabs && $0.profileID == store.profileID }?
            .tabs.filter { $0.kind == .favourite } ?? []
    }

    static func state(for store: TabStore, space: UUID?) -> Stash? {
        guard let space else { return nil }
        let peers = TabStore.all.filter {
            $0 !== store && $0.sharesTabs && $0.profileID == store.profileID
        }
        let live = peers.filter { $0.currentSpaceID == space }
        if let source = live.first(where: { $0.window?.isKeyWindow == true }) ?? live.first {
            return state(of: source)
        }
        for other in peers {
            if let kept = other.stashes[space], kept.fingerprint == other.fingerprint(of: space) {
                return kept
            }
        }
        return nil
    }

    private static func state(of store: TabStore) -> Stash {
        let tabs = store.tabs.filter { $0.kind != .favourite }
        let ids = Set(tabs.map(\.id))
        return Stash(tabs: tabs, pins: store.pins, todayShape: store.todayShape,
                     splits: store.splits.filter { $0.tabs.allSatisfy(ids.contains) },
                     current: store.current.flatMap { ids.contains($0) ? $0 : nil },
                     fingerprint: "")
    }

    static func existing(_ id: UUID, for store: TabStore) -> Tab? {
        TabStore.all.lazy.filter { $0 !== store && $0.sharesTabs && $0.profileID == store.profileID }
            .flatMap(\.everyTab).first { $0.id == id }
    }

    /// Older session files can contain genuinely different tabs in windows showing the
    /// same Space. Keep every identity, while a repeated identity reuses its live object.
    static func mergeRestored(_ store: TabStore) {
        guard store.sharesTabs, let shared = state(for: store, space: store.currentSpaceID) else { return }
        let ids = Set(store.tabs.map(\.id))
        store.tabs += shared.tabs.filter { !ids.contains($0.id) }
        let favourites = favourites(for: store)
        store.tabs += favourites.filter { !ids.contains($0.id) }
        store.splits = shared.splits
        store.normaliseSections()
        store.syncShapes()
    }

    static func synchronize(from store: TabStore) {
        guard store.sharingReady, store.sharesTabs, !updating else { return }
        updating = true
        defer { updating = false }
        let favourites = store.tabs.filter { $0.kind == .favourite }
        for tab in store.tabs { tab.sharedSpaceID = tab.kind == .favourite ? nil : store.currentSpaceID }
        let shared = state(of: store)
        var displaced: [Tab] = []
        for other in TabStore.all where other !== store && other.sharesTabs
            && other.profileID == store.profileID {
            let previous = other.tabs
            let heldBefore = other.everyTab
            if other.currentSpaceID == store.currentSpaceID {
                other.tabs = store.tabs
                other.pins = store.pins
                other.todayShape = store.todayShape
                // Pane focus follows each window's own selection.
                let remembered = other.splits
                other.splits = store.splits.map { split in
                    let focus = other.current.flatMap { split.contains($0) ? $0 : nil }
                        ?? remembered.first { Set($0.tabs) == Set(split.tabs) }?.activeTab
                    return focus.map { split.focusing($0) } ?? split
                }
            } else {
                other.tabs = favourites + other.tabs.filter {
                    $0.kind != .favourite && $0.sharedSpaceID == other.currentSpaceID
                }
                other.syncShapes()
                let ids = Set(other.tabs.map(\.id))
                other.splits = other.splits.compactMap { split in
                    split.tabs.filter { !ids.contains($0) }.reduce(Optional(split)) { $0?.removing($1) }
                }
            }
            if let space = store.currentSpaceID, let kept = other.stashes[space] {
                var replacement = shared
                replacement.current = kept.current.flatMap { id in shared.tabs.contains { $0.id == id } ? id : nil }
                replacement.splits = shared.splits.map { split in
                    let focus = replacement.current.flatMap { split.contains($0) ? $0 : nil }
                        ?? kept.splits.first { Set($0.tabs) == Set(split.tabs) }?.activeTab
                    return focus.map { split.focusing($0) } ?? split
                }
                replacement.fingerprint = kept.fingerprint
                other.stashes[space] = replacement
            }
            for id in Array(other.stashes.keys) where id != store.currentSpaceID {
                guard var kept = other.stashes[id] else { continue }
                for tab in kept.tabs where tab.kind == .favourite || tab.sharedSpaceID != id {
                    _ = kept.remove(tab.id)
                }
                other.stashes[id] = kept
            }
            reconcileSelection(in: other, previously: previous)
            displaced += heldBefore.filter { tab in !other.everyTab.contains { $0 === tab } }
            other.extensions.sync()
        }
        release(displaced)
        refreshPresentation()
    }

    /// Stashes mirrored from this live strip now describe the newly saved disk state.
    static func didSave(space: UUID, from store: TabStore) {
        let fingerprint = store.fingerprint(of: space)
        let ids = store.tabs.filter { $0.kind != .favourite }.map(\.id)
        for other in TabStore.all where other.profileID == store.profileID {
            if other.stashes[space]?.tabs.map(\.id) == ids {
                other.stashes[space]?.fingerprint = fingerprint
            }
        }
    }

    /// A disk-backed Move to Space must reach a live destination before its next save.
    /// With only stashes, fingerprint validation rebuilds the destination when entered.
    static func receiveSavedTab(_ url: URL, parked: Parked, kind: TabKind,
                                in space: UUID, profileID: UUID) {
        flush()
        guard let holder = TabStore.all.first(where: {
            $0.sharesTabs && $0.profileID == profileID && $0.currentSpaceID == space
        }), !holder.tabs.contains(where: { $0.kind == kind && $0.pinnedURL == url }) else { return }
        let tab = holder.newBlankTab(focus: false, as: kind)
        tab.open(url, parked: parked)
        synchronize(from: holder)
    }

    private static func reconcileSelection(in store: TabStore, previously: [Tab]) {
        let ids = Set(store.tabs.map(\.id))
        store.selection.keep(Array(ids))
        if let id = store.renamingTab, !ids.contains(id) { store.renamingTab = nil }
        guard let selected = store.current, !ids.contains(selected) else { return }
        let i = previously.firstIndex { $0.id == selected } ?? 0
        let rest = store.tabs
        let neighbour = min(i, max(0, rest.count - 1))
        store.current = rest.indices.contains(neighbour) && rest[neighbour].kind == .today
            ? rest[neighbour].id : nil
    }

    /// Remove the identity everywhere before its page is torn down, without re-archiving
    /// it or adding a second entry to Reopen Closed Tab.
    static func remove(_ id: UUID, from source: TabStore) {
        guard source.sharesTabs else { return }
        let wasUpdating = updating
        updating = true
        defer { updating = wasUpdating }
        for store in TabStore.all where store !== source && store.sharesTabs
            && store.profileID == source.profileID {
            let previous = store.tabs
            store.tabs.removeAll { $0.id == id }
            store.pins.remove(tab: id.uuidString)
            store.todayShape.remove(tab: id.uuidString)
            store.todayShape.removeEmptyFolders()
            let pane = store.dropPane(id)
            if store.current == id, let pane { store.current = pane }
            for space in Array(store.stashes.keys) { _ = store.stashes[space]?.remove(id) }
            reconcileSelection(in: store, previously: previous)
            store.extensions.sync()
        }
    }

    /// Closing a window or dropping a stash releases only pages nobody else holds.
    static func release(_ tabs: [Tab], excluding store: TabStore? = nil) {
        for tab in tabs where !TabStore.all.contains(where: {
            $0 !== store && $0.everyTab.contains { $0 === tab }
        }) { tab.tearDown() }
    }

    /// Elect one host per page. Different pages in background windows stay live; only
    /// another presentation of the same tab needs a snapshot.
    static func refreshPresentation() {
        let stores = TabStore.all.filter { $0.window != nil }
        var seen = Set<UUID>()
        for tab in stores.flatMap(\.everyTab) where seen.insert(tab.id).inserted {
            let holders = stores.filter { $0.everyTab.contains { $0 === tab } }
            if holders.count == 1, tab.windowSnapshot != nil { tab.windowSnapshot = nil }
            let visible = holders.filter {
                $0.window?.isMiniaturized == false && $0.onScreenTabs.contains { $0 === tab }
            }
            let owner = visible.first { $0.window?.isKeyWindow == true }
                ?? visible.first { $0.windowID == tab.presentationOwner }
                ?? visible.first
                ?? holders.first { $0.windowID == tab.presentationOwner }
                ?? holders.first
            guard let owner else { continue }
            claim(tab, in: owner)
        }
    }

    private static func claim(_ tab: Tab, in store: TabStore) {
        // Invalidate a pending snapshot even when the user has returned to the current
        // owner: a late callback must never move the page back to a window just left.
        tab.presentationGeneration += 1
        let generation = tab.presentationGeneration
        guard tab.presentationOwner != store.windowID else { return }
        if let session = tab.easelSession,
           let previous = TabStore.all.first(where: { $0.windowID == tab.presentationOwner }),
           let host = EaselHostingView.find(session, in: previous.window?.contentView),
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            tab.windowSnapshot = image
        }
        if tab.presentationOwner != nil, let web = tab.existingWeb, web.window != nil, !tab.suspended {
            web.takeSnapshot(with: nil) { [weak tab, weak store, weak web] image, _ in
                guard let tab, let store, let web,
                      tab.presentationGeneration == generation, tab.existingWeb === web,
                      TabStore.all.contains(where: { $0 === store }),
                      store.everyTab.contains(where: { $0 === tab }) else { return }
                if let image { tab.windowSnapshot = image }
                install(tab, in: store)
            }
        } else {
            install(tab, in: store)
        }
    }

    private static func install(_ tab: Tab, in store: TabStore) {
        store.wire(tab)
        tab.presentationOwner = store.windowID
        if store.current == tab.id { store.focusPage() }
    }
}

extension TabStore {
    var sharesTabs: Bool { !isPrivate && !isLittle && currentSpaceID != nil }
    func ownsPage(_ tab: Tab) -> Bool { tab.presentationOwner == windowID || !sharesTabs }
}
