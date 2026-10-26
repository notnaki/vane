import Combine
import SwiftUI

/// Shared mutations of the settled sidebar and its captured Space previews.
/// Each @Published source skips its own initial value; the protection subject
/// has no initial value and must revoke snapshots on the sending turn.
extension TabStore {
    var sidebarSnapshotChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            sidebarChange($tabs), sidebarChange($pins), sidebarChange($todayShape),
            sidebarChange($splits), sidebarChange($current), sidebarChange($selection),
            sidebarChange($collapsedPinnedSpaces), sidebarChange($currentSpaceID),
            sidebarChange($spaceRevision), sidebarChange($previewSpace),
            sidebarChange($profileVisible), sidebarPreviewInvalidated.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
    }
}

private func sidebarChange<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
    publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
}

/// The structure and interaction owners intentionally have different lifetimes.
/// Scopes describe consumers, not a whitelist of Tab metadata: real Tab notifications
/// continue through their existing observers, including explicit title/mute sends.
enum SidebarObservationScope: Hashable {
    case all
    case window
    case structure
    case interactionLifetime
    case tab(Tab.ID)
    case surface(Tab.ID)
    case folder(UUID)
}

private final class WeakSidebarObservation {
    weak var value: SidebarObservation?
    init(_ value: SidebarObservation) { self.value = value }
}

/// Sidebar rows draw a small part of the window's state. The legacy shared boundary
/// remains intact; the default-off experiment opts consumers into focused boundaries.
@MainActor final class SidebarObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscriptions: [AnyCancellable] = []
    private var structural: SidebarObservation?
    private weak var store: TabStore?
    private var focused: [SidebarObservationScope: WeakSidebarObservation] = [:]

    init(store: TabStore, scope: SidebarObservationScope = .all) {
        self.store = store
        if scope == .window {
            observe(store.objectWillChange.eraseToAnyPublisher())
            return
        }
        if scope == .all {
            observe(Publishers.MergeMany([
                store.sidebarSnapshotChanges,
                sidebarChange(store.$renamingTab), sidebarChange(store.$renamingFolder),
                sidebarChange(store.$renamingSpace), sidebarChange(store.$announcing),
                sidebarChange(store.$creatingSpace)
            ]).eraseToAnyPublisher())
            return
        }

        if scope == .structure {
            // All structural and protection sources still forward synchronously. Split
            // focus is the one explicitly nonstructural field; normalizing it preserves
            // every other Split field, including future fields, in structural equality.
            observe(Publishers.MergeMany([
                sidebarChange(store.$tabs), sidebarChange(store.$pins), sidebarChange(store.$todayShape),
                store.$splits.map { splits in splits.map { $0.focusing($0.tabs[0]) } }
                    .removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
                sidebarChange(store.$collapsedPinnedSpaces), sidebarChange(store.$currentSpaceID),
                sidebarChange(store.$spaceRevision), sidebarChange(store.$previewSpace),
                sidebarChange(store.$profileVisible), store.sidebarPreviewInvalidated.eraseToAnyPublisher(),
                sidebarChange(store.$renamingSpace), sidebarChange(store.$announcing),
                sidebarChange(store.$creatingSpace)
            ]).eraseToAnyPublisher())
        } else {
            // Share the structural fan-in; one lightweight row observer must not
            // create another subscription to every large outline publisher.
            let structural = store.sidebarObservation.observation(for: .structure)
            self.structural = structural
            observe(structural.objectWillChange.eraseToAnyPublisher())
        }

        switch scope {
        case .tab(let id), .surface(let id):
            let isSurface = scope == .surface(id)
            // Combine incoming published values, never a read of the store inside a
            // will-change callback. This also handles split membership changing before
            // the next current assignment without retaining a stale projection.
            observe(store.$current.combineLatest(store.$splits).map { current, splits -> Tab.ID? in
                guard let current else { return nil }
                if current == id { return current }
                guard !isSurface, splits.first(where: { $0.contains(id) })?.contains(current) == true else { return nil }
                return current
            }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher())
            if isSurface {
                observe(store.$selection.map { $0.contains(id) }.removeDuplicates()
                    .dropFirst().map { _ in () }.eraseToAnyPublisher())
            } else {
                // A selected row's menu depends on the complete membership, not only
                // its count. Unselected rows have no selection-dependent bulk controls.
                observe(store.$selection.map { $0.contains(id) ? $0 : Selection() }.removeDuplicates()
                    .dropFirst().map { _ in () }.eraseToAnyPublisher())
                observe(store.$splits.map { $0.first { $0.contains(id) } }.removeDuplicates()
                    .dropFirst().map { _ in () }.eraseToAnyPublisher())
                // Split AX titles and the audible-pane trailing control consume every
                // pane's metadata. Rebind on incoming membership/object replacement;
                // forwarding the full notification preserves manual Tab notifications.
                let panes = store.$tabs.combineLatest(store.$splits).map { tabs, splits -> [Tab] in
                    guard let split = splits.first(where: { $0.contains(id) }) else { return [] }
                    return tabs.filter { split.contains($0.id) }
                }.removeDuplicates { old, new in
                    old.map(ObjectIdentifier.init) == new.map(ObjectIdentifier.init)
                }
                observe(panes.map { tabs in
                    Publishers.MergeMany(tabs.map { $0.objectWillChange.eraseToAnyPublisher() })
                        .eraseToAnyPublisher()
                }.switchToLatest().eraseToAnyPublisher())
                // Every tooltip disables while a tab is renamed; only the light row
                // wrapper observes the global nil/non-nil transition.
                observe(store.$renamingTab.map { $0 == nil }.removeDuplicates()
                    .dropFirst().map { _ in () }.eraseToAnyPublisher())
            }
            observe(store.$renamingTab.map { $0 == id }.removeDuplicates()
                .dropFirst().map { _ in () }.eraseToAnyPublisher())
        case .folder(let id):
            observe(store.$renamingFolder.map { $0 == id }.removeDuplicates()
                .dropFirst().map { _ in () }.eraseToAnyPublisher())
        case .interactionLifetime:
            // Native/retained owners must protect a newly edited row before it moves
            // offscreen, even though the section's actual row structure is unchanged.
            observe(Publishers.Merge(sidebarChange(store.$renamingTab), sidebarChange(store.$renamingFolder))
                .eraseToAnyPublisher())
        case .all, .window, .structure: break
        }
    }

    private func observe(_ publisher: AnyPublisher<Void, Never>) {
        subscriptions.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    func observation(for scope: SidebarObservationScope) -> SidebarObservation {
        guard scope != .all, let store else { return self }
        if let existing = focused[scope]?.value { return existing }
        // Do not retain observers for deleted rows or detached hosting roots.
        focused = focused.filter { $0.value.value != nil }
        let observation = SidebarObservation(store: store, scope: scope)
        focused[scope] = WeakSidebarObservation(observation)
        return observation
    }
}

/// Observe sidebar state while keeping the original store as the action target.
/// Explicit ownership also works in native drag and swipe preview hosting trees.
@MainActor @propertyWrapper struct SidebarObserved: DynamicProperty {
    private let target: TabStore
    @ObservedObject private var observation: SidebarObservation

    init(wrappedValue: TabStore, scope: SidebarObservationScope = .all,
         experimental: Bool = RenderPerformanceExperiment.rowSelection, legacyWholeStore: Bool = false) {
        target = wrappedValue
        _observation = ObservedObject(wrappedValue: wrappedValue.sidebarObservation
            .observation(for: experimental ? scope : (legacyWholeStore ? .window : .all)))
    }

    var wrappedValue: TabStore { target }
}
