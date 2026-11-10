import Foundation
import Darwin

/// Read-only identity evidence before the standard wrapper retires its manifests.
enum F6DiagnosticHostTrace {
    static func record(_ marker: String) {
        guard ProcessInfo.processInfo.environment["VANE_F6_STAGE_TRACE"] == "1" else { return }
        let identity = NativeFixtureDiagnostics.identity(getpid())
        let fields: [String: Any] = [
            "marker": marker,
            "pid": Int(getpid()),
            "start": identity?.start ?? 0,
            "path": identity?.path ?? "unavailable",
            "retirement_phase": ProcessInfo.processInfo.environment["VANE_NATIVE_FIXTURE_RETIREMENT_PHASE"] ?? "primary"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return }
        print("F6_PROCESS " + text)
    }
}
