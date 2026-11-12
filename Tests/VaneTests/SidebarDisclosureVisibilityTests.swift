import SwiftUI
import XCTest
@testable import vane

final class SidebarDisclosureVisibilityTests: XCTestCase {
    func testEqualHeightFolderSwapKeepsIndependentVisibilityComponents() {
        let start = NativeSidebarDisclosureVisibility(rowCount: 3, changes: [:])
        let destination = NativeSidebarDisclosureVisibility(rowCount: 3,
            changes: ["closing-a": -1, "closing-b": -1, "opening-a": 1, "opening-b": 1])
        var travel = destination - start
        travel.scale(by: 0.25)
        let sample = start + travel
        XCTAssertEqual(sample.rowCount, 3)
        XCTAssertEqual(1 + sample.change(for: "closing-a"), 0.75)
        XCTAssertEqual(sample.change(for: "opening-a"), 0.25)
        XCTAssertEqual(sample.change(for: "untouched"), 0)
    }

    func testLaterFolderFollowsAnEarlierStripDuringAnEqualHeightSwap() {
        let basis: Set<String> = ["a", "a1", "a2", "b"]
        let layout = NativeSidebarDisclosureLayout(order: ["a", "a1", "a2", "b", "b1", "b2"],
            baseline: basis, groups: ["a1": "a", "a2": "a", "b1": "b", "b2": "b"])
        let sample = NativeSidebarDisclosureVisibility(rowCount: 4,
            changes: ["a1": -0.5, "a2": -0.5, "b1": 0.5, "b2": 0.5])
        XCTAssertEqual(layout.position(for: "b", visibility: sample), 2)
        XCTAssertEqual(layout.position(for: "b1", visibility: sample), 2)
        XCTAssertEqual(layout.position(for: "b2", visibility: sample), 3)
        XCTAssertEqual(layout.position(for: "a2", visibility: sample), 1)
    }

    func testRetainedChildBeforeItsReorderedParentHasASafeMaskedPose() throws {
        let layout = NativeSidebarDisclosureLayout(order: ["child", "other", "folder"],
            baseline: ["child", "other", "folder"], groups: [:], parents: ["child": "folder"])
        let sample = NativeSidebarDisclosureVisibility(rowCount: 2.5, changes: ["child": -0.5])
        XCTAssertEqual(layout.position(for: "child", visibility: sample), 0)
        XCTAssertGreaterThan(try XCTUnwrap(layout.clipTop(for: "child", visibility: sample)), 1,
                             "A retained child preceding its moved parent must stay masked, with no invalid prefix range")
    }

    func testInnerFolderCanCloseWhileItsAncestorIsOpening() throws {
        let layout = NativeSidebarDisclosureLayout(order: ["outer", "inner", "c1", "c2", "tail"],
            baseline: ["outer"], groups: [:],
            parents: ["inner": "outer", "c1": "inner", "c2": "inner", "tail": "outer"])
        // The ancestor continues opening while the inner children reverse.
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let outer = 0.5 + 0.5 * t
            let inner = 0.5 * (1 - t)
            let sample = NativeSidebarDisclosureVisibility(rowCount: 1 + 2 * outer + 2 * inner,
                changes: ["inner": outer, "tail": outer, "c1": inner, "c2": inner])
            let tail = try XCTUnwrap(layout.position(for: "tail", visibility: sample))
            XCTAssertEqual(tail + 1, sample.rowCount, accuracy: 0.0001,
                           "The last native row and outer extent must share the nested disclosure pose")
            if inner > 0 {
                let first = try XCTUnwrap(layout.position(for: "c1", visibility: sample))
                let last = try XCTUnwrap(layout.position(for: "c2", visibility: sample))
                XCTAssertEqual(last - first, 1, accuracy: 0.0001)
            }
        }
    }

    func testReversalRetargetsThePresentedVisibilityAndExtentTogether() {
        let expanded = NativeSidebarDisclosureVisibility(rowCount: 7, changes: [:])
        let collapsed = NativeSidebarDisclosureVisibility(rowCount: 1,
            changes: Dictionary(uniqueKeysWithValues: (0..<6).map { ("child-\($0)", CGFloat(-1)) }))
        var closing = collapsed - expanded
        closing.scale(by: 0.4)
        let presented = expanded + closing
        var reopening = expanded - presented
        reopening.scale(by: 0.25)
        let reversed = presented + reopening
        let progress = 1 + reversed.change(for: "child-5")
        XCTAssertEqual(progress, 0.7, accuracy: 0.0001)
        XCTAssertEqual(reversed.rowCount, 1 + 6 * progress, accuracy: 0.0001)
        XCTAssertEqual((expanded - expanded).magnitudeSquared, 0)
    }
}

@MainActor final class SidebarDisclosureBaselineTests: XCTestCase {
    func testSettledTabChurnDoesNotAccumulateAnimatedRows() {
        let baseline = NativeSidebarDisclosureBaseline()
        var visible = Set(["folder", "original"])
        baseline.capture(visible, scope: nil)
        for index in 0..<200 {
            visible = ["folder", "replacement-\(index)"]
            baseline.capture(visible, scope: nil)
            XCTAssertLessThanOrEqual(baseline.visibility.changes.count, 2)
            XCTAssertTrue(baseline.commitSettledVisibility(baseline.visibility, revision: baseline.revision))
            XCTAssertTrue(baseline.visibility.changes.isEmpty)
        }
        visible.insert("opening-child")
        baseline.capture(visible, scope: nil)
        XCTAssertEqual(baseline.visibility.changes, ["opening-child": 1])
    }

    func testReversalRevokesAnOldRebaseWithoutChangingThePresentedBasis() {
        let baseline = NativeSidebarDisclosureBaseline()
        baseline.capture(["folder", "child"], scope: nil)
        baseline.capture(["folder"], scope: nil)
        let oldRevision = baseline.revision
        let oldDestination = baseline.visibility
        baseline.capture(["folder", "child"], scope: nil)
        XCTAssertFalse(baseline.commitSettledVisibility(oldDestination, revision: oldRevision))
        XCTAssertEqual(baseline.rows, ["folder", "child"])
        XCTAssertTrue(baseline.visibility.changes.isEmpty)
    }
}
