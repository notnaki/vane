import AppKit
import Security

/// A separate, unsandboxed service stamps only the app that contains it. No caller path
/// crosses XPC, and each peer must satisfy the other embedded binary's signature.
@objc protocol VaneIconPersisting {
    func setIcon(_ image: Data?, withReply reply: @escaping @Sendable (Bool) -> Void)
}

enum AppIconPersistence {
    static let serviceName = "io.github.notnaki.vane.IconService"
    /// Publish the saved image before the caller can quit. The Dock caches its canonical
    /// bundle icon at launch; a Finder stamp alone can leave the first quit on that image.
    @MainActor static func stamp(_ image: NSImage?, at host: URL) -> Bool {
        guard NSWorkspace.shared.setIcon(image, forFile: host.path, options: []) else { return false }
        refreshDockIconCache()
        return true
    }

    /// Tahoe's icon-appearance publisher tells the Dock to rebuild its cached icons.
    /// Re-save the existing configuration without changing any appearance preference.
    /// This private API is optional: persistence still works if a future OS removes it.
    @MainActor static func refreshDockIconCache(
        configurationClass: NSObject.Type? = NSClassFromString("SLSIconAppearanceConfiguration") as? NSObject.Type
    ) {
        let fetch = NSSelectorFromString("fetchCurrentIconAppearanceConfiguration")
        let save = NSSelectorFromString("save")
        guard let configurationClass,
              configurationClass.responds(to: fetch),
              let configuration = configurationClass.perform(fetch)?.takeUnretainedValue() as? NSObject,
              configuration.responds(to: save) else { return }
        configuration.perform(save)
    }

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

    /// XPC setup/signature reads and the helper reply never block the app's actor.
    static func setIcon(_ image: Data?) async -> Bool {
        await Task.detached(priority: .utility) {
            let service = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(serviceName).xpc")
            guard let requirement = signingRequirement(for: service) else { return false }
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: VaneIconPersisting.self)
            connection.setCodeSigningRequirement(requirement)
            connection.resume()
            defer { connection.invalidate() }
            let session = Connection(connection)
            return await request { finish in
                let proxy = session.connection.remoteObjectProxyWithErrorHandler { _ in finish(false) }
                guard let service = proxy as? VaneIconPersisting else { finish(false); return }
                service.setIcon(image, withReply: finish)
            }
        }.value
    }

    /// A helper can fail, disconnect, reply twice, or never reply. Finish exactly once;
    /// timeout releases the continuation and connection without occupying any actor.
    /// Late replies cannot claim success while the timeout callback waits for a worker.
    static func request(timeout: TimeInterval = 3,
                        start: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let deadline = DispatchTime.now() + timeout
            let reply = Reply(continuation, deadline: deadline)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { reply.finish(false) }
            start { reply.finish($0) }
        }
    }

    /// Configuration finishes before publication; subsequent proxy/invalidate calls use
    /// NSXPCConnection's thread-safe message API, never mutable UI state.
    private final class Connection: @unchecked Sendable {
        let connection: NSXPCConnection
        init(_ connection: NSXPCConnection) { self.connection = connection }
    }

    final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let deadline: DispatchTime
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>, deadline: DispatchTime) {
            self.continuation = continuation
            self.deadline = deadline
        }
        func finish(_ value: Bool) {
            let pending = lock.withLock { () -> (CheckedContinuation<Bool, Never>, Bool)? in
                guard let pending = continuation else { return nil }
                continuation = nil
                return (pending, value && DispatchTime.now() < deadline)
            }
            if let (continuation, result) = pending { continuation.resume(returning: result) }
        }
    }
}

/// The app updates its Dock tile immediately, while Finder stamps stay ordered across
/// startup/settings. A durability boundary waits for the final selection and its result.
@MainActor final class AppIconPersistenceQueue {
    private var task: Task<Bool, Never>?
    private var generation: UInt64 = 0
    private var succeeded = true
    private var latestStamp: (@MainActor () async -> Bool)?
    var pending: Bool { task != nil }

    func enqueue(_ stamp: @escaping @MainActor () async -> Bool) {
        latestStamp = stamp
        let previous = task
        generation &+= 1
        let current = generation
        task = Task {
            _ = await previous?.value
            let success = await stamp()
            if current == generation {
                succeeded = success
                task = nil
                if !success { NSLog("[vane] Couldn’t persist the selected Finder icon.") }
            }
            return success
        }
    }

    func flush() async -> Bool {
        // A later quit attempt retries a helper that recovered after a failed stamp.
        if task == nil, !succeeded, let latestStamp { enqueue(latestStamp) }
        while let task { _ = await task.value }
        return succeeded
    }
}
