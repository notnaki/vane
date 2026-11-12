import AppKit

// Temporary hosted-only buffered evidence. Remove before final PR push.
@MainActor enum SpaceLandingDiagnostic {
    static var enabled: Bool { ProcessInfo.processInfo.environment["VANE_PROFILE_LIFETIME_TRACE"] == "1" }
    private static var events: [String] = []
    static func record(_ event: @autoclosure () -> String) {
        guard enabled, events.count < 1024 else { return }
        events.append("t=\(CACurrentMediaTime()) \(event())")
    }
    static func drain(_ label: String) {
        guard enabled else { return }
        print("LANDING_TRACE \(label)\n" + events.joined(separator: "\n"))
        events.removeAll(keepingCapacity: true)
    }
}
