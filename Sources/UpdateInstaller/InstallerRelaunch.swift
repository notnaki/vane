import AppKit

/// A mode of the existing signed helper, restricted to the application containing it.
/// No shell caller can authorize launching or recovering a different installation.
enum InstallerRelaunch {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (NSRunningApplication?, Error?)?
        func finish(_ app: NSRunningApplication?, _ error: Error?) {
            lock.lock(); defer { lock.unlock() }
            value = (app, error)
        }
        func read() -> (NSRunningApplication?, Error?)? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    static func relaunch(target: URL) {
        let service = Bundle.main.bundleURL
        let host = service.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard service.lastPathComponent == UpdateInstaller.serviceName + ".xpc",
              service.deletingLastPathComponent().lastPathComponent == "XPCServices",
              host.standardizedFileURL == target.standardizedFileURL,
              target.standardizedFileURL == target.resolvingSymlinksInPath() else {
            NSLog("[vane] relaunch refused a destination outside its host bundle")
            exit(1)
        }
        do {
            try UpdateInstallation.verifyForRelaunch(target)
            if let directory = ProcessInfo.processInfo.environment["VANE_DATA_DIR"] {
                try launchIsolated(target, directory: directory)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            let reply = Reply()
            NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, error in
                reply.finish(app, error)
            }
            let deadline = Date().addingTimeInterval(30)
            while reply.read() == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            guard let (application, error) = reply.read() else {
                // An unavailable completion is uncertainty, never proof that no app exists.
                NSLog("[vane] relaunch completion unavailable; retained previous bundle")
                exit(1)
            }
            if let error { NSLog("[vane] relaunch failed: %@", String(describing: error)) }
            // LaunchServices gives us the actual process object. Keep waiting for a slow
            // live bootstrap; don't mistake an unregistered window or elapsed timer for
            // process death. Once bootstrap claims the journal, normal launch recovery owns it.
            while let application, !application.isTerminated,
                  BundleReplacement.hasPendingRecord(at: target),
                  !BundleReplacement.launchClaimed(at: target, by: application.processIdentifier) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            let restored = BundleReplacement.awaitingBootstrap(at: target) ? try recover(target) : false
            if (error != nil || application == nil || application?.isTerminated == true) && !restored { exit(1) }
        } catch {
            NSLog("[vane] relaunch verification failed: %@", String(describing: error))
            do {
                if try !recover(target) { exit(1) }
            } catch {
                NSLog("[vane] unlaunched update recovery failed: %@", String(describing: error))
                exit(1)
            }
        }
    }

    private static func launchIsolated(_ target: URL, directory: String) throws {
        // NSWorkspace ignores environment when called from an inherited sandbox.
        // Process retains the explicit override and the child's exact process identity.
        let application = Process()
        application.executableURL = Bundle(url: target)?.executableURL
        var environment = ProcessInfo.processInfo.environment
        environment["VANE_DATA_DIR"] = directory
        application.environment = environment
        try application.run()
        while application.isRunning, BundleReplacement.hasPendingRecord(at: target),
              !BundleReplacement.launchClaimed(at: target, by: application.processIdentifier) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !application.isRunning {
            let restored = BundleReplacement.awaitingBootstrap(at: target) ? try recover(target) : false
            if !restored { exit(1) }
        }
    }

    private static func recover(_ target: URL) throws -> Bool {
        // A separately launched copy could have appeared while our application exited.
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL == target.standardizedFileURL
        }) else { return false }
        switch try BundleReplacement.restoreUnlaunched(at: target,
                verifyPrevious: UpdateInstallation.recoverablePrevious) {
        case .rolledBack:
            NSLog("[vane] relaunch failed before bootstrap; restored previous bundle")
            // The running helper is now inside the failed stage. Open the restored app
            // after this helper exits, with its signature identity and isolation preserved.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", UpdateRelaunch.script(parentPID: getpid(), target: target,
                isolatedDirectory: ProcessInfo.processInfo.environment["VANE_DATA_DIR"],
                directExecutable: ProcessInfo.processInfo.environment["VANE_DATA_DIR"] == nil ? nil : Bundle(url: target)?.executableURL)]
            try process.run()
            return true
        case .needsAttention:
            throw NSError(domain: UpdateInstaller.serviceName, code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot safely restore the recorded previous bundle"])
        default: return false
        }
    }
}
