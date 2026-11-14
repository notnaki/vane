import AppKit
import SwiftUI

/// Read-only proof of one actual Library owner's resting state. Consumers must
/// validate again at use; the receipt never authorizes a navigation action.
@MainActor struct LibraryPageMountReceipt {
    let owner: UUID
    let generation: UUID
    private let validate: @MainActor () -> Bool

    fileprivate init(owner: UUID, generation: UUID, validate: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.generation = generation
        self.validate = validate
    }

    func isCurrentAndIdle() -> Bool { validate() }
}

/// Stable, weak provider: an initially cold page can ask again after its actual
/// marker mounts, rather than retaining an initial nil receipt forever.
@MainActor final class LibraryPageMountReceiptSource {
    private weak var paint: LibraryNavigationPaint?
    private weak var store: TabStore?
    private weak var gesture: LibraryGesture?
    private weak var monitor: LibrarySwipeMonitor?

    init(paint: LibraryNavigationPaint) { self.paint = paint }

    func bind(store: TabStore, gesture: LibraryGesture, monitor: LibrarySwipeMonitor) {
        self.store = store
        self.gesture = gesture
        self.monitor = monitor
    }

    // Fail-closed interface scaffold. Eligibility follows only after the owned
    // contract controls demonstrate RED on this exact public interface.
    func capture() -> LibraryPageMountReceipt? { nil }
}

private struct LibraryPageMountReceiptSourceKey: EnvironmentKey {
    static let defaultValue: LibraryPageMountReceiptSource? = nil
}

extension EnvironmentValues {
    var libraryPageMountReceiptSource: LibraryPageMountReceiptSource? {
        get { self[LibraryPageMountReceiptSourceKey.self] }
        set { self[LibraryPageMountReceiptSourceKey.self] = newValue }
    }
}
