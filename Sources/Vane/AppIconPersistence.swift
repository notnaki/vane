import Foundation
import Security

/// A separate, unsandboxed service stamps only the app that contains it. No caller path
/// crosses XPC, and each peer must satisfy the other embedded binary's signature.
@objc protocol VaneIconPersisting {
    func setIcon(_ image: Data?, withReply reply: @escaping (Bool) -> Void)
}

enum AppIconPersistence {
    static let serviceName = "io.github.notnaki.vane.IconService"

    static func hostBundle(for service: URL) -> URL? {
        let host = service.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard service.lastPathComponent == serviceName + ".xpc",
              service.deletingLastPathComponent().lastPathComponent == "XPCServices",
              service.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              host.pathExtension == "app", !host.path.contains("/AppTranslocation/") else { return nil }
        return host
    }

    /// Designated requirements pin Developer ID builds to their signer and ad-hoc builds
    /// to their code hash, so local builds can exercise the same XPC path as releases.
    static func signingRequirement(for bundle: URL) -> String? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var string: CFString?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &string) == errSecSuccess else { return nil }
        return string as String?
    }

    /// Synchronous like NSWorkspace.setIcon: the stamp completes before the user can quit.
    static func setIcon(_ image: Data?) -> Bool {
        let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(serviceName).xpc")
        guard let requirement = signingRequirement(for: service) else { return false }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: VaneIconPersisting.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        let result = Reply()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in result.finish(false) }
        guard let service = proxy as? VaneIconPersisting else { return false }
        service.setIcon(image) { result.finish($0) }
        // A failed helper must not leave Settings or startup waiting indefinitely.
        guard result.ready.wait(timeout: .now() + 3) == .success else { return false }
        return result.value
    }

    private final class Reply: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func finish(_ value: Bool) {
            lock.withLock { stored = value }
            ready.signal()
        }
    }
}
