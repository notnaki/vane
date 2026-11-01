import AppKit
import Darwin
import WebKit
@testable import vane

/// Failure-only diagnostics for the WebContent process owned by a fixture's live view.
/// Never enumerate or sample another application's WebKit processes.
@MainActor enum NativeFixtureDiagnostics {
    enum SQLiteHandleKind: String, Sendable { case database, wal, shm }

    struct DescriptorSnapshot: Sendable {
        let count: Int?
        // Bounded IDs support owned-pipe tests; summary output never includes them.
        let identifiers: [Int32]
        let capacity: Int
        let truncated: Bool
        let error: Int32?

        var summary: String {
            "fdCount=\(count.map(String.init) ?? "unavailable"), fdCapacity=\(capacity), fdAtCapacity=\(truncated), fdError=\(error.map(String.init) ?? "none")"
        }
    }

    /// Classify only the app's immediate per-profile database filenames. No paths
    /// or arbitrary descriptor metadata leave the resource snapshot.
    nonisolated static func sqliteHandleKind(path: String, directory: URL) -> SQLiteHandleKind? {
        guard directory.isFileURL, path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return nil }
        var name = file.lastPathComponent
        let kind: SQLiteHandleKind
        if name.hasSuffix("-wal") { kind = .wal; name = String(name.dropLast(4)) }
        else if name.hasSuffix("-shm") { kind = .shm; name = String(name.dropLast(4)) }
        else { kind = .database }
        guard name.hasSuffix(".db") else { return nil }
        let stem = String(name.dropLast(3))
        guard stem == "vane" || (stem.hasPrefix("vane-") && UUID(uuidString: String(stem.dropFirst(5))) != nil) else { return nil }
        return kind
    }

    nonisolated static func currentProcessDescriptors(limit: Int = 4_096) -> DescriptorSnapshot {
        descriptors(pid: getpid(), limit: limit).snapshot
    }

    private nonisolated static func descriptors(pid: Int32, limit: Int = 4_096)
        -> (entries: [proc_fdinfo], snapshot: DescriptorSnapshot) {
        let capacity = min(4_096, max(1, limit))
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let stride = MemoryLayout<proc_fdinfo>.stride
        errno = 0
        let bytes = entries.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        let code = errno
        guard bytes > 0, Int(bytes) <= capacity * stride, Int(bytes) % stride == 0 else {
            return ([], DescriptorSnapshot(count: nil, identifiers: [], capacity: capacity, truncated: false,
                                            error: code == 0 ? EIO : code))
        }
        let count = Int(bytes) / stride
        return (Array(entries.prefix(count)), DescriptorSnapshot(count: count, identifiers: entries.prefix(count).map(\.proc_fd), capacity: capacity,
                                                                 truncated: count == capacity, error: nil))
    }

    private nonisolated static func sqliteSummary(_ entries: [proc_fdinfo], truncated: Bool, directory: URL?) -> String {
        guard let directory, directory.isFileURL, directory.path != "/" else { return "sqliteHandles=unavailable" }
        // Kernel vnode paths resolve aliases such as /var -> /private/var. Resolve
        // only the explicitly isolated root, never unrelated descriptor paths.
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let deadline = ContinuousClock.now + .milliseconds(50)
        var database = 0, wal = 0, shm = 0, examined = 0, unreadable = 0
        for entry in entries.prefix(512) {
            guard ContinuousClock.now < deadline else { break }
            examined += 1
            guard entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(getpid(), entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                unreadable += 1
                continue
            }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            switch sqliteHandleKind(path: path, directory: root) {
            case .database: database += 1
            case .wal: wal += 1
            case .shm: shm += 1
            case nil: break
            }
        }
        return "sqliteDB=\(database), sqliteWAL=\(wal), sqliteSHM=\(shm), sqliteFDsExamined=\(examined), sqliteReadErrors=\(unreadable), sqlitePartial=\(truncated || examined < entries.count || unreadable > 0)"
    }

    /// UI-only when no view is supplied. This performs no AppKit initialization,
    /// process enumeration, descriptor opening, or subprocess launch.
    static func resourceSnapshot(for web: WKWebView? = nil) -> String {
        let ui = descriptors(pid: getpid())
        var limits = rlimit()
        let limitResult = getrlimit(RLIMIT_NOFILE, &limits)
        let limitError = errno
        let limit = limitResult == 0
            ? "fdSoftLimit=\(limits.rlim_cur), fdHardLimit=\(limits.rlim_max)"
            : "fdLimits=unavailable, fdLimitError=\(limitError)"
        let directory = Store.overrideDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let sqlite = ui.snapshot.count == nil ? "sqliteHandles=unavailable"
            : sqliteSummary(ui.entries, truncated: ui.snapshot.truncated, directory: directory)
        let current = "uiResources={\(ui.snapshot.summary), \(limit), \(sqlite)}"
        guard let web else { return current }
        guard let pid = contentPID(web), let captured = identity(pid),
              maySample(captured, observed: identity(pid), ownedPID: contentPID(web)) else {
            return current + "; contentResources=unavailable (fixture ownership unverified)"
        }
        // Only count the getter-owned child's descriptors; never inspect their paths.
        let content = descriptors(pid: pid).snapshot
        guard maySample(captured, observed: identity(pid), ownedPID: contentPID(web)) else {
            return current + "; contentResources=discarded (fixture process changed)"
        }
        return current + "; contentResources={pid=\(pid), start=\(captured.start), \(content.summary), fdLimits=unavailable}"
    }

    /// Write straight to stdout: failure context must survive XCTest error
    /// formatting and must already be visible if a later native diagnostic fails.
    nonisolated static func emit(_ message: String, descriptor: Int32 = STDOUT_FILENO) {
        let record = "Vane fixture diagnostic: " + message + "\n"
        record.utf8CString.withUnsafeBytes { bytes in
            var offset = 0
            let count = bytes.count - 1
            while offset < count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    struct Identity: Equatable, Sendable {
        let pid: Int32
        let start: UInt64
        let path: String
        let state: UInt32

        var isSystemWebContent: Bool {
            path.hasPrefix("/System/") && path.contains("/WebKit.framework/")
                && URL(fileURLWithPath: path).lastPathComponent == "com.apple.WebKit.WebContent"
        }
    }

    nonisolated static func identity(_ pid: Int32) -> Identity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return Identity(pid: pid, start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec),
                        path: String(decoding: bytes, as: UTF8.self), state: info.pbi_status)
    }

    private static func contentPID(_ web: WKWebView) -> Int32? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard web.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
        let pid = unsafeBitCast(web.method(for: selector), to: Getter.self)(web, selector)
        return pid > 0 ? pid : nil
    }

    nonisolated static func maySample(_ captured: Identity, observed: Identity?, ownedPID: Int32?) -> Bool {
        captured.isSystemWebContent && captured.pid != getpid() && captured.pid == ownedPID
            && observed.map { $0.pid == captured.pid && $0.start == captured.start && $0.path == captured.path } == true
    }

    nonisolated static func symbolsOnly(_ output: String) -> String {
        guard let start = output.range(of: "Call graph:")?.upperBound else { return "symbolic call graph unavailable" }
        let graph = output[start...]
        let end = graph.range(of: "Binary Images:")?.lowerBound ?? graph.endIndex
        // Omit process arguments, paths and binary-image metadata; cap UTF-8 bytes.
        var bytes = Array(graph[..<end].utf8.prefix(16_384))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            bytes.removeLast() // At most three bytes of a truncated final scalar.
        }
        return ""
    }

    nonisolated static func readSampleData(_ output: URL) -> Data? {
        let descriptor = open(output.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { return nil }
        return Data(bytes.prefix(count))
    }

    static func failureReport(for web: WKWebView) async -> String {
        let window = web.window
        let windowState = "uiPID=\(getpid()), appActive=\(NSApplication.shared.isActive), " +
            "windowVisible=\(window?.isVisible ?? false), windowOcclusion=\(window?.occlusionState.rawValue ?? 0)"
        emit("native UI before content PID getter: " + windowState)
        let pid = contentPID(web)
        let resources = resourceSnapshot(for: web)
        emit("native resources before sampling: " + resources)
        let ui = windowState + ", contentPID=\(pid.map(String.init) ?? "unavailable"); " + resources
        emit("native snapshot before sampling: " + ui)
        guard let pid, let captured = identity(pid) else { return ui + "; native process identity unavailable" }
        let metadata = ui + ", contentStart=\(captured.start), contentPath=\(captured.path), contentState=\(captured.state)"
        emit("native identity before sampling: " + metadata)
        guard maySample(captured, observed: identity(pid), ownedPID: contentPID(web)) else {
            return metadata + "; sample unavailable: live fixture process ownership could not be verified"
        }
        return metadata + "; " + (await sample(captured, stillOwned: { contentPID(web) == pid }))
    }

    private static func sample(_ captured: Identity, stillOwned: () -> Bool) async -> String {
        guard stillOwned(), maySample(captured, observed: identity(captured.pid), ownedPID: captured.pid) else {
            return "sample unavailable: fixture process changed"
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vane-webkit-sample-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(captured.pid), "1", "10", "-mayDie", "-file", output.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        let deadline = ContinuousClock.now + .seconds(20)
        emit("launching owned sampler for contentPID=\(captured.pid), contentStart=\(captured.start)")
        do { try sampler.run() } catch { return "sample unavailable: \(error.localizedDescription)" }
        let samplerIdentity = identity(sampler.processIdentifier)
        let samplerMetadata = "samplerPID=\(sampler.processIdentifier), samplerStart=\(samplerIdentity?.start ?? 0), samplerPath=\(samplerIdentity?.path ?? "unavailable")"
        emit("owned sampler launched: " + samplerMetadata)
        // Sampling starts only after the fixture's existing deadline has failed.
        // Allow twenty post-failure seconds for collection and symbolication before child cleanup.
        while sampler.isRunning, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        if sampler.isRunning {
            // Terminate only the child sampler, never the WebContent process being observed.
            for signal in [SIGTERM, SIGKILL] {
                guard sampler.isRunning, let expected = samplerIdentity,
                      expected.path == "/usr/bin/sample", let observed = identity(expected.pid),
                      observed.start == expected.start, observed.path == expected.path else { break }
                _ = kill(expected.pid, signal)
                try? await Task.sleep(for: .milliseconds(50))
            }
            let result = samplerMetadata + "; sample unavailable: exceeded diagnostic bound; samplerRunning=\(sampler.isRunning)"
            emit(result)
            return result
        }
        emit("owned sampler exited: " + samplerMetadata + ", status=\(sampler.terminationStatus)")
        guard stillOwned(), maySample(captured, observed: identity(captured.pid), ownedPID: captured.pid) else {
            return samplerMetadata + "; sample discarded: fixture process changed during collection"
        }
        guard sampler.terminationStatus == 0, let data = readSampleData(output) else {
            return samplerMetadata + "; sample unavailable: sampler exit \(sampler.terminationStatus)"
        }
        return samplerMetadata + ", samplerRunning=false; WebContent symbolic stacks:\n" + symbolsOnly(String(decoding: data, as: UTF8.self))
    }
}
