import AppKit
import SwiftUI
import XCTest
@testable import vane

final class SidebarDisclosureVisibilityTests: XCTestCase {
    func testSettledBasisDiscardsResidualPresentationFromInterruptedAnimation() {
        let residual = NativeSidebarDisclosureVisibility(rowCount: 59.8, changes: ["child": 0.196])
        let settled = NativeSidebarDisclosureSample(baseline: ["folder"], visibility: residual, isSettled: true)
        XCTAssertEqual(settled.visibility.rowCount, 1,
                       "A cancelled120-second curve cannot continue expanding the settled outer extent")
        XCTAssertTrue(settled.visibility.changes.isEmpty)
        XCTAssertEqual(settled.progress(for: "folder"), 1)
        XCTAssertEqual(settled.progress(for: "child"), 0)
        let active = NativeSidebarDisclosureSample(baseline: ["folder"], visibility: residual, isSettled: false)
        XCTAssertEqual(active.visibility, residual, "Active disclosure must retain its actual sampled pose")
    }

    func testAnimatedStructuralOpeningStartsAtThePreviousPresentedPose() {
        let resting = NativeSidebarDisclosureSample(baseline: ["folder"],
            visibility: .init(rowCount: 1), isSettled: true)
        let opening = NativeSidebarDisclosureSample(baseline: ["folder"],
            visibility: .init(rowCount: 2, changes: ["child": 1]), isSettled: false)
        let first = opening.starting(from: resting, transaction: Transaction(animation: .linear(duration: 1)),
            sameScope: true, membershipUnchanged: false, reducedMotion: false)
        XCTAssertEqual(first.visibility, resting.visibility,
                       "Installing membership must not expose target-position children before the outer extent interpolates")
        XCTAssertFalse(first.isSettled, "The resting pose must carry the new request's unsettled lifecycle")
    }

    func testStructuralReversalAndContentRefreshKeepTheLastInterpolatedVisibility() {
        let presented = NativeSidebarDisclosureSample(baseline: ["folder", "child"],
            visibility: .init(rowCount: 1.6, changes: ["child": -0.4]), isSettled: false)
        let closing = NativeSidebarDisclosureSample(baseline: presented.baseline,
            visibility: .init(rowCount: 1, changes: ["child": -1]), isSettled: false)
        let reversal = closing.starting(from: presented, transaction: Transaction(animation: .linear(duration: 1)),
            sameScope: true, membershipUnchanged: false, reducedMotion: false)
        let refresh = closing.starting(from: presented, transaction: Transaction(),
            sameScope: true, membershipUnchanged: true, reducedMotion: false)
        XCTAssertEqual(reversal.visibility, presented.visibility)
        XCTAssertEqual(refresh.visibility, presented.visibility,
                       "A content refresh during the curve cannot install the target-valued layout probe")
    }

