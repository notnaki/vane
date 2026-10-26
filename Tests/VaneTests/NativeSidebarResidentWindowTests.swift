import AppKit
import XCTest
@testable import vane

final class NativeSidebarResidentWindowTests: XCTestCase {
    private let pitch: CGFloat = 41
    private func viewport(_ first: CGFloat, _ rows: CGFloat = 10) -> CGRect {
        CGRect(x: 0, y: first * pitch, width: 240, height: rows * pitch)
    }
    private func assertCoverage(_ window: NativeSidebarResidentWindow, count: Int,
                                visible: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let intersecting = (0..<count).filter { index in
            CGFloat(index) * pitch < visible.maxY && CGFloat(index + 1) * pitch > visible.minY
        }
        for index in intersecting {
            XCTAssertTrue(window.range.contains(index), "missing visible row \(index) from \(window.range)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(window.range.lowerBound, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(window.range.upperBound, count, file: file, line: line)
        XCTAssertEqual(window.range.lowerBound % 8, 0, file: file, line: line)
        XCTAssertTrue(window.range.upperBound == count || window.range.upperBound % 8 == 0, "count=\(count) visible=\(visible) range=\(window.range)", file: file, line: line)
        let requiredBatches = Set(intersecting.map { $0 / 8 }).count
        let residentBatches = Set(window.range.map { $0 / 8 }).count
        if !intersecting.isEmpty {
            XCTAssertLessThanOrEqual(residentBatches, max(3, requiredBatches), file: file, line: line)
        } else {
            XCTAssertTrue(window.range.isEmpty, "count=\(count) visible=\(visible) range=\(window.range)", file: file, line: line)
        }
    }

    func testEnabledInteriorViewportUsesThreeCanonicalBatches() {
        var window = NativeSidebarResidentWindow(enabled: true)
        XCTAssertTrue(window.update(count: 100, visible: viewport(32), pitch: pitch))
        XCTAssertEqual(window.range.count, 24, "interior10row viewport needs3 resident8row graphs, not4")
        assertCoverage(window, count: 100, visible: viewport(32))
    }

    func testDisabledPolicyMatchesExistingWindowThroughScrollAndResize() {
        var existing = SidebarRowWindow()
        var window = NativeSidebarResidentWindow(enabled: false)
        XCTAssertEqual(window.range, existing.range)
        for visible in [viewport(0), viewport(1), viewport(32), viewport(32.5), viewport(91),
                        viewport(48), viewport(3), viewport(-4), viewport(22, 40)] {
            XCTAssertEqual(window.update(count: 100, visible: visible, pitch: pitch),
                           existing.update(count: 100, visible: visible, pitch: pitch))
            XCTAssertEqual(window.range, existing.range)
        }
    }

    func testEveryFractionalForwardAndReverseViewportRemainsCovered() {
        var window = NativeSidebarResidentWindow(enabled: true)
        let forward = stride(from: CGFloat(-3), through: 102, by: 0.25).map { $0 }
        for first in forward + Array(forward.reversed()) {
            let visible = viewport(first)
            _ = window.update(count: 100, visible: visible, pitch: pitch)
            assertCoverage(window, count: 100, visible: visible)
        }
    }

    func testUnchangedGuardInteriorDoesNotChurnRange() {
        var window = NativeSidebarResidentWindow(enabled: true)
        _ = window.update(count: 100, visible: viewport(32), pitch: pitch)
        let original = window.range
        for first in [CGFloat(32.1), 32.2, 32.05, 32.3] {
            XCTAssertFalse(window.update(count: 100, visible: viewport(first), pitch: pitch))
            XCTAssertEqual(window.range, original)
        }
    }

    func testSpareBatchFollowsDirectionAfterCoverageExhaustion() {
        var forward = NativeSidebarResidentWindow(enabled: true)
        _ = forward.update(count: 100, visible: viewport(8), pitch: pitch)
        _ = forward.update(count: 100, visible: viewport(32), pitch: pitch)
        var reverse = NativeSidebarResidentWindow(enabled: true)
        _ = reverse.update(count: 100, visible: viewport(72), pitch: pitch)
        _ = reverse.update(count: 100, visible: viewport(32), pitch: pitch)
        assertCoverage(forward, count: 100, visible: viewport(32))
        assertCoverage(reverse, count: 100, visible: viewport(32))
        XCTAssertGreaterThan(forward.range.lowerBound, reverse.range.lowerBound)
    }

    func testFastJumpsResizeTailAndModelShrinkNeverTradeCoverageForBudget() {
        var window = NativeSidebarResidentWindow(enabled: true)
        for (count, visible) in [(100, viewport(0)), (100, viewport(81.75)),
                                 (100, viewport(3, 45)), (100, viewport(80, 45)),
                                 (99, viewport(91)), (17, viewport(12)),
                                 (100, viewport(-5)), (0, viewport(0))] {
            _ = window.update(count: count, visible: visible, pitch: pitch)
            assertCoverage(window, count: count, visible: visible)
        }
    }

    func testRepeatedGeometryAfterDirectionalPlacementDoesNotRecenter() {
        var window = NativeSidebarResidentWindow(enabled: true)
        _ = window.update(count: 100, visible: viewport(8), pitch: pitch)
        _ = window.update(count: 100, visible: viewport(32), pitch: pitch)
        let forward = window.range
        XCTAssertFalse(window.update(count: 100, visible: viewport(32), pitch: pitch))
        XCTAssertEqual(window.range, forward)
        _ = window.update(count: 100, visible: viewport(72), pitch: pitch)
        _ = window.update(count: 100, visible: viewport(32), pitch: pitch)
        let reverse = window.range
        XCTAssertFalse(window.update(count: 100, visible: viewport(32), pitch: pitch))
        XCTAssertEqual(window.range, reverse)
    }

    func testDuplicateBoundsStayStableAtEveryForwardAndReverseCrossing() {
        var window = NativeSidebarResidentWindow(enabled: true)
        let forward = stride(from: CGFloat(-3), through: 102, by: 0.25).map { $0 }
        for first in forward + Array(forward.reversed()) {
            let visible = viewport(first)
            _ = window.update(count: 100, visible: visible, pitch: pitch)
            let settled = window.range
            for _ in 0..<3 {
                XCTAssertFalse(window.update(count: 100, visible: visible, pitch: pitch), "duplicate geometry first=\(first)")
                XCTAssertEqual(window.range, settled, "duplicate geometry first=\(first)")
                assertCoverage(window, count: 100, visible: visible)
            }
        }
    }

    func testFullyOutsideAndEmptyViewportHaveNoResidentGraphs() {
        var window = NativeSidebarResidentWindow(enabled: true)
        for visible in [viewport(-20, 5), viewport(110), viewport(30, 0)] {
            _ = window.update(count: 100, visible: visible, pitch: pitch)
            XCTAssertTrue(window.range.isEmpty)
        }
    }
    func testHundredAndThousandRowFarJumpsRetainCoverageAndBoundedResidentRange() {
        for count in [100, 1_000] {
            var window = NativeSidebarResidentWindow(enabled: true)
            for first in [CGFloat(0), CGFloat(count) * 0.51 + 0.25,
                          CGFloat(count) - 10.5, 3.25, CGFloat(count) * 0.27, 0] {
                let visible = viewport(first)
                _ = window.update(count: count, visible: visible, pitch: pitch)
                assertCoverage(window, count: count, visible: visible)
                XCTAssertLessThanOrEqual(window.range.count, 24)
                XCTAssertFalse(window.visibleCoverageExceedsBudget)
            }
        }
    }

    func testTallViewportOverridesBudgetAndClearsOverrideWhenViewportShrinksOrEmpties() {
        var window = NativeSidebarResidentWindow(enabled: true)
        let tall = viewport(32.25, 40)
        _ = window.update(count: 1_000, visible: tall, pitch: pitch)
        assertCoverage(window, count: 1_000, visible: tall)
        XCTAssertTrue(window.visibleCoverageExceedsBudget)
        XCTAssertGreaterThan(window.range.count, 24, "Coverage wins over the resident target")
        let short = viewport(32.25, 10)
        _ = window.update(count: 1_000, visible: short, pitch: pitch)
        assertCoverage(window, count: 1_000, visible: short)
        XCTAssertFalse(window.visibleCoverageExceedsBudget)
        XCTAssertLessThanOrEqual(window.range.count, 24)
        _ = window.update(count: 1_000, visible: viewport(32, 0), pitch: pitch)
        XCTAssertTrue(window.range.isEmpty)
        XCTAssertFalse(window.visibleCoverageExceedsBudget)
    }

    func testInvalidGeometryDoesNotReplaceLastValidRangeAndExtremeFiniteOffsetsClampBeforeIntConversion() {
        var window = NativeSidebarResidentWindow(enabled: true)
        _ = window.update(count: 100, visible: viewport(32), pitch: pitch)
        let valid = window.range
        for invalidPitch in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertFalse(window.update(count: 100, visible: viewport(80), pitch: invalidPitch))
            XCTAssertEqual(window.range, valid)
        }
        for y in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertFalse(window.update(count: 100,
                visible: CGRect(x: 0, y: y, width: 240, height: 410), pitch: pitch))
            XCTAssertEqual(window.range, valid)
        }
        for y in [CGFloat.greatestFiniteMagnitude, -CGFloat.greatestFiniteMagnitude] {
            _ = window.update(count: 100,
                visible: CGRect(x: 0, y: y, width: 240, height: 410), pitch: pitch)
            XCTAssertTrue(window.range.isEmpty)
        }
        _ = window.update(count: -100, visible: viewport(0), pitch: pitch)
        XCTAssertEqual(window.range, 0..<0)
    }

}
