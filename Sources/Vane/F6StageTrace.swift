import AppKit
import CoreFoundation

/// Passive, branch-only diagnostics; never schedules work or changes a view.
@MainActor enum F6StageTrace {
    static let enabled = ProcessInfo.processInfo.environment["VANE_F6_STAGE_TRACE"] == "1"

    static func identity(_ object: AnyObject?) -> String {
        object.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "nil"
    }

    static func record(_ stage: String, _ details: @autoclosure () -> String) {
        guard enabled else { return }
        print("F6_STAGE \(stage) t=\(ProcessInfo.processInfo.systemUptime) mode=\(String(describing: CFRunLoopCopyCurrentMode(CFRunLoopGetMain()))) \(details())")
    }
}
