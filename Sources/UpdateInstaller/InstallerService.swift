import Foundation

final class InstallerService: NSObject, NSXPCListenerDelegate {
    private let applicationsDirectories: [URL]

    init(applicationsDirectories: [URL] = UpdateInstallation.applicationsDirectories) {
        self.applicationsDirectories = applicationsDirectories
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              let start = BundleReplacement.processStart(connection.processIdentifier) else { return false }
        // XPC enforces this requirement on the peer's audit token, avoiding PID races.
        connection.setCodeSigningRequirement(UpdateInstaller.requirement(identifier: "io.github.notnaki.vane"))
        connection.exportedInterface = NSXPCInterface(with: VaneUpdateInstalling.self)
        connection.exportedObject = InstallerSession(applicationsDirectories: applicationsDirectories,
            pid: connection.processIdentifier, start: start)
        connection.resume()
        return true
    }

}

/// Each connection owns an immutable identity; concurrent callers cannot overwrite it.
private final class InstallerSession: NSObject, VaneUpdateInstalling {
    private let applicationsDirectories: [URL]
    private let pid: Int32
    private let start: UInt64

    init(applicationsDirectories: [URL], pid: Int32, start: UInt64) {
        self.applicationsDirectories = applicationsDirectories
        self.pid = pid
        self.start = start
    }

    private func launchOwner(_ target: URL) throws -> BundleReplacement.LaunchOwner {
        guard NSXPCConnection.current()?.processIdentifier == pid,
              UpdateInstallation.allowed(target, within: applicationsDirectories) else {
            throw invalidCaller()
        }
        let owner = BundleReplacement.LaunchOwner.process(pid, start: start,
            executable: target.appendingPathComponent("Contents/MacOS/Vane"))
        guard owner.valid else { throw invalidCaller() }
        return owner
    }

    private func invalidCaller() -> NSError {
        NSError(domain: UpdateInstaller.serviceName, code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid update recovery destination or caller"])
    }

    func beginLaunch(target: URL, withReply reply: @escaping (Int, NSError?) -> Void) {
        do {
            let owner = try launchOwner(target)
            let result = BundleReplacement.beginLaunch(at: target,
                verifyRecovery: { (try? UpdateInstallation.verifyForRelaunch($0)) != nil },
                verifyPrevious: UpdateInstallation.recoverablePrevious, owner: owner,
                retainFailedStage: true)
            reply(result.rawValue, nil)
        } catch { reply(BundleReplacement.Launch.needsAttention.rawValue, error as NSError) }
    }

    func markHealthy(target: URL, withReply reply: @escaping (Bool, NSError?) -> Void) {
        do {
            let owner = try launchOwner(target)
            reply(BundleReplacement.markHealthy(at: target,
                verifyRecovery: { (try? UpdateInstallation.verifyForRelaunch($0)) != nil },
                verifyPrevious: UpdateInstallation.recoverablePrevious, owner: owner), nil)
        } catch { reply(false, error as NSError) }
    }

    func install(source: URL, target: URL, tag: String, keepPrevious: Bool,
                 withReply reply: @escaping (NSError?) -> Void) {
        do {
            try UpdateInstallation.install(source: source, target: target, tag: tag,
                                           keepPrevious: keepPrevious,
                                           applicationsDirectories: applicationsDirectories)
            reply(nil)
        } catch { reply(error as NSError) }
    }

    func scheduleRelaunch(target: URL, isolatedDirectory: String?, parentPID: Int32,
                         withReply reply: @escaping (NSError?) -> Void) {
        do {
            guard NSXPCConnection.current()?.processIdentifier == parentPID,
                  parentPID == pid, BundleReplacement.processStart(pid) == start,
                  target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  UpdateInstallation.allowed(target, within: applicationsDirectories),
                  isolatedDirectory.map({ $0.hasPrefix("/") }) != false else {
                throw NSError(domain: UpdateInstaller.serviceName, code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid update relaunch destination or caller"])
            }
            try UpdateInstallation.verifyForRelaunch(target)
            let helper = target.appendingPathComponent("Contents/XPCServices/\(UpdateInstaller.serviceName).xpc/Contents/MacOS/VaneUpdateInstaller")
            try UpdateInstallation.verifyRelaunchHelper(helper)
            let worker = Process()
            worker.executableURL = helper
            worker.arguments = ["--relaunch-after-exit", target.path, String(parentPID), String(start)]
            var environment = ProcessInfo.processInfo.environment
            environment["VANE_DATA_DIR"] = isolatedDirectory
            environment.removeValue(forKey: "VANE_UPDATE_SUPERVISED")
            worker.environment = environment
            // Application XPC services die with their client. Start the independent,
            // unsandboxed worker now; only it waits for the authenticated caller to exit.
            try worker.run()
            reply(nil)
        } catch { reply(error as NSError) }
    }
}
