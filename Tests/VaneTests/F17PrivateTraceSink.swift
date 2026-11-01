import AppKit
import Darwin
import NativeTestHostBootstrap

/// Only the two existing F17 diagnostic channels. Call after fixture assertions
/// and the actual AppKit loop join; never from an SDK trampoline/timed action.
@MainActor enum F17PrivateTraceSink {
    private final class BundleMarker: NSObject {}
    private struct Contract: Decodable { let schema: Int; let token: String }
    private struct Header: Encodable {
        let schema = 1
        let kind = "F17_PRIVATE_TRACE"
        let channel: String
        let `case`: String
        let sourceRevision: String
        let sourceRevisionProvenance = "controller-verified-environment"
        let manifestDirectory: String
        let token: String
        let host: NativeFixtureRetirement.Host
        let exportStage = "after-fixture-assertions-and-AppKit-loop-join"
    }
    private struct End: Encodable {
        let schema = 1
        let kind = "F17_PRIVATE_TRACE_END"
        let channel: String
        let `case`: String
    }
    enum Failure: Error { case invalidBinding, activeLoop, invalidPrivateFile, system(String, Int32) }
    private static let limit = 4_194_304
    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static var fileMode: Bool { ProcessInfo.processInfo.environment["VANE_F17_PRIVATE_TRACE_V1"] == "1" }

    static func spell(caseName: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        let status = VaneF17SpellTraceReadStatus()
        guard status.requested else { return nil } // Flag-off: no file/descriptor work.
        guard environment["VANE_F17_CANDIDATE_LATENCY_TRACE_V1"] == "1" else { return nil }
        guard environment["VANE_F17_PRIVATE_TRACE_V1"] == "1" else {
            VaneF17SpellTraceEmit()
            return nil
        }
        guard !status.recording else { throw Failure.activeLoop }
        return try publish(channel: "spell", caseName: caseName, environment: environment) { descriptor in
            guard VaneF17SpellTraceEmitToDescriptor(descriptor) else { throw Failure.system("spell export", errno) }
        }
    }

    static func continuation(caseName: String, records: [String],
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        guard environment["VANE_F17_PRIVATE_TRACE_V1"] == "1",
              environment["VANE_F17_CANDIDATE_LATENCY_TRACE_V1"] == "1" else { return nil }
        let payload = Data((records.joined(separator: "\n") + (records.isEmpty ? "" : "\n")).utf8)
        guard payload.count <= limit else { throw Failure.invalidPrivateFile }
        return try publish(channel: "continuation", caseName: caseName, environment: environment) {
            try write(payload, to: $0)
        }
    }

