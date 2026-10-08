import Foundation

/// Only the signed installer service may publish an update without sandbox quarantine.
/// This protocol is also compiled into the service; no shell commands cross XPC.
@objc protocol VaneUpdateInstalling {
    func install(source: URL, target: URL, tag: String, keepPrevious: Bool,
                 withReply reply: @escaping (NSError?) -> Void)
    func scheduleRelaunch(target: URL, isolatedDirectory: String, parentPID: Int32,
                         withReply reply: @escaping (NSError?) -> Void)
}

enum UpdateInstaller {
    static let serviceName = "io.github.notnaki.vane.UpdateInstaller"
    static let teamID = "T7X84HN3W3"
    static func requirement(identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and identifier \"\(identifier)\""
    }

    /// Called off the main actor. NSXPC's synchronous proxy delivers either its reply or
    /// its error before returning, and the connection stays alive throughout the copy.
    static func install(source: URL, target: URL, tag: String, keepPrevious: Bool) throws {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: VaneUpdateInstalling.self)
        connection.setCodeSigningRequirement(requirement(identifier: serviceName))
        connection.resume()
        defer { connection.invalidate() }
        var failure: Error?
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { failure = $0 }
        guard let installer = proxy as? VaneUpdateInstalling else {
            throw NSError(domain: serviceName, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Update installer unavailable"])
        }
        installer.install(source: source, target: target, tag: tag, keepPrevious: keepPrevious) { error in
            failure = error
        }
        if let failure { throw failure }
    }

    /// The unsandboxed installer starts a detached worker before this browser exits.
    /// Direct children inherit our sandbox; LaunchServices drops its environment.
    static func scheduleRelaunch(target: URL, isolatedDirectory: String) throws {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: VaneUpdateInstalling.self)
        connection.setCodeSigningRequirement(requirement(identifier: serviceName))
        connection.resume()
        defer { connection.invalidate() }
        var failure: Error?
        guard let installer = connection.synchronousRemoteObjectProxyWithErrorHandler({ failure = $0 }) as? VaneUpdateInstalling else {
            throw NSError(domain: serviceName, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Update installer unavailable"])
        }
        installer.scheduleRelaunch(target: target, isolatedDirectory: isolatedDirectory, parentPID: getpid()) { failure = $0 }
        if let failure { throw failure }
    }
}
