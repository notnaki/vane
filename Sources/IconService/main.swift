import AppKit

final class IconService: NSObject, NSXPCListenerDelegate, VaneIconPersisting {
    private let host: URL
    private let requirement: String
    private let lock = NSLock()

    init?(service: URL) {
        guard let host = AppIconPersistence.hostBundle(for: service),
              let requirement = AppIconPersistence.signingRequirement(for: host) else { return nil }
        self.host = host
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VaneIconPersisting.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setIcon(_ data: Data?, withReply reply: @escaping (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var image: NSImage?
        if let data {
            guard data.count <= 20 * 1024 * 1024,
                  let decoded = NSImage(data: data), decoded.size.width > 0,
                  decoded.size.height > 0 else { reply(false); return }
            image = decoded
        }
        reply(NSWorkspace.shared.setIcon(image, forFile: host.path, options: []))
    }
}

guard let service = IconService(service: Bundle.main.bundleURL) else { exit(1) }
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
