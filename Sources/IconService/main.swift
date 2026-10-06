import AppKit

final class IconService: NSObject, NSXPCListenerDelegate, VaneIconPersisting {
    private let host: URL
    private let requirement: String

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

    func setIcon(_ data: Data?, withReply reply: @escaping @Sendable (Bool) -> Void) {
        // XPC invokes exports on a worker queue. Install and publish the Finder icon
        // on the main queue, matching the direct path and its Dock cache publication.
        // Serializing here also prevents concurrent requests from interleaving stamps.
        DispatchQueue.main.async { [host] in
            dispatchPrecondition(condition: .onQueue(.main))
            var image: NSImage?
            if let data {
                guard data.count <= 20 * 1024 * 1024,
                      let decoded = NSImage(data: data), decoded.size.width > 0,
                      decoded.size.height > 0 else { reply(false); return }
                image = decoded
            }
            reply(AppIconPersistence.stamp(image, at: host))
        }
    }
}

guard let service = IconService(service: Bundle.main.bundleURL) else { exit(1) }
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
