import AppKit
import Darwin

/// Opt-in scalar observations only. The real setter and lifecycle checks remain
/// authoritative; collecting a trace never repairs or accepts a policy change.
@MainActor enum NativeFixturePolicyDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["VANE_NATIVE_POLICY_TRACE"] == "1"
    private static let began = ContinuousClock.now
    private static var events: [String] = []
    private static var sequence = 0
    private static var dropped = 0

    static func mark(_ stage: String, loop: UUID? = nil, expected: Int? = nil, observed: Int? = nil) {
        guard enabled else { return }
        sequence += 1
        let value = "sequence=\(sequence), elapsed=\(began.duration(to: .now)), stage=\(stage), " +
            "loop=\(loop?.uuidString ?? "none"), expected=\(expected.map(String.init) ?? "none"), " +
            "boundPolicy=\(observed.map(String.init) ?? "unsampled"), observer=lean-no-system-reads"
        if events.count == 256 { events.removeFirst(); dropped += 1 }
        events.append(value)
    }

    @discardableResult
    static func setActivationPolicy(_ app: NSApplication, _ policy: NSApplication.ActivationPolicy,
                                    file: StaticString = #fileID, line: UInt = #line) -> Bool {
        mark("setter-request \(file):\(line) requested=\(policy.rawValue)")
        let accepted = app.setActivationPolicy(policy)
        mark("setter-return \(file):\(line) requested=\(policy.rawValue) accepted=\(accepted)")
        return accepted
    }

    static func failure(loop: UUID, site: StaticString, expected: Int, observed: Int?) {
        guard enabled else { return }
        mark("policy-invariant-failed \(site) invariantObserved=\(observed.map(String.init) ?? "unavailable")", loop: loop, expected: expected, observed: observed)
        dump("policy-failure")
    }

    static func dump(_ label: String) {
        guard enabled else { return }
        mark("dump \(label)")
        do { try saveSnapshot(label) }
        catch { emit("NATIVE_POLICY_TRACE snapshot-unavailable \(error)") }
        emit("NATIVE_POLICY_TRACE begin label=\(label) dropped=\(dropped) count=\(events.count)")
        for event in events { emit("NATIVE_POLICY_TRACE \(event)") }
        emit("NATIVE_POLICY_TRACE end")
    }

    private enum SnapshotFailure: Error { case invalidOutput, unsafeDirectory, createFailed, oversized }

    private static func saveSnapshot(_ label: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["VANE_NATIVE_POLICY_TRACE_DIRECTORY"], path.hasPrefix("/"),
              let token = environment["VANE_NATIVE_POLICY_TRACE_TOKEN"], !token.isEmpty, token.utf8.count <= 128 else {
            throw SnapshotFailure.invalidOutput
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw SnapshotFailure.unsafeDirectory }
        let snapshot: [String: Any] = ["schema": 1, "observer": "lean-no-system-reads", "label": label,
            "pid": ProcessInfo.processInfo.processIdentifier, "token": token, "dropped": dropped,
            "sequence": sequence, "events": events]
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        guard data.count <= 262144 else { throw SnapshotFailure.oversized }
        let output = directory.appendingPathComponent("native-policy-\(ProcessInfo.processInfo.processIdentifier)-\(UUID()).json")
        let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SnapshotFailure.createFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func emit(_ line: String) {
        // Keep each bounded record in one unbuffered write. SwiftPM can emit a
        // concurrent warning on stderr while buffered stdout is being drained.
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
