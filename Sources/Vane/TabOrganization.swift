import AppKit
import Combine

/// A profile-scoped review session. Reads live strips first, valid stashes second, and
/// saved Spaces last. Saved rows never need a WebKit page just to be reviewed.
@MainActor final class TabOrganization: ObservableObject {
    struct Row: Identifiable {
        let id: UUID
        let spaceID: UUID?
        let spaceName: String
        let url: URL
        let title: String
        let kind: TabKind
        let canChange: Bool
        let named: Bool
        let active: Bool
    }
    struct DuplicateGroup: Identifiable {
        let id: String
        let rows: [Row]
    }
    private struct Record {
        var id: UUID
        var url: URL?
        var home: URL?
        var kind: TabKind
        var parked: Parked
        var tab: Tab?
        var customName: String? = nil
        var savedURL: URL? { home ?? url }
    }
    private struct State {
        var space: Space
        var records: [Record]
        var pins: Pins
        var today: Pins
        var splits: [Split]
        var mark: Mark {
            Mark(ids: records.map(\.id), pages: records.map { $0.url?.absoluteString },
                 homes: records.map { $0.home?.absoluteString }, kinds: records.map(\.kind),
                 pins: pins, today: today, splits: splits)
        }
    }
    private struct Mark: Equatable {
        var ids: [UUID]
        var pages: [String?]
        var homes: [String?]
        var kinds: [TabKind]
        var pins: Pins
        var today: Pins
        var splits: [Split]

