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
        // This worker must be spawned by the unsandboxed XPC service. A sandboxed
        // parent cannot directly initialize the child's app sandbox on macOS 27.
        let pendingAtLaunch = BundleReplacement.hasPendingRecord(at: target)
        let witness = BundleReplacement.launchWitness(at: target,
            verifyReplacement: { (try? UpdateInstallation.verifyForRelaunch($0)) != nil },
            verifyPrevious: UpdateInstallation.recoverablePrevious)
        guard !pendingAtLaunch || witness != nil else {
            NSLog("[vane] cannot bind isolated relaunch to its transaction; refused launch")
            exit(1)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["VANE_DATA_DIR": directory, "VANE_UPDATE_SUPERVISED": "1"]
        let reply = Reply()
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, error in
            reply.finish(app, error)
        }
        let deadline = Date().addingTimeInterval(30)
        while reply.read() == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let result = reply.read() else {
            NSLog("[vane] isolated relaunch completion unavailable; retained previous bundle")
            exit(1)
        }
        guard let application = result.0, result.1 == nil else {
            if try !recover(target) {
                var details: [String: Any] = [NSLocalizedDescriptionKey: "Isolated relaunch failed"]
                if let error = result.1 { details[NSUnderlyingErrorKey] = error }
                throw NSError(domain: UpdateInstaller.serviceName, code: 4, userInfo: details)
            }
            return
        }
        while !application.isTerminated, BundleReplacement.hasPendingRecord(at: target) {
            if let witness, BundleReplacement.hasCompletedReplacement(at: target, witness: witness,
                    verifyReplacement: { (try? UpdateInstallation.verifyForRelaunch($0)) != nil }) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if let witness, BundleReplacement.isRestoredPrevious(at: target, witness: witness,
                verifyPrevious: UpdateInstallation.recoverablePrevious) {
            // Bootstrap restored the old inode and durably removed the journal.
            // The exact new child may still own profile locks until it exits.
            while !application.isTerminated {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            try launchRestoredIsolated(target, directory: directory, witness: witness)
            return
        }
        if let witness, !application.isTerminated,
           !BundleReplacement.hasCompletedReplacement(at: target, witness: witness,
                verifyReplacement: { (try? UpdateInstallation.verifyForRelaunch($0)) != nil }) {
            NSLog("[vane] replacement completion did not match its verified transaction; refusing success")
            exit(1)
        }
        if application.isTerminated {
            let restored = BundleReplacement.awaitingBootstrap(at: target) ? try recover(target) : false
            if !restored { exit(1) }
        }
    }

    private static func launchRestoredIsolated(_ target: URL, directory: String,
                                              witness: BundleReplacement.LaunchWitness? = nil) throws {
        if let witness, !BundleReplacement.isRestoredPrevious(at: target, witness: witness,
                verifyPrevious: UpdateInstallation.recoverablePrevious) {
            throw NSError(domain: UpdateInstaller.serviceName, code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Restored previous bundle no longer matches its transaction"])
        }
        guard UpdateInstallation.recoverablePrevious(target),
              !NSWorkspace.shared.runningApplications.contains(where: {
                  !$0.isTerminated && $0.bundleURL?.standardizedFileURL == target.standardizedFileURL
              }) else {
            throw NSError(domain: UpdateInstaller.serviceName, code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Restored previous bundle is unavailable or already running"])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ["VANE_DATA_DIR": directory]
        let reply = Reply()
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, error in
            reply.finish(app, error)
        }
        let deadline = Date().addingTimeInterval(30)
        while reply.read() == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let (application, error) = reply.read(), let application,
              error == nil, !application.isTerminated else {
            throw NSError(domain: UpdateInstaller.serviceName, code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Restored previous app failed to relaunch"])
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
            if let directory = ProcessInfo.processInfo.environment["VANE_DATA_DIR"] {
                try launchRestoredIsolated(target, directory: directory)
                return true
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", UpdateRelaunch.script(parentPID: getpid(), target: target,
                isolatedDirectory: nil)]
            try process.run()
            return true
        case .needsAttention:
            throw NSError(domain: UpdateInstaller.serviceName, code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot safely restore the recorded previous bundle"])
        default: return false
        }
    }
}
