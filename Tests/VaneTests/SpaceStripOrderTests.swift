import Foundation
import XCTest
@testable import vane

/// The footer dots and the swipe walk one strip. A global order must be able to put a Space
/// from one profile between Spaces of another, without changing which profile owns it.
final class SpaceStripOrderTests: XCTestCase {
    func testGlobalOrderMovesSpacesAcrossProfilesAndKeepsOwnership() {
        let a = UUID(), b = UUID()
        let a1 = Space(name: "A1", profileID: a), a2 = Space(name: "A2", profileID: a)
        let b1 = Space(name: "B1", profileID: b)
        let owned = [a: [a1, a2], b: [b1]]

        XCTAssertEqual(Spaces.strip(profiles: [a, b]) { owned[$0] ?? [] }.map(\.name),
                       ["A1", "A2", "B1"], "No order saved: profile by profile, as before")

        let ordered = Spaces.strip(profiles: [a, b], spacesOf: { owned[$0] ?? [] },
                                   order: [b1.id, a1.id, a2.id])
        XCTAssertEqual(ordered.map(\.name), ["B1", "A1", "A2"])
        XCTAssertEqual(ordered.first(where: { $0.name == "B1" })?.profileID, b,
                       "Ordering must never change which profile owns a Space")
    }

    func testSpacesMissingFromTheSavedOrderKeepTheirPlace() {
        let a = UUID(), b = UUID()
        let a1 = Space(name: "A1", profileID: a), a2 = Space(name: "A2", profileID: a)
        let b1 = Space(name: "B1", profileID: b)
        let owned = [a: [a1, a2], b: [b1]]

        let partial = Spaces.strip(profiles: [a, b], spacesOf: { owned[$0] ?? [] }, order: [b1.id])
        XCTAssertEqual(partial.map(\.name), ["B1", "A1", "A2"],
                       "A Space made after the last reorder has no entry and must still appear")
    }
}
