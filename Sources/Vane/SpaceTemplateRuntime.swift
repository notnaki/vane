import AppKit

extension TabStore {
    /// Capture identities and chrome without reading interactionState or waking a page.
    func workspaceLayout() -> SpaceLayout {
        SharedTabs.flush()
        return Self.workspaceLayout(tabs: tabs, pins: pins, today: todayShape,
                                    splits: splits, selected: current, profile: profileID)
    }

    static func workspaceLayout(tabs: [Tab], pins: Pins, today: Pins, splits: [Split],
                                selected: UUID?, profile: UUID) -> SpaceLayout {
        let mine = tabs.filter { $0.kind != .favourite }
        let pages = mine.compactMap { tab -> SpaceLayout.Page? in
            guard let url = tab.currentURL, TabAddress.restorable(url),
                  let saved = tab.pinnedURL, TabAddress.restorable(saved) else { return nil }
            return .init(id: tab.id, url: url, kind: tab.kind, title: TidyTitles.title(for: tab),
                         customName: tab.workspaceName ?? TidyTitles.override(for: saved, in: profile),
                         home: tab.kind == .pinned ? saved : nil)
        }
        let kept = Set(pages.map { $0.id.uuidString })
        let saved = splits.compactMap { split -> Split.Saved? in
            let surviving = split.tabs.enumerated().filter { kept.contains($0.element.uuidString) }
            guard surviving.count >= 2 else { return nil }
            return .init(urls: surviving.map { item in pages.first { $0.id == item.element }!.url.absoluteString },
                         vertical: split.vertical, active: surviving.firstIndex { $0.offset == split.active } ?? 0,
                         ids: surviving.map { $0.element.uuidString },
                         weights: Split.normalised(surviving.map { split.weights[$0.offset] }))
        }
        var pinShape = pins.mapped { kept.contains($0) ? $0 : nil }
        var todayShape = today.mapped { kept.contains($0) ? $0 : nil }
        pinShape.sync(tabs: pages.filter { $0.kind == .pinned }.map { $0.id.uuidString })
        todayShape.sync(tabs: pages.filter { $0.kind == .today }.map { $0.id.uuidString })
        return SpaceLayout(tabs: pages, pins: pinShape, today: todayShape, splits: saved,
            selected: selected.flatMap { kept.contains($0.uuidString) ? $0 : nil }, omitted: mine.count - pages.count)
    }

    /// Legacy readers use the URL lists; this reader additionally restores distinct rows.
    @discardableResult
    func restoreWorkspaceLayout(_ space: Space, parked: [String: Parked]) -> Bool {
        guard let layout = space.layout, layout.matches(space), (try? layout.validate()) != nil else { return false }
        for page in layout.tabs {
            let tab = newBlankTab(focus: false, as: page.kind, id: page.id)
            tab.workspaceName = page.customName ?? ""
            tab.restore(url: page.url, home: page.home,
                        parked: parked[page.savedURL.absoluteString] ?? Parked(title: page.title))
        }
        pins = layout.pins; todayShape = layout.today
        applyOrder(.pinned); applyOrder(.today)
        applySplits(layout.splits)
        current = layout.selected ?? tabs.first { $0.kind == .today }?.id ?? tabs.first { $0.kind == .pinned }?.id
        return true
    }

    /// Session entries already carry page state; only recover the identity-based folders.
    func applyWorkspaceFolders(_ layout: SpaceLayout) {
        let ids = Set(tabs.filter { $0.kind != .favourite }.map(\.id))
        guard Set(layout.tabs.map(\.id)) == ids, (try? layout.validate()) != nil else { return }
        pins = layout.pins; todayShape = layout.today
        applyOrder(.pinned); applyOrder(.today)
    }
}

/// A sheet request fixes its profile and source Space so a profile hop cannot save elsewhere.
struct WorkspaceSheetRequest: Identifiable {
    let id = UUID()
    let profileID: UUID
    let sourceID: UUID?
    let saving: Bool
}

extension TabStore {
    func showWorkspaceTemplates(saving: Bool = false) {
        guard !isPrivate, !isLittle, !saving || currentSpaceID != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !isPrivate, !isLittle else { return }
            workspaceSheet = .init(profileID: profileID, sourceID: currentSpaceID, saving: saving)
        }
    }
}
