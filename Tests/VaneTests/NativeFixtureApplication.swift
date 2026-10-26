import AppKit

/// Test-host launch admission, independent of foreground window presentation.
@MainActor enum NativeFixtureApplication {
    private static var requestedLaunch = false

    private struct AdmissionFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static var launchOpenRequestAbsentOrEmpty: Bool {
        let openValue = UserDefaults.standard.object(forKey: "NSOpen")
        return openValue == nil || (openValue as? String)?.isEmpty == true ||
            (openValue as? [Any])?.isEmpty == true
    }

    private static func failureMetadata() -> String {
        let app = NSApplication.shared
        let running = NSRunningApplication.current
        return "launchRequested=\(requestedLaunch), finishedLaunching=\(running.isFinishedLaunching), " +
            "appDelegateNil=\(app.delegate == nil), NSOpenAbsentOrEmpty=\(launchOpenRequestAbsentOrEmpty), " +
            "prohibitedPolicy=\(app.activationPolicy() == .prohibited), appActive=\(app.isActive), " +
            "runningActive=\(running.isActive), appRunning=\(app.isRunning)"
    }

    static func requestLaunchIfNeeded() throws {
        let app = NSApplication.shared
        if !NSRunningApplication.current.isFinishedLaunching, !requestedLaunch {
            guard app.delegate == nil, launchOpenRequestAbsentOrEmpty else {
                throw AdmissionFailure(description: "Native fixture launch request unsafe; " + failureMetadata())
            }
            // SwiftPM drives XCTest's loop rather than NSApplication.run(), which
            // normally completes this launch phase before a window receives input.
            // Mark the request before posting launch notifications; Launch Services
            // can publish isFinishedLaunching on a later turn of the run loop.
            requestedLaunch = true
            app.finishLaunching()
        }
    }

    static func dispatchQueuedAppKitEvents() {
        let app = NSApplication.shared
        // NSApplication.run normally fetches and dispatches activation events.
        // XCTest drives its own loop; process existing AppKit state events only
        // while establishing a fixture, without consuming user input.
        for _ in 0..<32 {
            guard let event = app.nextEvent(matching: .appKitDefined, until: Date.distantPast,
                                            inMode: .default, dequeue: true) else { break }
            app.sendEvent(event)
        }
    }

    static func admitCompletedLaunch() async throws {
        try requestLaunchIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            dispatchQueuedAppKitEvents()
            if NSRunningApplication.current.isFinishedLaunching { return }
            guard ContinuousClock.now < deadline else {
                throw AdmissionFailure(description: "Native fixture launch admission timed out; " + failureMetadata())
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
