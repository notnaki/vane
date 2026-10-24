import Foundation

/// Default-off probe of passive native pointer feedback for command results.
/// A row captures this at creation so experiments cannot change its input path mid-scroll.
@MainActor enum PaletteNativeHoverExperiment {
    static var enabled = ProcessInfo.processInfo.environment["VANE_EXPERIMENT_PALETTE_NATIVE_HOVER"] == "1"
}
