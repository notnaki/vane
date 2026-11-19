import Foundation
import XCTest
@testable import vane

/// A Manage Spaces card dropped onto another card must reorder the global strip, the same
/// order the footer dots and the swipe follow.
@MainActor final class SpaceCardDropTests: XCTestCase {
    func testDroppingACardOntoAnotherMovesItInTheGlobalOrder() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared
        let profile = manager.active
        let first = manager.createSpace(name: "CardFirst-\(UUID())", in: profile.id)
        let second = manager.createSpace(name: "CardSecond-\(UUID())", in: profile.id)
        let store = TabStore(space: Spaces.resolve(nil, for: profile), session: [])
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }

        // Drag `first`, drop it onto `second`.
        let data = SpaceCardDragging.start(first)
        XCTAssertTrue(SpaceCardDragging.accept(data, onto: second, in: store), "The drop was refused")

        let order = Spaces.strip(profiles: manager.profiles, spacesOf: { manager.spaces(for: $0.id) },
                                 order: manager.stripOrder).map(\.id)
        let a = try XCTUnwrap(order.firstIndex(of: first.id))
        let b = try XCTUnwrap(order.firstIndex(of: second.id))
        XCTAssertGreaterThan(a, b, "Dropping a card onto another should place it after that card")
    }
}
