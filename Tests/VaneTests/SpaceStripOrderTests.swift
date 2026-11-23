import Foundation
import XCTest
@testable import vane

/// The footer dots, the swipe and Manage Spaces walk one strip. A global order may put a
/// Space from one profile between Spaces of another without changing which profile owns it,
/// and it only ever decides how profiles interleave: inside a profile, that profile's own
/// list is the order.
final class SpaceStripOrderTests: XCTestCase {
    private let a = UUID(), b = UUID()
    private func space(_ name: String, _ profile: UUID) -> Space { Space(name: name, profileID: profile) }
    private func names(_ owned: [UUID: [Space]], order: [UUID]) -> [String] {
        Spaces.strip(profiles: [a, b], spacesOf: { owned[$0] ?? [] }, order: order).map(\.name)
    }

    func testGlobalOrderMovesSpacesAcrossProfilesAndKeepsOwnership() {
        let a1 = space("A1", a), a2 = space("A2", a), b1 = space("B1", b)
        let owned = [a: [a1, a2], b: [b1]]
        XCTAssertEqual(names(owned, order: []), ["A1", "A2", "B1"], "No order saved: profile by profile, as before")

        let ordered = Spaces.strip(profiles: [a, b], spacesOf: { owned[$0] ?? [] }, order: [a1.id, b1.id, a2.id])
        XCTAssertEqual(ordered.map(\.name), ["A1", "B1", "A2"])
        XCTAssertEqual(ordered.map(\.profileID), [a, b, a], "Ordering must never change which profile owns a Space")
    }

    func testASpaceTheOrderDoesNotNameStaysBesideItsOwnProfile() {
        let a1 = space("A1", a), a2 = space("A2", a), a3 = space("A3", a)
        let b1 = space("B1", b), b2 = space("B2", b)
        // A3 and B2 were made after the last reorder. Neither goes to the end of the strip.
        XCTAssertEqual(names([a: [a1, a2, a3], b: [b1, b2]], order: [b1.id, a1.id, a2.id]),
                       ["B1", "B2", "A1", "A2", "A3"])
        XCTAssertEqual(names([a: [a1, a2, a3], b: [b1]], order: [a1.id, b1.id, a2.id]), ["A1", "B1", "A2", "A3"])
        // A profile the order has never seen comes after the profiles before it.
        XCTAssertEqual(names([a: [a1, a2], b: [b1, b2]], order: [a2.id, a1.id]), ["A1", "A2", "B1", "B2"])
        XCTAssertEqual(names([a: [a1], b: [b1, b2]], order: [b2.id, b1.id]), ["A1", "B1", "B2"])
    }

    func testAProfilesOwnListDecidesTheOrderInsideIt() {
        let a1 = space("A1", a), a2 = space("A2", a), b1 = space("B1", b)
        // An older version (or sync) reordered profile A after the global order was saved.
        XCTAssertEqual(names([a: [a2, a1], b: [b1]], order: [a1.id, b1.id, a2.id]), ["A2", "B1", "A1"])
    }

    func testDamagedOrdersStillListEverySpaceOnce() {
        let a1 = space("A1", a), a2 = space("A2", a), b1 = space("B1", b)
        let owned = [a: [a1, a2], b: [b1]]
        let gone = UUID()
        XCTAssertEqual(names(owned, order: [gone, b1.id, b1.id, a1.id, gone, a1.id, a2.id]), ["B1", "A1", "A2"])
        XCTAssertEqual(names(owned, order: [gone, UUID()]), ["A1", "A2", "B1"], "Only unknown ids: the plain walk")
        XCTAssertEqual(names(owned, order: Array(repeating: a2.id, count: 5_000)).sorted(), ["A1", "A2", "B1"])
        // The same Space in two profiles' files is damage too; both rows still show once each.
        XCTAssertEqual(names([a: [a1], b: [a1, b1]], order: [b1.id, a1.id]).count, 3)
    }
}
