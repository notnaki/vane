import Foundation
import CoreGraphics

/// Capture the resident-range policy once when constructing each native owner.
/// An explicit diagnostic opt-out retains the previous range policy.
enum NativeSidebarResidentWindowExperiment {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["VANE_EXPERIMENT_THREE_RESIDENT_BATCHES"] != "0"
    }
}

/// Canonical eight-row groups, with a small resident guard band. This changes
/// attachment selection only: cache identity and logical document extent stay owned
/// by the caller. Tall viewports override the budget instead of exposing blank rows.
struct NativeSidebarResidentWindow {
    let usesThreeBatchBudget: Bool
    var requestedMaxGraphBudget: Int { usesThreeBatchBudget ? 3 : 0 }
    private(set) var visibleCoverageExceedsBudget = false
    private(set) var range = 0..<16
    private var legacy = SidebarRowWindow()
    private var previousMinY: CGFloat?
    private var lastDirection = 0
    private static let batch = 8
    private static let guardRows = 2

    init(enabled: Bool = NativeSidebarResidentWindowExperiment.enabled) {
        usesThreeBatchBudget = enabled
    }

    mutating func update(count: Int, visible: CGRect, pitch: CGFloat) -> Bool {
        guard usesThreeBatchBudget else {
            let changed = legacy.update(count: count, visible: visible, pitch: pitch)
            range = legacy.range
            return changed
        }
        guard pitch > 0, pitch.isFinite, visible.minY.isFinite,
              visible.maxY.isFinite else { return false }
        let count = max(0, count)
        // Clamp before conversion so far-outside native geometry cannot overflow Int.
        let first = Int(min(CGFloat(count), max(0, floor(visible.minY / pitch))))
        let end = Int(min(CGFloat(count), max(0, ceil(visible.maxY / pitch))))
        if let previousMinY {
            if visible.minY > previousMinY { lastDirection = 1 }
            else if visible.minY < previousMinY { lastDirection = -1 }
        }
        // Layout may repeat the same bounds after attachment. Preserve the last
        // actual travel direction so a stationary callback cannot recenter hosts.
        let direction = lastDirection
        previousMinY = visible.minY
        guard visible.height > 0, end > first else {
            visibleCoverageExceedsBudget = false
            let changed = !range.isEmpty
            range = 0..<0
            return changed
        }

        let firstBatch = first / Self.batch
        let endBatch = (end - 1) / Self.batch + 1
        let totalBatches = count / Self.batch + (count % Self.batch == 0 ? 0 : 1)
        let visibleBatches = endBatch - firstBatch
        visibleCoverageExceedsBudget = visibleBatches > requestedMaxGraphBudget
        let budget = min(totalBatches, max(requestedMaxGraphBudget, visibleBatches))
        let residentBatches = range.isEmpty ? 0 : (range.upperBound - 1) / Self.batch - range.lowerBound / Self.batch + 1
        if !range.isEmpty, range.upperBound <= count, residentBatches <= budget,
           range.upperBound == count || range.upperBound % Self.batch == 0,
           range.lowerBound <= max(0, first - Self.guardRows),
           range.upperBound >= min(count, end + Self.guardRows) {
            return false
        }

        let spare = budget - visibleBatches
        // On a new window, center the spare capacity; after travel, put it ahead.
        let preceding = direction < 0 ? spare : (direction > 0 ? 0 : (spare + 1) / 2)
        let lowerBatch = min(max(0, firstBatch - preceding), totalBatches - budget)
        let upperBatch = lowerBatch + budget
        let upper = upperBatch == totalBatches ? count : upperBatch * Self.batch
        let next = (lowerBatch * Self.batch)..<upper
        guard next != range else { return false }
        range = next
        return true
    }
}
