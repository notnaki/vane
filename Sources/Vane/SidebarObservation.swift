import Combine
import SwiftUI

/// Sidebar rows draw a small part of the window's state. Keeping this boundary
/// separate prevents search and page-chrome publications from rebuilding every row.
@MainActor final class SidebarObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?

    init(store: TabStore) {
        func changed<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        subscription = Publishers.MergeMany([
            changed(store.$tabs), changed(store.$pins), changed(store.$todayShape),
            changed(store.$splits), changed(store.$current), changed(store.$selection),
            changed(store.$collapsedPinnedSpaces), changed(store.$currentSpaceID),
            changed(store.$spaceRevision), changed(store.$previewSpace),
            changed(store.$profileVisible), changed(store.$renamingTab),
            changed(store.$renamingFolder), changed(store.$renamingSpace),
            changed(store.$announcing), changed(store.$creatingSpace),
            store.sidebarPreviewInvalidated.eraseToAnyPublisher()
        ]).sink { [weak self] _ in self?.objectWillChange.send() }
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