    private static func readPrivate(_ name: String, at directory: Int32) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.system("open private binding", errno) }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600,
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= 1_048_576 else { throw Failure.invalidPrivateFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw Failure.invalidPrivateFile }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.system("write private trace", errno) }
                offset += count
            }
        }
    }

    private static func jsonLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(10)
        return data
    }

    private static func publish(channel: String, caseName: String, environment: [String: String],
                                body: (Int32) throws -> Void) throws -> URL {
        guard let source = environment["VANE_F17_TRACE_SOURCE_HEAD"],
              isLowercaseHex(source, count: 40),
              let token = environment["VANE_NATIVE_FIXTURE_MANIFEST_TOKEN"],
              isLowercaseHex(token, count: 32),
              let directory = environment["VANE_NATIVE_FIXTURE_MANIFEST_DIR"],
              directory.hasPrefix("/"), NativeFixtureRetirement.canonical(directory) == directory,
              let identity = NativeFixtureDiagnostics.identity(getpid()) else { throw Failure.invalidBinding }
        guard NSApp?.isRunning != true else { throw Failure.activeLoop }
        var before = stat()
        guard lstat(directory, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == geteuid(), before.st_mode & 0o7777 == 0o700 else { throw Failure.invalidPrivateFile }
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.system("open private directory", errno) }
        defer { _ = close(directoryFD) }
        var opened = stat()
        guard fstat(directoryFD, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              opened.st_uid == geteuid(), opened.st_mode & 0o7777 == 0o700 else { throw Failure.invalidPrivateFile }
        let contract = try JSONDecoder().decode(Contract.self, from: readPrivate("contract.json", at: directoryFD))
        guard contract.schema == 1, contract.token == token else { throw Failure.invalidBinding }
        let host = NativeFixtureRetirement.Host(pid: identity.pid, start: identity.start,
            path: NativeFixtureRetirement.canonical(identity.path), processName: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            testBundlePath: NativeFixtureRetirement.canonical(Bundle(for: BundleMarker.self).bundleURL.path))
        let registered = try JSONDecoder().decode(NativeFixtureRetirement.Manifest.self,
            from: readPrivate("host-\(host.pid)-\(host.start).json", at: directoryFD))
        guard registered.schema == 1, registered.token == token, registered.host == host else { throw Failure.invalidBinding }
        let base = "f17trace-\(host.pid)-\(host.start)-\(channel)-\(UUID().uuidString)"
        let temporary = base + ".pending", final = base + ".trace"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.system("create private trace", errno) }
        var fileOpen = true, published = false
        var created = stat()
        var identified = false
        defer {
            if fileOpen { _ = close(descriptor) }
            if !published {
                var remaining = stat()
                let observed = fstatat(directoryFD, temporary, &remaining, AT_SYMLINK_NOFOLLOW)
                if identified, observed == 0,
                   remaining.st_dev == created.st_dev, remaining.st_ino == created.st_ino {
                    if unlinkat(directoryFD, temporary, 0) != 0 {
                        NativeFixtureDiagnostics.emit("Private trace failed-pending cleanup also failed: errno=\(errno)")
                    }
                } else if observed == 0 || errno != ENOENT {
                    // Preserve an ambiguous entry; filename/private-dir membership
                    // is not proof that it still belongs to this writer.
                    NativeFixtureDiagnostics.emit("Private trace failed-pending ownership/cleanup UNVERIFIED")
                }
            }
        }
        // Capture ownership before any later setup failure (including chmod).
        guard fstat(descriptor, &created) == 0 else { throw Failure.invalidPrivateFile }
        identified = true
        var configured = stat()
        guard fchmod(descriptor, 0o600) == 0, fstat(descriptor, &configured) == 0,
              configured.st_dev == created.st_dev, configured.st_ino == created.st_ino,
              configured.st_mode & S_IFMT == S_IFREG, configured.st_uid == geteuid(),
              configured.st_mode & 0o7777 == 0o600, configured.st_nlink == 1,
              created.st_mode & S_IFMT == S_IFREG, created.st_uid == geteuid(),
              created.st_nlink == 1 else { throw Failure.invalidPrivateFile }
        try write(jsonLine(Header(channel: channel, case: caseName, sourceRevision: source,
            manifestDirectory: directory, token: token, host: host)), to: descriptor)
        try body(descriptor)
        try write(jsonLine(End(channel: channel, case: caseName)), to: descriptor)
        var completed = stat()
        guard fstat(descriptor, &completed) == 0, completed.st_size <= limit,
              completed.st_dev == created.st_dev, completed.st_ino == created.st_ino,
              completed.st_nlink == 1, fsync(descriptor) == 0 else { throw Failure.invalidPrivateFile }
        let closeResult = close(descriptor)
        fileOpen = false // Do not retry close on a potentially reused descriptor.
        guard closeResult == 0 else { throw Failure.system("close private trace", errno) }
        var named = stat()
        guard fstatat(directoryFD, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == created.st_dev, named.st_ino == created.st_ino,
              named.st_mode & S_IFMT == S_IFREG, named.st_uid == geteuid(),
              named.st_mode & 0o7777 == 0o600, named.st_nlink == 1,
              named.st_size == completed.st_size else { throw Failure.invalidPrivateFile }
        // Requires exclusive producer/collector sequencing. Public rename is not
        // an inode-CAS against an uncooperative concurrent directory mutator.
        guard renameatx_np(directoryFD, temporary, directoryFD, final, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.system("publish private trace", errno)
        }
        published = true
        var finalInfo = stat()
        guard fstatat(directoryFD, final, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0,
              finalInfo.st_dev == created.st_dev, finalInfo.st_ino == created.st_ino,
              finalInfo.st_mode & S_IFMT == S_IFREG, finalInfo.st_uid == geteuid(),
              finalInfo.st_mode & 0o7777 == 0o600, finalInfo.st_nlink == 1,
              finalInfo.st_size == completed.st_size else { throw Failure.invalidPrivateFile }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(final)
    }
}
