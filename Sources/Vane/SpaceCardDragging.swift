import AppKit
import UniformTypeIdentifiers

/// Card reorders have their own payload, so a page-row/text drop cannot reuse
/// stale drag state. Every accepted drop resolves both identities against disk.
@MainActor enum SpaceCardDragging {
    /// Declared in the app's Info.plist by make-app.sh. Without that declaration SwiftUI
    /// hands the card's `onDrop` a provider with no types, and the drop does nothing.
    static let type = UTType(exportedAs: "app.vane.space-card", conformingTo: .data)
    private struct Payload: Codable, Equatable {
        let space: UUID
        let profile: UUID
        let nonce: UUID
    }
    private static var active: Payload?

    static func start(_ space: Space) -> Data {
        let payload = Payload(space: space.id, profile: space.profileID, nonce: UUID())
        active = payload
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }

    static func provider(for space: Space) -> NSItemProvider {
        let data = start(space)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    @discardableResult static func accept(_ data: Data, onto target: Space, in store: TabStore) -> Bool {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), payload == active else { return false }
        active = nil
        guard !store.isPrivate, !store.isLittle, !store.isParked,
              payload.space != target.id else { return false }
        // The global strip, so a card can land beside one from another profile.
        let list = ProfileManager.shared.allSpaces
        guard let from = list.firstIndex(where: { $0.id == payload.space }),
              let to = list.firstIndex(where: { $0.id == target.id }) else { return false }
        Motion.animate(Look.quick) {
            store.reorderSpaces(from: from, to: to > from ? to + 1 : to)
        }
        axAnnounce("Moved \(list[from].name) \(to > from ? "after" : "before") \(target.name).")
        return true
    }
}
