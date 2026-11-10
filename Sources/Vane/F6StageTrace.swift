import AppKit
import CoreFoundation

/// Passive, branch-only diagnostics; never schedules work or changes a view.
@MainActor enum F6StageTrace {
    static let enabled = ProcessInfo.processInfo.environment["VANE_F6_STAGE_TRACE"] == "1"

    static func identity(_ object: AnyObject?) -> String {
        object.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "nil"
    }

    // The initial NSWorkspace read is deliberately recorded as an observer effect.
    // Read NSApp as an optional: observing must never create NSApplication.
    static func host(_ stage: String) {
        guard enabled else { return }
        let existedBefore = NSApp != nil
        let workspaceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let modelMotion = Motion.spaceReduced
        let app: NSApplication? = NSApp
        record(stage, "pid=\(ProcessInfo.processInfo.processIdentifier) appBeforeWorkspace=\(existedBefore) appAfterWorkspace=\(app != nil) workspaceMotion=\(workspaceMotion) spaceReduced=\(modelMotion) finished=\(NSRunningApplication.current.isFinishedLaunching) policy=\(String(describing: app?.activationPolicy().rawValue)) running=\(String(describing: app?.isRunning)) active=\(String(describing: app?.isActive)) key=\(identity(app?.keyWindow)) holder=\(identity(app?.keyWindow?.firstResponder)) front=\(String(describing: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))")
    }

    static func record(_ stage: String, _ details: @autoclosure () -> String) {
        guard enabled else { return }
        print("F6_STAGE \(stage) t=\(ProcessInfo.processInfo.systemUptime) mode=\(String(describing: CFRunLoopCopyCurrentMode(CFRunLoopGetMain()))) \(details())")
    }
}
