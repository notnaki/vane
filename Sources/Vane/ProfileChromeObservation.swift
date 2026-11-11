import Combine
import SwiftUI

/// Window chrome reads profile metadata and save notices, not the app-wide
/// default profile. A window already owns its selected store during a hop.
@MainActor final class ProfileChromeObservation: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var subscription: AnyCancellable?

    init(manager: ProfileManager) {
        subscription = Publishers.MergeMany([
            manager.$profiles.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            manager.$spacesRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            manager.$saveFailures.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

@MainActor @propertyWrapper struct ProfileChromeObserved: DynamicProperty {
    private let manager: ProfileManager
    @ObservedObject private var observation: ProfileChromeObservation

    init(wrappedValue: ProfileManager) {
        manager = wrappedValue
        _observation = ObservedObject(wrappedValue: wrappedValue.chromeObservation)
    }

    var wrappedValue: ProfileManager { manager }
}
