import AppKit

/// Opt-in scalar observations only. The real setter and lifecycle checks remain
/// authoritative; collecting a trace never repairs or accepts a policy change.
@MainActor enum NativeFixturePolicyDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["VANE_NATIVE_POLICY_TRACE"] == "1"
    private static let began = ContinuousClock.now
    private static var events: [String] = []
    private static var sequence = 0
    private static var dropped = 0

    static func mark(_ stage: String, loop: UUID? = nil, expected: Int? = nil) {
        guard enabled else { return }
        sequence += 1
        let app = NSApplication.shared
        let value = "sequence=\(sequence), elapsed=\(began.duration(to: .now)), stage=\(stage), " +
            "loop=\(loop?.uuidString ?? "none"), expected=\(expected.map(String.init) ?? "none"), " +
            "applicationPolicy=\(app.activationPolicy().rawValue), " +
            "runningPolicy=\(NSRunningApplication.current.activationPolicy.rawValue), running=\(app.isRunning)"
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
        mark("policy-invariant-failed \(site) invariantObserved=\(observed.map(String.init) ?? "unavailable")", loop: loop, expected: expected)
        dump("policy-failure")
    }

    static func dump(_ label: String) {
        guard enabled else { return }
        mark("dump \(label)")
        print("NATIVE_POLICY_TRACE begin label=\(label) dropped=\(dropped) count=\(events.count)")
        for event in events { print("NATIVE_POLICY_TRACE \(event)") }
        print("NATIVE_POLICY_TRACE end")
        fflush(stdout)
    }
}
