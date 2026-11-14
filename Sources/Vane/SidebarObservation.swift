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

/// Sidebar rows draw a small part of the window's state. Keeping this boundary
/// separate prevents search and page-chrome publications from rebuilding every row.
@MainActor final class SidebarObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?
    private var mutationDepth = 0
    private var pendingChange = false

    /// This object is a rendering bridge, not the store's model publisher. A close
    /// changes several model properties; invalidate its hosting roots once with the
    /// completed state, before returning to the caller. Sending at the first write
    /// lets another hosting root flush and retain an intermediate outline instead.
    /// The original model and snapshot/protection publishers still send immediately.
    func withCompletedChanges<T>(_ body: () throws -> T) rethrows -> T {
        mutationDepth += 1
        defer {
            mutationDepth -= 1
            if mutationDepth == 0, pendingChange {
                pendingChange = false
                objectWillChange.send()
            }
        }
        return try body()
    }

    private func changed() {
        if mutationDepth > 0 { pendingChange = true }
        else { objectWillChange.send() }
    }

    init(store: TabStore) {
        subscription = Publishers.MergeMany([
            store.sidebarSnapshotChanges,
            // Live controls redraw for these changes; captured previews do not.
            sidebarChange(store.$renamingTab), sidebarChange(store.$renamingFolder),
            sidebarChange(store.$renamingSpace), sidebarChange(store.$announcing),
            sidebarChange(store.$creatingSpace)
        ]).sink { [weak self] _ in self?.changed() }
    }
}

/// Observe sidebar state while keeping the original store as the action target.
/// Explicit ownership also works in native drag and swipe preview hosting trees.
@MainActor @propertyWrapper struct SidebarObserved: DynamicProperty {
    private let target: TabStore
    @ObservedObject private var observation: SidebarObservation

    init(wrappedValue: TabStore) {
        target = wrappedValue
        _observation = ObservedObject(wrappedValue: wrappedValue.sidebarObservation)
    }

    var wrappedValue: TabStore { target }
}
