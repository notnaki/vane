import Foundation

final class InstallerService: NSObject, NSXPCListenerDelegate, VaneUpdateInstalling {
    private let applicationsDirectories: [URL]

    init(applicationsDirectories: [URL] = UpdateInstallation.applicationsDirectories) {
        self.applicationsDirectories = applicationsDirectories
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        // XPC enforces this requirement on the peer's audit token, avoiding PID races.
        connection.setCodeSigningRequirement(UpdateInstaller.requirement(identifier: "io.github.notnaki.vane"))
        connection.exportedInterface = NSXPCInterface(with: VaneUpdateInstalling.self)
        connection.exportedObject = self
        connection.resume()
        return true
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

    func scheduleRelaunch(target: URL, isolatedDirectory: String, parentPID: Int32,
                         withReply reply: @escaping (NSError?) -> Void) {
        do {
            guard NSXPCConnection.current()?.processIdentifier == parentPID,
                  let parentStart = BundleReplacement.processStart(parentPID),
                  target.standardizedFileURL == target.resolvingSymlinksInPath(),
                  UpdateInstallation.allowed(target, within: applicationsDirectories),
                  isolatedDirectory.hasPrefix("/") else {
                throw NSError(domain: UpdateInstaller.serviceName, code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid update relaunch destination or caller"])
            }
            try UpdateInstallation.verifyForRelaunch(target)
            let helper = target.appendingPathComponent("Contents/XPCServices/\(UpdateInstaller.serviceName).xpc/Contents/MacOS/VaneUpdateInstaller")
            try UpdateInstallation.verifyRelaunchHelper(helper)
            let worker = Process()
            worker.executableURL = helper
            worker.arguments = ["--relaunch-after-exit", target.path, String(parentPID), String(parentStart)]
            var environment = ProcessInfo.processInfo.environment
            environment["VANE_DATA_DIR"] = isolatedDirectory
            worker.environment = environment
            // Application XPC services die with their client. Start the independent,
            // unsandboxed worker now; only it waits for the authenticated caller to exit.
            try worker.run()
            reply(nil)
        } catch { reply(error as NSError) }
    }
}
