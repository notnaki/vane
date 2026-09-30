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
}