        /// A saved Space receives fresh row IDs when opened. Compare its page/order and
        /// folder membership, while retaining identity-sensitive ordering for live rows.
        func matches(_ other: Mark) -> Bool {
            guard pages == other.pages, homes == other.homes, kinds == other.kinds else { return false }
            if Set(ids) == Set(other.ids), ids != other.ids { return false }
            let names = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element.uuidString, "row:\($0.offset)") })
            let otherNames = Dictionary(uniqueKeysWithValues: other.ids.enumerated().map { ($0.element.uuidString, "row:\($0.offset)") })
            guard pins.mapped({ names[$0] }) == other.pins.mapped({ otherNames[$0] }),
                  today.mapped({ names[$0] }) == other.today.mapped({ otherNames[$0] }) else { return false }
            func splitMarks(_ list: [Split], ids: [UUID]) -> [SplitMark] {
                list.map { split in
                    SplitMark(rows: split.tabs.map { ids.firstIndex(of: $0) ?? -1 },
                              vertical: split.vertical, weights: split.weights)
                }
            }
            // Pane focus is window selection, and merely viewing a page must not block undo.
            return splitMarks(splits, ids: ids) == splitMarks(other.splits, ids: other.ids)
        }
    }
    private struct SplitMark: Equatable {
        var rows: [Int]
        var vertical: Bool
        var weights: [Double]
    }
    private struct UndoRecord {
        var before: [State]
        var after: [UUID: Mark]
        var previousArchive: [Archive.Entry]
        var addedArchive: [Archive.Entry]
    }
    private struct DiskKey: Hashable {
        var profile: UUID
        var space: UUID?
        var kind: TabKind
        var url: URL
        var occurrence: Int
    }
    // One undo per profile survives dismissing or reopening the organizer.
    private static var saved: [UUID: UndoRecord] = [:]
    private static var diskIDs: [DiskKey: UUID] = [:]
    private weak var store: TabStore?
    let profileID: UUID
    @Published private(set) var rows: [Row] = []
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var canUndo = false
    @Published var selection = Set<UUID>()
    @Published var message = ""
    private var observations: [AnyCancellable] = []
    private var tabObservations: [AnyCancellable] = []
    private var observedTabs = Set<ObjectIdentifier>()
    private var refreshQueued = false
    private var sessionSaveFailed = false

    init(store: TabStore) {
        self.store = store
        profileID = store.profileID
        refresh()
        let publishers = TabStore.all.filter { $0.profileID == profileID }.map(\.objectWillChange)
            + [ProfileManager.shared.objectWillChange]
        observations = publishers.map { publisher in
            publisher.sink { [weak self] _ in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    static func hasUndo(in store: TabStore) -> Bool {
        !store.isPrivate && !store.isLittle && saved[store.profileID] != nil
    }

    private var available: Bool {
        guard let store else { return false }
        return !store.isPrivate && !store.isLittle && store.profileID == profileID
    }

    var duplicateGroups: [DuplicateGroup] {
        var order: [String] = []
        var grouped: [String: [Row]] = [:]
        for row in rows {
            let key = row.url.absoluteString
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }
        return order.compactMap { key in
            guard let members = grouped[key], members.count > 1 else { return nil }
            return DuplicateGroup(id: key, rows: members)
        }
    }

    /// An explicit convenience action, never an automatic cleanup. Prefer protected,
    /// named, active or playing copies as keepers; users can adjust every checkbox.
    func selectDuplicateExtras() {
        refresh()
        let extras = Set(duplicateGroups.flatMap { group -> [UUID] in
            let keeper = group.rows.first { !$0.canChange || $0.named || $0.active } ?? group.rows[0]
            return group.rows.filter { $0.id != keeper.id && $0.canChange && !$0.named && !$0.active }.map(\.id)
        })
        Motion.list { selection = extras }
    }

    func refresh() {
        guard available else { rows = []; spaces = []; canUndo = false; return }
        let tabs = TabStore.all.filter { $0.sharesTabs && $0.profileID == profileID }.flatMap(\.everyTab)
        let identities = Set(tabs.map(ObjectIdentifier.init))
        if identities != observedTabs {
            observedTabs = identities
            var seen = Set<ObjectIdentifier>()
            tabObservations = tabs.filter { seen.insert(ObjectIdentifier($0)).inserted }.map { tab in
                tab.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
            }
        }
        let states = capture(flush: false)
        spaces = states.map(\.space)
        rows = states.flatMap { state in state.records.compactMap { record in row(record, in: state) } }
        // Favourites belong to the profile, so show them once rather than once per Space.
        let favourites = TabStore.all.first { $0.sharesTabs && $0.profileID == profileID }?
            .tabs.filter { $0.kind == .favourite }
        if let favourites {
            rows += favourites.compactMap { tab in
                guard let url = tab.currentURL, TabAddress.restorable(url) else { return nil }
                return Row(id: tab.id, spaceID: nil, spaceName: "Favourites", url: url,
                           title: TidyTitles.title(for: tab), kind: .favourite, canChange: false,
                           named: true, active: false)
            }
        } else {
            rows += Spaces.favourites(for: profileID).enumerated().map { index, url in
                Row(id: diskID(space: nil, kind: .favourite, url: url, occurrence: index),
                    spaceID: nil, spaceName: "Favourites", url: url,
                    title: TidyTitles.previewName(for: url, in: profileID, saved: "", stays: true),
                    kind: .favourite, canChange: false, named: true, active: false)
            }
        }
        selection.formIntersection(Set(rows.filter(\.canChange).map(\.id)))
        canUndo = undoIsCurrent(states)
    }

    private func row(_ record: Record, in state: State) -> Row? {
        guard let url = record.url, TabAddress.restorable(url),
              state.pins.lockedFolders(for: record.id.uuidString, unlocked: []).isEmpty,
              state.today.lockedFolders(for: record.id.uuidString, unlocked: []).isEmpty else { return nil }
        let split = state.splits.contains { $0.contains(record.id) }
        let active = TabStore.all.contains { $0.profileID == profileID && $0.current == record.id }
            || record.tab.map(TabAudio.isPlaying) == true
        return Row(id: record.id, spaceID: state.space.id, spaceName: state.space.name, url: url,
                   title: record.tab.map { TidyTitles.title(for: $0) }
                    ?? record.customName.map { $0.isEmpty ? record.parked.title : $0 }
                    ?? TidyTitles.previewName(for: record.savedURL ?? url, in: profileID,
                                              saved: record.parked.title, stays: record.kind != .today),
                   kind: record.kind, canChange: record.kind == .today && !split,
                   named: record.customName.map { !$0.isEmpty } ?? (TidyTitles.override(for: record.savedURL ?? url, in: profileID) != nil),
                   active: active)
    }

    private func diskID(space: UUID?, kind: TabKind, url: URL, occurrence: Int) -> UUID {
        let key = DiskKey(profile: profileID, space: space, kind: kind, url: url, occurrence: occurrence)
        if let id = Self.diskIDs[key] { return id }
        let id = UUID()
        Self.diskIDs[key] = id
        return id
    }

    private func capture(flush: Bool = true) -> [State] {
        if flush { SharedTabs.flush() }
        return ProfileManager.shared.spaces(for: profileID).map { space in
            let holders = TabStore.all.filter { $0.sharesTabs && $0.profileID == profileID }
            if let owner = holders.first(where: { $0.currentSpaceID == space.id }) {
                return state(space, tabs: owner.tabs, pins: owner.pins, today: owner.todayShape, splits: owner.splits)
            }
            for owner in holders {
                if let stash = owner.stashes[space.id], stash.fingerprint == owner.fingerprint(of: space.id) {
                    return state(space, tabs: stash.tabs, pins: stash.pins, today: stash.todayShape, splits: stash.splits)
                }
            }
            let parked = Suspension.SpaceState.load(space: space.id, profileID: profileID, in: Store.directory)
            if let layout = space.layout, layout.matches(space), (try? layout.validate()) != nil {
                let records = layout.tabs.map { page in
                    Record(id: page.id, url: page.url, home: page.home, kind: page.kind,
                           parked: parked[page.savedURL.absoluteString] ?? Parked(title: page.title),
                           tab: nil, customName: page.customName ?? "")
                }
                let splits = layout.splits.compactMap { saved -> Split? in
                    guard let ids = saved.ids?.compactMap(UUID.init(uuidString:)),
                          var split = Split(tabs: ids, vertical: saved.vertical) else { return nil }
                    if let weights = saved.weights { split = split.withWeights(weights) }
                    return split.focusing(ids[saved.active])
                }
                return State(space: space, records: records, pins: layout.pins, today: layout.today, splits: splits)
            }
            var records: [Record] = []
            for kind in [TabKind.pinned, .today] {
                let urls = kind == .pinned ? space.pinnedTabURLs ?? [] : space.tabURLs
                var counts: [URL: Int] = [:]
                for url in urls {
                    let occurrence = counts[url, default: 0]
                    counts[url] = occurrence + 1
                    let snapshot = parked[url.absoluteString] ?? Parked()
                    records.append(Record(id: diskID(space: space.id, kind: kind, url: url, occurrence: occurrence),
                                          url: snapshot.page ?? url, home: kind == .today ? nil : url,
                                          kind: kind, parked: snapshot, tab: nil))
                }
            }
            @MainActor func shape(_ kind: TabKind) -> Pins {
                TabStore.adopted(TabStore.savedShape(kind, space: space.id, profileID: profileID),
                    opened: records.filter { $0.kind == kind }.compactMap { record in
                        record.savedURL.map { ($0.absoluteString, record.id.uuidString) }
                    })
            }
            return State(space: space, records: records, pins: shape(.pinned), today: shape(.today), splits: [])
        }
    }

    private func state(_ space: Space, tabs: [Tab], pins: Pins, today: Pins, splits: [Split]) -> State {
        State(space: space, records: tabs.filter { $0.kind != .favourite }.map {
            Record(id: $0.id, url: $0.currentURL, home: $0.homeURL, kind: $0.kind, parked: $0.snapshot, tab: $0,
                   customName: $0.workspaceName ?? $0.pinnedURL.flatMap { TidyTitles.override(for: $0, in: profileID) })
        }, pins: pins, today: today, splits: splits)
    }

    /// Revalidate against the actual pages the user reviewed, including navigation and
    /// profile/lock changes while the sheet was open. A changed selection is never applied.
    private func reviewedSelection(in states: [State]) -> [Row]? {
        let expected = rows.filter { selection.contains($0.id) }
        let current = states.flatMap { state in state.records.compactMap { record in row(record, in: state) } }
        guard !selection.isEmpty, expected.count == selection.count,
              expected.allSatisfy({ old in current.contains {
                  $0.id == old.id && $0.url == old.url && $0.spaceID == old.spaceID && $0.canChange
              } }) else {
            message = "Selected tabs changed or are protected. Refresh and review the selection again."
            refresh()
            return nil
        }
        return expected
    }

    @discardableResult func archiveSelected(duplicatesOnly: Bool = false) -> Bool {
        guard available else { return false }
        let before = capture()
        guard let selected = reviewedSelection(in: before) else { return false }
        let ids = Set(selected.map(\.id))
        if duplicatesOnly {
            // Include current protected copies, not an old duplicate count from the sheet.
            refresh()
            guard selected.allSatisfy({ row in
                rows.contains { $0.url == row.url && !ids.contains($0.id) }
            }) else {
                message = "Keep at least one copy of each page. Untick the copies you want to keep."
                return false
            }
        }
        var after = before.filter { $0.records.contains { ids.contains($0.id) } }
        let affected = Set(after.map { $0.space.id })
        var undoBefore = before.filter { affected.contains($0.space.id) }
        for index in after.indices {
            after[index].records.removeAll { ids.contains($0.id) }
            for id in ids { after[index].today.remove(tab: id.uuidString) }
            after[index].today.removeEmptyFolders()
        }
        guard commit(after) else { return false }
        let archive = Archive.shared(for: profileID)
        let previous = archive.entries.filter { entry in selected.contains { $0.url.absoluteString == entry.url } }
        for row in selected { archive.add(url: row.url, title: row.title, space: row.spaceID) }
        // Closed pages are reconstructed from their own snapshots on undo. Never reuse a
        // torn-down WebKit object; moved tabs retain their identity and live object instead.
        for index in undoBefore.indices {
            for record in undoBefore[index].records.indices where ids.contains(undoBefore[index].records[record].id) {
                undoBefore[index].records[record].tab = nil
            }
        }
        Self.saved[profileID] = UndoRecord(before: undoBefore,
            after: Dictionary(uniqueKeysWithValues: capture().filter { affected.contains($0.space.id) }.map { ($0.space.id, $0.mark) }),
            previousArchive: previous,
            addedArchive: archive.entries.filter { entry in selected.contains { $0.url.absoluteString == entry.url } })
        finished("Archived \(selected.count) tabs")
        return true
    }

    @discardableResult func moveSelected(to destination: UUID) -> Bool {
        guard available else { return false }
        let before = capture()
        guard let target = before.firstIndex(where: { $0.space.id == destination }),
              let selected = reviewedSelection(in: before) else { return false }
        let ids = Set(selected.filter { $0.spaceID != destination }.map(\.id))
        guard !ids.isEmpty else { message = "These tabs are already in that Space."; return false }
        var after = before
        let moved = before.flatMap(\.records).filter { ids.contains($0.id) }
        let affected = Set(selected.filter { ids.contains($0.id) }.compactMap(\.spaceID) + [destination])
        for index in after.indices {
            after[index].records.removeAll { ids.contains($0.id) }
            for id in ids { after[index].today.remove(tab: id.uuidString) }
            after[index].today.removeEmptyFolders()
        }
        after[target].records += moved
        after[target].today.sync(tabs: after[target].records.filter { $0.kind == .today }.map(\.id.uuidString))
        guard commit(after.filter { affected.contains($0.space.id) }) else { return false }
        Self.saved[profileID] = UndoRecord(before: before.filter { affected.contains($0.space.id) },
            after: Dictionary(uniqueKeysWithValues: capture().filter { affected.contains($0.space.id) }.map { ($0.space.id, $0.mark) }),
            previousArchive: [], addedArchive: [])
        finished("Moved \(moved.count) tabs to \(after[target].space.name)")
        return true
    }

    private func undoIsCurrent(_ states: [State]) -> Bool {
        guard let undo = Self.saved[profileID] else { return false }
        let current = Dictionary(uniqueKeysWithValues: states.map { ($0.space.id, $0.mark) })
        return undo.after.allSatisfy { id, mark in current[id].map { mark.matches($0) } == true }
    }

    @discardableResult func undo() -> Bool {
        let current = available ? capture() : []
        guard available, let undo = Self.saved[profileID], undoIsCurrent(current) else {
            message = "Tabs or folders changed since this action. Undo would overwrite those changes."
            refresh()
            return false
        }
        // Surviving saved rows may now be live with new IDs. Keep those live objects and
        // their latest page state; only resurrect the archived rows from the old snapshots.
        var survivors: [UUID: Record] = [:]
        for state in current {
            guard let expected = undo.after[state.space.id] else { continue }
            for (oldID, record) in zip(expected.ids, state.records) { survivors[oldID] = record }
        }
        var restoring = undo.before
        for index in restoring.indices {
            restoring[index].records = restoring[index].records.map { survivors[$0.id] ?? $0 }
            restoring[index].pins = restoring[index].pins.mapped { raw in
                UUID(uuidString: raw).flatMap { survivors[$0]?.id.uuidString } ?? raw
            }
            restoring[index].today = restoring[index].today.mapped { raw in
                UUID(uuidString: raw).flatMap { survivors[$0]?.id.uuidString } ?? raw
            }
            if let live = current.first(where: { $0.space.id == restoring[index].space.id }) {
                restoring[index].splits = live.splits
            }
        }
        guard commit(restoring) else { return false }
        let archive = Archive.shared(for: profileID)
        for entry in undo.addedArchive where archive.entries.contains(entry) {
            archive.remove(entry.id)
            if let old = undo.previousArchive.first(where: { $0.id == entry.id }), let url = URL(string: old.url) {
                archive.add(url: url, title: old.title, at: old.at, space: old.space, littleArc: old.isLittleArc)
            }
        }
        Self.saved[profileID] = nil
        message = "Undid tab organization." + (sessionSaveFailed ? " The session could not be saved." : "")
        refresh()
        rebuild()
        return true
    }

    private func finished(_ text: String) {
        selection = []
        message = text + "." + (sessionSaveFailed ? " The session could not be saved." : "")
        refresh()
        rebuild()
        if let store {
            Toasts.show(text, action: ("Undo", { [self] in _ = undo() }), in: store)
        }
        axAnnounce(message)
    }

    /// Save the profile list atomically before changing live membership. Sidecars are
    /// staged first and rolled back on failure. Folder shapes only write after both succeed.
    private func commit(_ states: [State]) -> Bool {
        var spaces = ProfileManager.shared.spaces(for: profileID)
        guard states.allSatisfy({ state in spaces.contains { $0.id == state.space.id } }) else {
            message = "A Space changed profiles or was deleted. Refresh and try again."
            return false
        }
        let sessionURL = ProfileManager.sessionURL(for: profileID, in: Store.directory)
        let sessionBefore = try? Data(contentsOf: sessionURL)
        @MainActor func restoreSession() {
            if let sessionBefore, !SnapshotPersistence.write(sessionBefore, to: sessionURL) {
                message = "Could not restore the session snapshot. Check storage and retry."
            }
        }
        for state in states {
            guard Session.forget(space: state.space.id, in: profileID) else {
                message = "Could not save the session. No tabs were changed."
                restoreSession()
                return false
            }
        }
        let previous = Dictionary(uniqueKeysWithValues: states.map {
            ($0.space.id, Suspension.SpaceState.load(space: $0.space.id, profileID: profileID, in: Store.directory))
        })
        @MainActor func rollback() {
            restoreSession()
            for (id, parked) in previous {
                if !Suspension.SpaceState.save(parked, space: id, profileID: profileID, in: Store.directory) {
                    message = "Could not restore saved page state. Check storage and retry."
                }
            }
        }
        for state in states {
            var parked: [String: Parked] = [:]
            // Match saveCurrentSpace's favourite → pinned → Today precedence. The
            // sidecar is URL-keyed; a wandered favourite must not overwrite Today.
            for tab in TabStore.all.first(where: { $0.sharesTabs && $0.profileID == profileID })?.tabs.filter({ $0.kind == .favourite }) ?? [] {
                if let entry = TabStore.sidecarEntry(page: tab.currentURL, home: tab.homeURL, snapshot: tab.snapshot) {
                    parked[entry.key] = entry.parked
                }
            }
            for record in state.records {
                guard let entry = TabStore.sidecarEntry(page: record.url, home: record.home, snapshot: record.parked) else { continue }
                parked[entry.key] = entry.parked
            }
            guard Suspension.SpaceState.save(parked, space: state.space.id, profileID: profileID, in: Store.directory) else {
                message = "Could not save page state. No tabs were changed."
                rollback()
                return false
            }
            let index = spaces.firstIndex { $0.id == state.space.id }!
            spaces[index].tabURLs = state.records.filter { $0.kind == .today }.compactMap(\.savedURL).filter(TabAddress.restorable)
            spaces[index].pinnedTabURLs = state.records.filter { $0.kind == .pinned }.compactMap(\.savedURL).filter(TabAddress.restorable)
            if spaces[index].layout != nil || state.records.contains(where: { $0.customName != nil }) {
                let pages = state.records.compactMap { record -> SpaceLayout.Page? in
                    guard let url = record.url, let saved = record.savedURL,
                          TabAddress.restorable(url), TabAddress.restorable(saved) else { return nil }
                    return .init(id: record.id, url: url, kind: record.kind, title: record.parked.title,
                                 customName: record.customName, home: record.home)
                }
                let kept = Set(pages.map(\.id))
                let splits = state.splits.compactMap { split -> Split.Saved? in
                    guard split.tabs.allSatisfy(kept.contains) else { return nil }
                    return .init(urls: split.tabs.map { id in pages.first { $0.id == id }!.url.absoluteString },
                                 vertical: split.vertical, active: split.active,
                                 ids: split.tabs.map(\.uuidString), weights: split.weights)
                }
                spaces[index].layout = SpaceLayout(tabs: pages,
                    pins: state.pins.mapped { UUID(uuidString: $0).map(kept.contains) == true ? $0 : nil },
                    today: state.today.mapped { UUID(uuidString: $0).map(kept.contains) == true ? $0 : nil }, splits: splits,
                    selected: state.space.layout?.selected.flatMap { kept.contains($0) ? $0 : nil })
            }
        }
        guard ProfileManager.shared.saveSpaces(spaces, for: profileID) else {
            message = "Could not save Spaces. No tabs were changed."
            rollback()
            return false
        }
        for state in states {
            var counts: [DiskKey: Int] = [:]
            let byID = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id.uuidString, $0.savedURL?.absoluteString) })
            for (kind, shape) in [(TabKind.pinned, state.pins), (.today, state.today)] {
                let key = TabStore.shapeKey(kind, space: state.space.id, profileID: profileID)
                let named = shape.mapped { byID[$0] ?? nil }
                if named.entries.contains(where: { $0.folder != nil }) {
                    UserDefaults.vane.set(try? JSONEncoder().encode(named), forKey: key)
                } else { UserDefaults.vane.removeObject(forKey: key) }
            }
            for record in state.records {
                guard let url = record.savedURL else { continue }
                var key = DiskKey(profile: profileID, space: state.space.id, kind: record.kind, url: url, occurrence: 0)
                let occurrence = counts[key, default: 0]
                counts[key] = occurrence + 1
                key.occurrence = occurrence
                Self.diskIDs[key] = record.id
            }
        }
        publish(states)
        sessionSaveFailed = !Session.save()
        return true
    }

    /// Publish all ends before releasing any page. This preserves a moved live tab and
    /// mirrors changes into every window/stash of the profile, including parked profiles.
    private func publish(_ states: [State]) {
        let holders = TabStore.all.filter { $0.sharesTabs && $0.profileID == profileID }
        let old = holders.flatMap(\.everyTab)
        var materialized: [UUID: Tab] = [:]
        Motion.list {
            for state in states {
                let live = holders.filter { $0.currentSpaceID == state.space.id }
                let stashed = holders.filter { $0.stashes[state.space.id] != nil }
                // Retain incoming live pages in a normal stash when their destination has
                // no window. This uses Space switching's existing lifecycle and idle policy.
                let keepIn = live.isEmpty && stashed.isEmpty && state.records.contains(where: { $0.tab != nil })
                    ? holders.prefix(1).map { $0 } : []
                let owners = live + stashed + keepIn
                guard !owners.isEmpty else { continue }
                let tabs = state.records.map { record -> Tab in
                    if let existing = materialized[record.id] { return existing }
                    let tab = record.tab ?? Tab(id: record.id, profileID: profileID)
                    tab.workspaceName = record.customName
                    if record.tab == nil {
                        tab.kind = record.kind
                        if let url = record.url { tab.restore(url: url, home: record.home, parked: record.parked) }
                    }
                    tab.sharedSpaceID = state.space.id
                    owners[0].wire(tab)
                    materialized[record.id] = tab
                    return tab
                }
                let ids = Set(tabs.map(\.id))
                for owner in owners {
                    if owner.currentSpaceID == state.space.id {
                        owner.tabs = owner.tabs.filter { $0.kind == .favourite } + tabs
                        owner.pins = state.pins
                        owner.todayShape = state.today
                        owner.splits = state.splits
                        owner.selection.keep(tabs.map(\.id))
                        if let current = owner.current, !ids.contains(current),
                           !owner.tabs.contains(where: { $0.id == current }) { owner.current = nil }
                        if let rename = owner.renamingTab, !ids.contains(rename) { owner.renamingTab = nil }
                    } else {
                        let current = owner.stashes[state.space.id]?.current.flatMap { ids.contains($0) ? $0 : nil }
                        owner.stashes[state.space.id] = Stash(tabs: tabs, pins: state.pins, todayShape: state.today,
                            splits: state.splits, current: current, fingerprint: owner.fingerprint(of: state.space.id))
                    }
                }
            }
        }
        SharedTabs.flush()
        for owner in holders {
            for state in states {
                owner.stashes[state.space.id]?.fingerprint = owner.fingerprint(of: state.space.id)
            }
            owner.spacesChanged()
            owner.extensions.sync()
        }
        let retained = Set(holders.flatMap(\.everyTab).map(\.id))
        for tab in old where !retained.contains(tab.id) {
            TabAudio.forget(tab.id)
            MediaState.shared.forget(tab.id)
        }
        SharedTabs.release(old)
        SharedTabs.refreshPresentation()
    }
}
