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

    enum SamplePhase: String, CaseIterable, Sendable {
        case collectionStarted, symbolProcessingStarted, taskReadFailed, threadReadFailed, samplerCreationFailed
    }

    /// Keep only fixed classifications, never subprocess text, paths or arguments.
    struct SamplePhases: Sendable {
        let ownedPID: Int32
        private(set) var observed: Set<SamplePhase> = []
        private(set) var truncated = false
        private(set) var readError: Int32?
        private var partial: [UInt8] = []
        private var discardingLine = false
        init(ownedPID: Int32) { self.ownedPID = ownedPID }
        var pendingByteCount: Int { partial.count }
        var summary: String {
            let tokens = SamplePhase.allCases.filter { observed.contains($0) }.map(\.rawValue).joined(separator: ",")
            return "samplePhases=[\(tokens)], streamTruncated=\(truncated), streamReadError=\(readError.map(String.init) ?? "none"), missingTokens=inconclusive"
        }

        mutating func ingest(_ bytes: Data) {
            for byte in bytes {
                if byte == 10 {
                    if !discardingLine {
                        if partial.last == 13 { partial.removeLast() }
                        classifyLine()
                    }
                    partial.removeAll(keepingCapacity: true)
                    discardingLine = false
                } else if !discardingLine {
                    guard partial.count < 512 else {
                        partial.removeAll(keepingCapacity: true)
                        discardingLine = true
                        truncated = true
                        continue
                    }
                    partial.append(byte)
                }
            }
        }

        private mutating func classifyLine() {
            // Exact ASCII records prevent accepting a private-line suffix, a
            // different process, a changed invocation, or malformed UTF-8.
            let records: [(SamplePhase, String)] = [
                (.collectionStarted, "Sampling process \(ownedPID) for 1 second with 10 milliseconds of run time between samples"),
                (.symbolProcessingStarted, "Sampling completed, processing symbols..."),
                (.taskReadFailed, "task_read_for_pid(\(ownedPID)) failed"),
                (.threadReadFailed, "task_threads() for \(ownedPID) failed"),
                (.samplerCreationFailed, "Unable to create VMUSampler for \(ownedPID)")
            ]
            for (phase, line) in records where partial.elementsEqual(line.utf8) { observed.insert(phase) }
        }

        /// One bounded nonblocking poll, including when the writer is still open.
        /// Reaching the budget leaves unread bytes for the next poll.
        @discardableResult mutating func drain(descriptor: Int32) -> Int {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0 else { readError = readError ?? errno; return 0 }
            if flags & O_NONBLOCK == 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
                readError = readError ?? errno
                return 0
            }
            var consumed = 0, interruptions = 0
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while consumed < 16_384 {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, min($0.count, 16_384 - consumed))
                }
                if count > 0 {
                    consumed += count
                    ingest(Data(bytes.prefix(count)))
                } else if count == 0 { break }
                else {
                    let code = errno
                    if code == EINTR, interruptions < 8 { interruptions += 1; continue }
                    if code != EAGAIN && code != EWOULDBLOCK { readError = readError ?? code }
                    break
                }
            }
            if consumed == 16_384 { truncated = true }
            return consumed
        }
    }

    nonisolated static func cachedNativeState(owned: Bool, read: (String) -> Bool?) -> String {
        guard owned else { return "nativeCachedState=unavailable (fixture ownership unverified)" }
        let closed = read("_isClosed")
        // The remaining getters dereference the existing process. Never call
        // them if the page is closed or its closed-state getter is unavailable.
        let suspended = closed == false ? read("_isSuspended") : nil
        let responsive = closed == false ? read("_webProcessIsResponsive") : nil
        func value(_ flag: Bool?) -> String { flag.map(String.init) ?? "unavailable" }
        return "nativeClosed=\(value(closed)), nativeSuspended=\(value(suspended)), nativeResponsiveCached=\(value(responsive))"
    }

    private final class ScriptProbeReply {
        var report: String?
        var finished = false
    }

    /// A public callback proves more than WebKit's cached responsiveness flag.
    /// The callback retains only sanitized state and the committed URL, never the view.
    static func scriptResponsiveness(committedURL: URL?, stillOwned: () -> Bool, isClosed: () -> Bool?,
                                     timeout: Duration = .seconds(1),
                                     evaluate: (@escaping @MainActor @Sendable (Any?, Error?) -> Void) -> Void) async -> String {
        guard stillOwned() else { return "jsProbe=ownership-unverified, inconclusive=true" }
        guard isClosed() == false else { return "jsProbe=page-unavailable, inconclusive=true" }
        let deadline = ContinuousClock.now + max(.zero, min(timeout, .seconds(1)))
        let reply = ScriptProbeReply()
        defer { reply.finished = true; reply.report = nil }
        evaluate { value, error in
            guard !reply.finished, reply.report == nil, ContinuousClock.now < deadline else { return }
            guard error == nil else { reply.report = "jsProbe=error, inconclusive=true"; return }
            guard let values = value as? [Any], values.count == 2,
                  let ready = values[0] as? String, ["loading", "interactive", "complete"].contains(ready),
                  let raw = values[1] as? String, !raw.isEmpty, raw.utf8.count <= 16_384,
                  let actual = URL(string: raw), actual.scheme != nil else {
                reply.report = "jsProbe=malformed-reply, inconclusive=true"
                return
            }
            let oldDocument = committedURL.map { String(actual == $0) } ?? "unavailable"
            reply.report = "jsProbe=reply, readyState=\(ready), oldCommittedDocument=\(oldDocument), inconclusive=\(committedURL == nil)"
        }
        while reply.report == nil, ContinuousClock.now < deadline {
            guard stillOwned() else { return "jsProbe=process-changed, inconclusive=true" }
            guard isClosed() == false else { return "jsProbe=page-unavailable, inconclusive=true" }
            do { try await Task.sleep(until: min(deadline, ContinuousClock.now + .milliseconds(20)), clock: .continuous) }
            catch { return "jsProbe=cancelled, inconclusive=true" }
        }
        guard stillOwned() else { return "jsProbe=process-changed, inconclusive=true" }
        guard isClosed() == false else { return "jsProbe=page-unavailable, inconclusive=true" }
        return reply.report ?? "jsProbe=no-response, inconclusive=true"
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
        guard let pid, let captured = identity(pid) else {
            emit(cachedNativeState(owned: false) { _ in nil })
            return ui + "; native process identity unavailable"
        }
        let owned = maySample(captured, observed: identity(pid), ownedPID: contentPID(web))
        let readNative: (String) -> Bool? = { name in
            let selector = NSSelectorFromString(name)
            guard web.responds(to: selector) else { return nil }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(web.method(for: selector), to: Getter.self)(web, selector)
        }
        let cached = cachedNativeState(owned: owned, read: readNative)
        emit("native cached state before sampling: " + cached)
        let metadata = ui + ", contentStart=\(captured.start), contentPath=\(captured.path), contentState=\(captured.state); " + cached
        emit("native identity before sampling: " + metadata)
        let committed = owned && readNative("_isClosed") == false ? web.backForwardList.currentItem?.url : nil
        let probe = await scriptResponsiveness(committedURL: committed,
            stillOwned: { maySample(captured, observed: identity(pid), ownedPID: contentPID(web)) },
            isClosed: { readNative("_isClosed") }) { reply in
                web.evaluateJavaScript("[document.readyState, location.href]", completionHandler: reply)
            }
        emit("native document responsiveness before sampling: " + probe)
        let probedMetadata = metadata + "; " + probe
        guard maySample(captured, observed: identity(pid), ownedPID: contentPID(web)) else {
            return probedMetadata + "; sample unavailable: live fixture process ownership could not be verified"
        }
        return probedMetadata + "; " + (await sample(captured, stillOwned: { contentPID(web) == pid }))
    }

    private static func sample(_ captured: Identity, stillOwned: () -> Bool) async -> String {
        var phases = SamplePhases(ownedPID: captured.pid)
        var phasePipe: Pipe?
        defer {
            if let phasePipe { phases.drain(descriptor: phasePipe.fileHandleForReading.fileDescriptor) }
            emit("sampler stream progress: " + phases.summary)
            try? phasePipe?.fileHandleForReading.close()
            try? phasePipe?.fileHandleForWriting.close()
        }
        guard stillOwned(), maySample(captured, observed: identity(captured.pid), ownedPID: captured.pid) else {
            return "sample unavailable: fixture process changed"
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vane-webkit-sample-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(captured.pid), "1", "10", "-mayDie", "-file", output.path]
        let stream = Pipe()
        phasePipe = stream
        // Phase messages can be emitted on either stream. Their raw bytes never
        // leave the bounded classifier, and no drain waits for EOF.
        sampler.standardOutput = stream.fileHandleForWriting
        sampler.standardError = stream.fileHandleForWriting
        let deadline = ContinuousClock.now + .seconds(6)
        emit("launching owned sampler for contentPID=\(captured.pid), contentStart=\(captured.start)")
        do { try sampler.run() } catch { return "sample unavailable: \(error.localizedDescription)" }
        try? stream.fileHandleForWriting.close()
        let samplerIdentity = identity(sampler.processIdentifier)
        let samplerMetadata = "samplerPID=\(sampler.processIdentifier), samplerStart=\(samplerIdentity?.start ?? 0), samplerPath=\(samplerIdentity?.path ?? "unavailable")"
        emit("owned sampler launched: " + samplerMetadata)
        // Sampling starts only after the fixture's existing deadline has failed.
        // Allow six seconds for collection and symbolication before child cleanup.
        while sampler.isRunning, ContinuousClock.now < deadline {
            phases.drain(descriptor: stream.fileHandleForReading.fileDescriptor)
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
