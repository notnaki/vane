import Foundation

/// Default-off probe: use the existing visible-row lazy stack for small outlines.
/// Visible row IDs and protected-content filtering remain unchanged; collapsed
/// children may unmount, committing any active inline editor through onDisappear.
@MainActor enum RetainedRowVirtualizationExperiment {
    static var enabled = ProcessInfo.processInfo.environment["VANE_EXPERIMENT_RETAINED_LAZY"] == "1"
}
