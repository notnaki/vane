import SwiftUI

/// Optional per-host diagnostic hook; no counters or recorder are retained in normal hosts.
enum LibrarySurfaceWork: Equatable, Sendable {
    case archiveSearch, downloadsRefresh, mediaRefresh
}
private struct LibrarySurfaceWorkRecorderKey: EnvironmentKey {
    static let defaultValue: (@MainActor (LibrarySurfaceWork) -> Void)? = nil
}
extension EnvironmentValues {
    var librarySurfaceWorkRecorder: (@MainActor (LibrarySurfaceWork) -> Void)? {
        get { self[LibrarySurfaceWorkRecorderKey.self] }
        set { self[LibrarySurfaceWorkRecorderKey.self] = newValue }
    }
}
