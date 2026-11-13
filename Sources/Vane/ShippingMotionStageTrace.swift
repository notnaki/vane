import AppKit
import QuartzCore

/// Temporary diagnostic only. Value records are printed after the original test body.
@MainActor enum ShippingMotionStageTrace {
    #if DEBUG
    private static let enabled = ProcessInfo.processInfo.environment["VANE_SHIPPING_STAGE_TRACE"] == "1"
    private struct Entry {
        let stage: String
        let time: CFTimeInterval
        let a: Double
        let b: Double
        let c: Double
    }
    private static var label: String?
    private static var entries: [Entry] = []
    #endif

    static func begin(_ name: String) {
        #if DEBUG
        guard enabled else { return }
        entries.removeAll(keepingCapacity: true)
        entries.reserveCapacity(512)
        label = name
        mark("begin")
        #endif
    }

    static func mark(_ stage: String, _ a: Double = .nan,
                     _ b: Double = .nan, _ c: Double = .nan) {
        #if DEBUG
        guard enabled, label != nil, entries.count < 512 else { return }
        entries.append(Entry(stage: stage, time: CACurrentMediaTime(), a: a, b: b, c: c))
        #endif
    }

    /// Record the result of an existing read without requesting another presentation sample.
    static func observed(_ stage: String, _ value: CGFloat) -> CGFloat {
        mark(stage, value)
        return value
    }

    static func dump() {
        #if DEBUG
        guard enabled, let name = label, let first = entries.first else { return }
        label = nil
        for entry in entries {
            print("SHIPPING_STAGE label=\(name) stage=\(entry.stage) ms=\((entry.time - first.time) * 1000) a=\(entry.a) b=\(entry.b) c=\(entry.c)")
        }
        entries.removeAll(keepingCapacity: true)
        #endif
    }
}