    func testImmediateMembershipChangesAndSettledHandoffsUseTheTargetPose() {
        let presented = NativeSidebarDisclosureSample(baseline: ["folder"],
            visibility: .init(rowCount: 1.4, changes: ["child": 0.4]), isSettled: false)
        let target = NativeSidebarDisclosureSample(baseline: presented.baseline,
            visibility: .init(rowCount: 2, changes: ["child": 1]), isSettled: false)
        let animated = Transaction(animation: .linear(duration: 1))
        var disabled = animated
        disabled.disablesAnimations = true
        for (transaction, sameScope, unchanged, reduced) in [
            (Transaction(), true, false, false), (disabled, true, true, false),
            (animated, true, true, true), (animated, false, true, false)
        ] {
            XCTAssertEqual(target.starting(from: presented, transaction: transaction, sameScope: sameScope,
                membershipUnchanged: unchanged, reducedMotion: reduced), target)
        }
        let rebased = NativeSidebarDisclosureSample(baseline: ["folder", "child"],
            visibility: .init(rowCount: 2), isSettled: true)
        XCTAssertEqual(rebased.starting(from: presented, transaction: animated,
            sameScope: true, membershipUnchanged: true, reducedMotion: false), rebased)
        let otherBasis = NativeSidebarDisclosureSample(baseline: ["other"], visibility: target.visibility, isSettled: false)
        XCTAssertEqual(otherBasis.starting(from: presented, transaction: animated,
            sameScope: true, membershipUnchanged: true, reducedMotion: false), otherBasis)
    }

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
        let frame = layout.frame(visibility: sample)
        XCTAssertEqual(frame.position(for: "b"), 2)
        XCTAssertEqual(frame.position(for: "b1"), 2)
        XCTAssertEqual(frame.position(for: "b2"), 3)
        XCTAssertEqual(frame.position(for: "a2"), 1)
    }

    func testRetainedChildBeforeItsReorderedParentHasASafeMaskedPose() throws {
        let layout = NativeSidebarDisclosureLayout(order: ["child", "other", "folder"],
            baseline: ["child", "other", "folder"], groups: [:], parents: ["child": "folder"])
        let sample = NativeSidebarDisclosureVisibility(rowCount: 2.5, changes: ["child": -0.5])
        let frame = layout.frame(visibility: sample)
        XCTAssertEqual(frame.position(for: "child"), 0)
        XCTAssertGreaterThan(try XCTUnwrap(frame.clipTop(for: "child")), 1,
                             "A retained child preceding its moved parent must stay masked, with no invalid prefix range")
    }

    func testLargeOpeningIndexesContributionsOnceAndCachesResidentQueries() throws {
        let children = (0..<3_000).map { "child-\($0)" }
        let layout = NativeSidebarDisclosureLayout(order: ["folder"] + children, baseline: ["folder"], groups: [:],
            parents: Dictionary(uniqueKeysWithValues: children.map { ($0, "folder") }), travelLimits: ["folder": 20])
        let visibility = NativeSidebarDisclosureVisibility(rowCount: 751,
            changes: Dictionary(uniqueKeysWithValues: children.map { ($0, CGFloat(0.25)) }))
        let frame = layout.frame(visibility: visibility)
        XCTAssertEqual(frame.indexedContributionCount, 3_000)
        for row in children.prefix(24) {
            _ = try XCTUnwrap(frame.position(for: row))
            _ = try XCTUnwrap(frame.clipTop(for: row))
        }
        XCTAssertEqual(try XCTUnwrap(frame.position(for: "child-23")), 9, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(frame.indexProbes, 24 * 4 * 16,
                                 "Resident geometry must use logarithmic prefix lookups, not rescan3,000 changes per row")
        let probes = frame.indexProbes
        for _ in 0..<8 {
            for row in children.prefix(24) { _ = frame.position(for: row); _ = frame.clipTop(for: row) }
        }
        XCTAssertEqual(frame.indexProbes, probes,
                       "All native owners must share this frame's cached origins and ancestor clip edges")
    }

    /// A carrier may stand in for SwiftUI only where the result is the very same pose.
    func testCarrierMoveReproducesTheSampledPoseOrDeclines() throws {
        let pitch: CGFloat = 40, rowHeight: CGFloat = 36
        let children = (0..<12).map { "child-\($0)" }
        let order = ["before", "folder"] + children + ["after-0", "after-1"]
        let layout = NativeSidebarDisclosureLayout(order: order, baseline: ["before", "folder", "after-0", "after-1"],
            groups: [:], parents: Dictionary(uniqueKeysWithValues: children.map { ($0, "folder") }))
        func frame(_ progress: CGFloat) -> NativeSidebarDisclosureLayout.Frame {
            layout.frame(visibility: NativeSidebarDisclosureVisibility(rowCount: 4 + 12 * progress,
                changes: Dictionary(uniqueKeysWithValues: children.map { ($0, progress) })))
        }
        let rest = frame(1)
        let strip = Array(children[2..<10]), header = ["before", "folder"] + Array(children[0..<2])
        let tail = Array(children[10...]) + ["after-0", "after-1"]
        for step in 0...20 {
            let progress = CGFloat(step) / 20
            let sampled = frame(progress)
            for rows in [strip, header, tail, ["before"], ["after-0", "after-1"]] {
                guard let move = sampled.carrierMove(of: rows, from: rest, pitch: pitch, rowHeight: rowHeight) else { continue }
                for row in rows {
                    let y = try XCTUnwrap(sampled.position(for: row)) * pitch
                    let resting = try XCTUnwrap(rest.position(for: row)) * pitch
                    XCTAssertEqual(resting + move.offset, y, accuracy: 0.01, "\(row) at \(progress)")
                    // What SwiftUI would leave visible of the row, against the resting clip
                    // carried along and cut at the carrier's edge.
                    let visible = sampled.clipTop(for: row).map { y + $0 * pitch } ?? y - rowHeight
                    let carried = rest.clipTop(for: row).map { resting + move.offset + $0 * pitch } ?? y - rowHeight
                    XCTAssertEqual(max(carried, move.edge ?? -.infinity), visible, accuracy: 0.01, "\(row) at \(progress)")
                }
            }
            let moved = try XCTUnwrap(sampled.carrierMove(of: strip, from: rest, pitch: pitch, rowHeight: rowHeight),
                                      "A whole strip of siblings travels together at \(progress)")
            XCTAssertEqual(moved.offset, -12 * (1 - progress) * pitch, accuracy: 0.01)
            if progress < 1 { XCTAssertEqual(try XCTUnwrap(moved.edge), 2 * pitch, accuracy: 0.01) }
            XCTAssertNotNil(sampled.carrierMove(of: ["before"], from: rest, pitch: pitch, rowHeight: rowHeight))
            XCTAssertNotNil(sampled.carrierMove(of: ["after-0", "after-1"], from: rest, pitch: pitch, rowHeight: rowHeight))
            if progress < 1 {
                XCTAssertNil(sampled.carrierMove(of: header, from: rest, pitch: pitch, rowHeight: rowHeight),
                             "A header stays while its children travel; one move cannot place both")
            }
        }
        XCTAssertNil(frame(0).carrierMove(of: tail, from: rest, pitch: pitch, rowHeight: rowHeight),
                     "An unclipped follower still overhangs the reveal edge it starts beneath")
        XCTAssertNotNil(frame(0.5).carrierMove(of: tail, from: rest, pitch: pitch, rowHeight: rowHeight))
        XCTAssertNil(frame(1.02).carrierMove(of: strip, from: rest, pitch: pitch, rowHeight: rowHeight),
                     "A spring's overshoot spreads the strip; its rows no longer travel as one")
    }

    @MainActor func testCarrierPresentsItsOwnerMovedAndClippedInTheSection() {
        let section = FlippedSection(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        let window = NSWindow(contentRect: section.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = FlippedSection(frame: section.frame)
        window.contentView = content
        content.addSubview(section)
        defer { window.contentView = nil; window.close() }
        let carrier = NativeSidebarBatchCarrier(frame: .zero)
        let owner = FlippedSection(frame: .zero)
        owner.passesEmptyHits = true
        let row = NSView(frame: NSRect(x: 0, y: 120, width: 200, height: 36))
        owner.addSubview(row)
        section.addSubview(carrier)
        carrier.place(owner, size: NSSize(width: 200, height: 400), offset: -60, edge: 80)
        XCTAssertEqual(row.convert(row.bounds, to: section), NSRect(x: 0, y: 60, width: 200, height: 36))
        XCTAssertEqual(row.convert(row.bounds.intersection(row.visibleRect), to: section), NSRect(x: 0, y: 80, width: 200, height: 16),
                       "The reveal edge clips the travelling row for paint and hits alike")
        XCTAssertTrue(section.hitTest(NSPoint(x: 10, y: 70)) === section)
        XCTAssertTrue(section.hitTest(NSPoint(x: 10, y: 90)) === row)
        XCTAssertTrue(section.hitTest(NSPoint(x: 10, y: 300)) === section, "An owner's empty slots pass hits to other owners")
        let clipped = carrier.frame.size
        carrier.place(owner, size: NSSize(width: 200, height: 400), offset: -20, edge: 80)
        XCTAssertEqual(carrier.frame.size, clipped, "Travelling moves an origin; it must not resize the owner's tree")
        XCTAssertEqual(row.convert(row.bounds, to: section).minY, 100)
        carrier.place(owner, size: NSSize(width: 200, height: 400))
        XCTAssertEqual(carrier.frame, NSRect(x: 0, y: 0, width: 200, height: 400))
        XCTAssertEqual(row.convert(row.bounds.intersection(row.visibleRect), to: section), NSRect(x: 0, y: 120, width: 200, height: 36))
        XCTAssertFalse(carrier.clipsToBounds, "Resting owners keep focus and selection overhang")
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
            let frame = layout.frame(visibility: sample)
            let tail = try XCTUnwrap(frame.position(for: "tail"))
            XCTAssertEqual(tail + 1, sample.rowCount, accuracy: 0.0001,
                           "The last native row and outer extent must share the nested disclosure pose")
            if inner > 0 {
                let first = try XCTUnwrap(frame.position(for: "c1"))
                let last = try XCTUnwrap(frame.position(for: "c2"))
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
    func testExplicitImmediateTransactionSettlesAnAlreadyRegisteredCurve() async {
        let baseline = NativeSidebarDisclosureBaseline()
        baseline.capture(["folder"], scope: nil)
        baseline.capture(["folder", "child"], scope: nil)
        var animated = Transaction(animation: .linear(duration: 120))
        baseline.registerCompletion(in: &animated)
        var immediate = Transaction(animation: nil)
        immediate.disablesAnimations = true
        baseline.registerCompletion(in: &immediate)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(baseline.isSettled,
                      "An explicit immediate endpoint must not wait for the interrupted120-second completion")
        XCTAssertEqual(baseline.rows, ["folder", "child"])
    }

    func testSupersededImmediateSettlementCannotRebaseANewerTarget() async {
        let baseline = NativeSidebarDisclosureBaseline()
        baseline.capture(["folder"], scope: nil)
        baseline.capture(["folder", "child"], scope: nil)
        var immediate = Transaction(animation: nil)
        immediate.disablesAnimations = true
        baseline.registerCompletion(in: &immediate)
        baseline.capture(["folder"], scope: nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(baseline.isSettled)
        XCTAssertEqual(baseline.rows, ["folder"], "The old endpoint cannot replace the active reversal's basis")
    }

    func testSettledTabChurnDoesNotAccumulateAnimatedRows() {
        let baseline = NativeSidebarDisclosureBaseline()
        var visible = Set(["folder", "original"])
        baseline.capture(visible, scope: nil)
        XCTAssertTrue(baseline.isSettled)
        for index in 0..<200 {
            visible = ["folder", "replacement-\(index)"]
            baseline.capture(visible, scope: nil)
            XCTAssertFalse(baseline.isSettled)
            XCTAssertLessThanOrEqual(baseline.visibility.changes.count, 2)
            XCTAssertTrue(baseline.commitSettledVisibility(baseline.visibility, revision: baseline.revision))
            XCTAssertTrue(baseline.visibility.changes.isEmpty)
            XCTAssertTrue(baseline.isSettled)
        }
        visible.insert("opening-child")
        baseline.capture(visible, scope: nil)
        XCTAssertEqual(baseline.visibility.changes, ["opening-child": 1])
    }

    func testReversalToOriginalBasisStillCommitsSettledCleanup() {
        let baseline = NativeSidebarDisclosureBaseline()
        baseline.capture(["folder"], scope: nil)
        baseline.capture(["folder", "child"], scope: nil)
        baseline.capture(["folder"], scope: nil)
        XCTAssertTrue(baseline.visibility.changes.isEmpty)
        XCTAssertFalse(baseline.isSettled,
                       "An empty target delta can still be reversing from a presented opening pose")
        XCTAssertTrue(baseline.commitSettledVisibility(baseline.visibility, revision: baseline.revision),
                      "Returning to the resting basis must still release retained closing visuals")
        XCTAssertTrue(baseline.isSettled,
                      "Only guarded completion authorizes the native bridge to release retained closing rows")
        XCTAssertFalse(baseline.commitSettledVisibility(baseline.visibility, revision: baseline.revision),
                       "A completed target must not repeatedly rebuild resting native roots")
    }

    func testReversalRevokesAnOldRebaseWithoutChangingThePresentedBasis() {
        let baseline = NativeSidebarDisclosureBaseline()
        baseline.capture(["folder", "child"], scope: nil)
        baseline.capture(["folder"], scope: nil)
        let oldRevision = baseline.revision
        let oldDestination = baseline.visibility
        baseline.capture(["folder", "child"], scope: nil)
        XCTAssertFalse(baseline.commitSettledVisibility(oldDestination, revision: oldRevision))
        XCTAssertFalse(baseline.isSettled, "A superseded completion cannot settle the new reversal")
        XCTAssertEqual(baseline.rows, ["folder", "child"])
        XCTAssertTrue(baseline.visibility.changes.isEmpty)
    }
}

private final class FlippedSection: NSView {
    var passesEmptyHits = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return passesEmptyHits && hit === self ? nil : hit
    }
}
