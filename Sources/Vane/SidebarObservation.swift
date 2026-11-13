import Combine
import SwiftUI

/// Shared mutations of the settled sidebar and its captured Space previews.
/// Each @Published source skips its own initial value; the protection subject
/// has no initial value and must revoke snapshots on the sending turn.
extension TabStore {
    var sidebarSnapshotChanges: AnyPublisher<Void, Never> {
        sidebarChanges(includingProfileVisibility: true)
    }

    fileprivate func sidebarChanges(includingProfileVisibility: Bool) -> AnyPublisher<Void, Never> {
        var changes = [
            sidebarChange($tabs), sidebarChange($pins), sidebarChange($todayShape),
            sidebarChange($splits), sidebarChange($current), sidebarChange($selection),
            sidebarChange($collapsedPinnedSpaces), sidebarChange($currentSpaceID),
            sidebarChange($spaceRevision), sidebarChange($previewSpace)
        ]
        if includingProfileVisibility { changes.append(sidebarChange($profileVisible)) }
        changes.append(sidebarPreviewInvalidated.eraseToAnyPublisher())
        return Publishers.MergeMany(changes).eraseToAnyPublisher()
    }
}

private func sidebarChange<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
    publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
}

/// Row ink does not change when its owning profile is parked or exposed. Native
/// owner revocation and forms keep their separate, synchronous visibility stream.
@MainActor final class SidebarRowObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
}

/// Sidebar rows draw a small part of the window's state. Keeping this boundary
/// separate prevents search and page-chrome publications from rebuilding every row.
@MainActor final class SidebarObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let rows = SidebarRowObservation()
    private var subscription: AnyCancellable?
    private var mutationDepth = 0
    private var pendingChange = false
    private var pendingRowChange = false

    /// This object is a rendering bridge, not the store's model publisher. A close
    /// changes several model properties; invalidate its hosting roots once with the
    /// completed state, before returning to the caller. Sending at the first write
    /// lets another hosting root flush and retain an intermediate outline instead.
    /// Both rendering scopes share this boundary. Model, snapshot, and protection
    /// publishers still send immediately, including profile visibility changes.
    func withCompletedChanges<T>(_ body: () throws -> T) rethrows -> T {
        mutationDepth += 1
        defer {
            mutationDepth -= 1
            if mutationDepth == 0, pendingChange {
                let updatesRows = pendingRowChange
                pendingChange = false
                pendingRowChange = false
                publish(updatesRows: updatesRows)
            }
        }
        return try body()
    }

    private func publish(updatesRows: Bool) {
        if updatesRows { rows.objectWillChange.send() }
        objectWillChange.send()
    }

    private func changed(updatesRows: Bool) {
        if mutationDepth > 0 {
            pendingChange = true
            pendingRowChange = pendingRowChange || updatesRows
        } else {
            publish(updatesRows: updatesRows)
        }
    }

    init(store: TabStore) {
        let content = Publishers.MergeMany([
            store.sidebarChanges(includingProfileVisibility: false),
            // Live controls redraw for these changes; captured previews do not.
            sidebarChange(store.$renamingTab), sidebarChange(store.$renamingFolder),
            sidebarChange(store.$renamingSpace), sidebarChange(store.$announcing),
            sidebarChange(store.$creatingSpace)
        ]).map { true }
        subscription = content.merge(with: sidebarChange(store.$profileVisible).map { false })
            .sink { [weak self] in self?.changed(updatesRows: $0) }
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

/// For row/section views whose drawn values do not depend on profile visibility.
/// Forms, popovers and ownership/readiness shells retain SidebarObserved.
@MainActor @propertyWrapper struct SidebarRowObserved: DynamicProperty {
    private let target: TabStore
    @ObservedObject private var observation: SidebarRowObservation

    init(wrappedValue: TabStore) {
        target = wrappedValue
        _observation = ObservedObject(wrappedValue: wrappedValue.sidebarObservation.rows)
    }

    var wrappedValue: TabStore { target }
}
