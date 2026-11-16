import Combine
import SwiftUI

/// Everything the window publishes except which tab is selected or ticked. Most of the
/// window's chrome draws neither, and switching tabs is the most frequent publication of
/// all: a view that observes this instead of the store sits out every tab switch.
@MainActor final class ChromeObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?

    init(store: TabStore) {
        subscription = store.objectWillChange.sink { [weak self, weak store] in
            guard let self, let store, store.selectionPublications == 0 else { return }
            self.objectWillChange.send()
        }
    }
}

/// Observe the window's chrome state while keeping the original store as the action
/// target. Only for a view that reads nothing derived from `current` or `selection` —
/// `active`, `activeSplit`, `onScreenTabs` and the locked-page state included; hand those
/// to a small view of their own that observes the store itself.
@MainActor @propertyWrapper struct ChromeObserved: DynamicProperty {
    private let target: TabStore
    @ObservedObject private var observation: ChromeObservation

    init(wrappedValue: TabStore) {
        target = wrappedValue
        _observation = ObservedObject(wrappedValue: wrappedValue.chromeObservation)
    }

    var wrappedValue: TabStore { target }
    /// Bindings into the store, as `@EnvironmentObject` and `@ObservedObject` offer them.
    var projectedValue: ObservedObject<TabStore>.Wrapper { ObservedObject(wrappedValue: target).projectedValue }
}
