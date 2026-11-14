import AppKit
import SwiftUI

/// Non-observable metadata only. Exhaustion permanently rejects receipts rather
/// than wrapping to an epoch that an old receipt could still hold.
struct LibraryPageMountEpoch: Equatable {
    private(set) var value: UInt64
    private(set) var exhausted = false
    init(value: UInt64 = 0) { self.value = value }
    mutating func invalidate() {
        guard !exhausted else { return }
        if value == .max { exhausted = true } else { value += 1 }
    }
}

/// Mirrors existing settlement ownership; never drives its completion or action.
struct LibraryPageMountSettlement {
    private(set) var epoch: LibraryPageMountEpoch
    private(set) var pending: UUID?
    init(epoch: LibraryPageMountEpoch = .init()) { self.epoch = epoch }
    mutating func invalidate() { epoch.invalidate() }
    mutating func retire() { epoch.invalidate(); pending = nil }
    mutating func begin(_ token: UUID) { epoch.invalidate(); pending = token }
    mutating func complete(_ token: UUID) {
        guard pending == token else { return }
        epoch.invalidate(); pending = nil
    }
}

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

    func bind(store: TabStore?, gesture: LibraryGesture, monitor: LibrarySwipeMonitor) {
        if self.store !== store || self.gesture !== gesture || self.monitor !== monitor {
            paint?.invalidatePageMountMetadata()
        }
        self.store = store
        self.gesture = gesture
        self.monitor = monitor
    }

    func capture() -> LibraryPageMountReceipt? {
        guard let paint, let store, let gesture, let monitor,
              let marker = paint.pageMountMarker, let window = marker.window,
              eligible(paint: paint, store: store, gesture: gesture, monitor: monitor,
                       marker: marker, window: window) else { return nil }
        let generation = paint.pageMountGeneration
        let paintEpoch = paint.pageMountEpoch
        let monitorEpoch = monitor.pageMountEpoch
        return LibraryPageMountReceipt(owner: paint.owner, generation: generation) {
            [weak self, weak paint, weak store, weak gesture, weak monitor, weak marker, weak window] in
            guard let self, let paint, let store, let gesture, let monitor, let marker, let window,
                  self.paint === paint, self.store === store, self.gesture === gesture, self.monitor === monitor,
                  paint.pageMountGeneration == generation, paint.pageMountEpoch == paintEpoch,
                  monitor.pageMountEpoch == monitorEpoch else { return false }
            return self.eligible(paint: paint, store: store, gesture: gesture, monitor: monitor,
                                 marker: marker, window: window)
        }
    }

    private func eligible(paint: LibraryNavigationPaint, store: TabStore, gesture: LibraryGesture,
                          monitor: LibrarySwipeMonitor, marker: LibraryPaintView, window: NSWindow) -> Bool {
        guard store.libraryGesture === gesture, store.librarySwipeMonitor === monitor,
              gesture.paint === paint, marker.paint === paint, paint.pageMountMarker === marker,
              marker.window === window, store.window === window, store.profileVisible, !store.isParked,
              !store.libraryOpen, gesture.progress == nil, window.isVisible, !window.inLiveResize,
              !marker.isHiddenOrHasHiddenAncestor, !marker.pageMountAttachmentChanging,
              paint.pageMountIsIdle(in: window), monitor.pageMountIsIdle(in: store, window: window),
              let root = window.contentView, marker.isDescendant(of: root),
              (window as? VaneWindow)?.isPreparingPageResize != true else { return false }
        func hasNativeOwner(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if let host = view as? WebHost, !host.offscreen, host.pageResizeOwnershipWillChange != nil { return true }
            return view.subviews.contains(where: hasNativeOwner)
        }
        return !hasNativeOwner(root)
    }
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
