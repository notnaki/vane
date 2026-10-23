import Foundation
import Darwin
import zlib

/// A deliberately narrow ZIP reader for release archives: STORE and raw DEFLATE only.
/// Central-directory sizes are preflight checks; every emitted byte is independently
/// metered before a write. No archive metadata can create links, ACLs or special files.
enum UpdateArchive {
    struct Limits: Sendable {
        var compressedBytes: Int64 = 200 * 1024 * 1024
        var totalBytes: Int64 = 1024 * 1024 * 1024
        var fileBytes: Int64 = 512 * 1024 * 1024
        var entries = 20_000
        var pathBytes = 1024
        var pathComponents = 32
        var seconds: TimeInterval = 120
    }

    enum Failure: Error { case invalidZIP, limit, unsafePath, unsupportedEntry, filesystem }

    private struct Entry {
        var name: Data
        var components: [String]
        var directory: Bool
        var metadata: Bool
        var permissions: mode_t
        var flags: UInt16
        var version: UInt16
        var method: UInt16
        var crc: UInt32
        var compressed: Int64
        var expanded: Int64
        var local: Int64
        var dataOffset: Int64 = 0
        var end: Int64 = 0
    }

    private final class Reader {
        let descriptor: Int32
        let size: Int64
        init(_ url: URL, maximum: Int64) throws {
            descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.filesystem }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 22, info.st_size <= maximum else {
                close(descriptor)
                throw Failure.invalidZIP
            }
            size = info.st_size
        }
        deinit { close(descriptor) }
        func read(_ offset: Int64, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= size, Int64(count) <= size - offset else {
                throw Failure.invalidZIP
            }
            var bytes = Data(count: count)
            try bytes.withUnsafeMutableBytes { buffer in
                var readBytes = 0
                while readBytes < count {
                    let result = pread(descriptor, buffer.baseAddress!.advanced(by: readBytes),
                                       count - readBytes, off_t(offset + Int64(readBytes)))
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw Failure.invalidZIP }
                    readBytes += result
                }
            }
            return bytes
        }
    }

    static func extract(zip: URL, to destination: URL, limits: Limits = .init()) throws {
        let began = ProcessInfo.processInfo.systemUptime
        func deadline() throws {
            guard limits.seconds.isFinite, limits.seconds > 0,
                  ProcessInfo.processInfo.systemUptime - began < limits.seconds else { throw Failure.limit }
        }
        try deadline()
        guard limits.compressedBytes >= 22, limits.totalBytes >= 0, limits.fileBytes >= 0,
              limits.entries > 0, limits.pathBytes > 0, limits.pathComponents > 0 else { throw Failure.limit }
        let reader = try Reader(zip, maximum: limits.compressedBytes)
        let entries = try directory(reader, limits: limits, deadline: deadline)
        try deadline()
        // Never remove or populate a caller's existing directory on a failure.
        guard mkdir(destination.path, 0o700) == 0 else { throw Failure.filesystem }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: destination) } }
        let root = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.filesystem }
        defer { close(root) }
        var total: Int64 = 0
        for entry in entries {
            try deadline()
            let parent = try parentDescriptor(root: root, components: entry.components.dropLast())
            defer { close(parent) }
            let name = entry.components.last!
            if entry.directory {
                if mkdirat(parent, name, 0o755) != 0 {
                    guard errno == EEXIST else { throw Failure.filesystem }
                    let existing = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard existing >= 0 else { throw Failure.unsafePath }
                    close(existing)
                }
                guard entry.expanded == 0 else { throw Failure.invalidZIP }
            }
            let output = entry.directory || entry.metadata ? -1 : openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard entry.directory || entry.metadata || output >= 0 else { throw Failure.unsafePath }
            defer { if output >= 0 { close(output) } }
            var produced: Int64 = 0
            var checksum = crc32(0, nil, 0)
            var metadataHeader = Data()
            func emit(_ bytes: UnsafeRawBufferPointer) throws {
                try deadline()
                let count = Int64(bytes.count)
                guard count <= limits.fileBytes - produced, count <= limits.totalBytes - total,
                      count <= entry.expanded - produced else { throw Failure.limit }
                if bytes.count > 0 {
                    checksum = crc32(checksum, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
                    if entry.metadata {
                        metadataHeader.append(contentsOf: bytes.prefix(max(0, 26 - metadataHeader.count)))
                    }
                    var written = entry.metadata ? bytes.count : 0
                    while written < bytes.count {
                        let result = write(output, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                        if result < 0 && errno == EINTR { continue }
                        guard result > 0 else { throw Failure.filesystem }
                        written += result
                    }
                }
                produced += count
                total += count
            }
            if entry.method == 0 {
                guard entry.compressed == entry.expanded else { throw Failure.invalidZIP }
                var offset: Int64 = 0
                while offset < entry.compressed {
                    let chunk = try reader.read(entry.dataOffset + offset, Int(min(65_536, entry.compressed - offset)))
                    try chunk.withUnsafeBytes(emit)
                    offset += Int64(chunk.count)
                }
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw Failure.invalidZIP
                }
                defer { inflateEnd(&stream) }
                var offset: Int64 = 0
                var ended = false
                var outputBuffer = [UInt8](repeating: 0, count: 65_536)
                repeat {
                    try deadline()
                    let chunk = try reader.read(entry.dataOffset + offset, Int(min(65_536, entry.compressed - offset)))
                    offset += Int64(chunk.count)
                    try chunk.withUnsafeBytes { input in
                        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                        stream.avail_in = uInt(input.count)
                        repeat {
                            try deadline()
                            let before = stream.avail_in
                            let status = try outputBuffer.withUnsafeMutableBytes { outputBytes in
                                stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                                stream.avail_out = uInt(outputBytes.count)
                                let status = inflate(&stream, Z_NO_FLUSH)
                                let count = outputBytes.count - Int(stream.avail_out)
                                try emit(UnsafeRawBufferPointer(rebasing: outputBytes[..<count]))
                                return status
                            }
                            if status == Z_STREAM_END {
                                guard stream.avail_in == 0, offset == entry.compressed else { throw Failure.invalidZIP }
                                ended = true
                                break
                            }
                            guard status == Z_OK, before != stream.avail_in || stream.avail_out < 65_536 else {
                                throw Failure.invalidZIP
                            }
                        } while stream.avail_in > 0 || stream.avail_out == 0
                    }
                    guard ended || offset < entry.compressed else { throw Failure.invalidZIP }
                } while !ended
            }
            guard produced == entry.expanded, UInt32(truncatingIfNeeded: checksum) == entry.crc else { throw Failure.invalidZIP }
            // Preserve only ordinary executable bits. Archive ownership, ACLs, flags and
            // set-id/sticky permissions are deliberately never applied.
            if entry.metadata {
                // ditto may put AppleDouble beside a sealed resource instead of under
                // __MACOSX. Materializing these sidecars invalidates strict code signing.
                // Validate and discard them after fully metering/CRC-checking their body;
                // never apply untrusted ACLs, extended attributes or resource forks.
                guard metadataHeader.count == 26,
                      metadataHeader.prefix(8).elementsEqual([0, 5, 22, 7, 0, 2, 0, 0]),
                      26 + 12 * (Int(metadataHeader[24]) << 8 | Int(metadataHeader[25])) <= entry.expanded else {
                    throw Failure.invalidZIP
                }
            }
            if !entry.directory && !entry.metadata {
                guard fchmod(output, entry.permissions & 0o111 == 0 ? 0o644 : 0o755) == 0 else { throw Failure.filesystem }
            }
        }
        try deadline()
        success = true
    }

    private static func parentDescriptor(root: Int32, components: ArraySlice<String>) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw Failure.filesystem }
        do {
            for component in components {
                if mkdirat(current, component, 0o755) != 0 && errno != EEXIST { throw Failure.filesystem }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unsafePath }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func directory(_ reader: Reader, limits: Limits, deadline: () throws -> Void) throws -> [Entry] {
        let tailOffset = max(0, reader.size - 65_557)
        let tail = try reader.read(tailOffset, Int(reader.size - tailOffset))
        var end: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(offset) == 0x06054b50, offset + 22 + Int(tail.u16(offset + 20)) == tail.count {
                end = offset
                break
            }
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10), tail.u16(end + 10) != UInt16.max,
              tail.u32(end + 12) != UInt32.max, tail.u32(end + 16) != UInt32.max else { throw Failure.invalidZIP }
        let count = Int(tail.u16(end + 10))
        guard count <= limits.entries else { throw Failure.limit }
        let central = Int64(tail.u32(end + 16))
        let centralSize = Int64(tail.u32(end + 12))
        guard central + centralSize == tailOffset + Int64(end) else { throw Failure.invalidZIP }
        var cursor = central
        var result: [Entry] = []
        var names = Set<String>()
        // Include implicit parents, so differently-spelled ancestors cannot alias on APFS.
        var spellings: [String: String] = [:]
        var kinds: [String: Bool] = [:]
        var declaredTotal: Int64 = 0
        for _ in 0..<count {
            try deadline()
            guard cursor + 46 <= central + centralSize else { throw Failure.invalidZIP }
            let header = try reader.read(cursor, 46)
            guard header.u32(0) == 0x02014b50, header.u16(6) <= 20, header.u16(34) == 0 else { throw Failure.invalidZIP }
            let flags = header.u16(8), method = header.u16(10)
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  method != 0 || flags & 0x0006 == 0 else { throw Failure.unsupportedEntry }
            let compressed = Int64(header.u32(20)), expanded = Int64(header.u32(24))
            guard compressed != Int64(UInt32.max), expanded != Int64(UInt32.max), header.u32(42) != UInt32.max else {
                throw Failure.invalidZIP
            }
            guard expanded <= limits.fileBytes, expanded <= limits.totalBytes - declaredTotal else { throw Failure.limit }
            declaredTotal += expanded
            let nameSize = Int(header.u16(28)), extraSize = Int(header.u16(30)), commentSize = Int(header.u16(32))
            guard nameSize > 0, nameSize <= limits.pathBytes else { throw Failure.limit }
            let next = cursor + 46 + Int64(nameSize + extraSize + commentSize)
            guard next <= central + centralSize else { throw Failure.invalidZIP }
            let name = try reader.read(cursor + 46, nameSize)
            guard !name.contains(0), let text = String(data: name, encoding: .utf8),
                  !text.hasPrefix("/"), !text.contains("\\") else { throw Failure.unsafePath }
            let isDirectory = text.hasSuffix("/")
            let path = isDirectory ? String(text.dropLast()) : text
            let components = path.components(separatedBy: "/")
            guard components.count <= limits.pathComponents,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }) else {
                throw Failure.unsafePath
            }
            let canonical = canonicalName(path)
            guard names.insert(canonical).inserted else { throw Failure.unsafePath }
            var prefix = ""
            for (index, component) in components.enumerated() {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                let key = canonicalName(prefix)
                guard spellings[key] == nil || spellings[key]!.utf8.elementsEqual(prefix.utf8) else { throw Failure.unsafePath }
                // Omitted parent records still create filesystem nodes and consume
                // tracking memory. Charge them against the same entry budget.
                guard spellings[key] != nil || spellings.count < limits.entries else { throw Failure.limit }
                spellings[key] = prefix
                let directory = index < components.count - 1 || isDirectory
                guard kinds[key] == nil || kinds[key] == directory else { throw Failure.unsafePath }
                kinds[key] = directory
            }
            let mode = mode_t(header.u32(38) >> 16)
            let kind = mode & S_IFMT
            guard kind == 0 || kind == (isDirectory ? S_IFDIR : S_IFREG) else { throw Failure.unsupportedEntry }
            if isDirectory, expanded != 0 { throw Failure.invalidZIP }
            try validateExtra(reader.read(cursor + 46 + Int64(nameSize), extraSize))
            result.append(Entry(name: name, components: components, directory: isDirectory,
                                metadata: !isDirectory && components.last!.hasPrefix("._"),
                                permissions: mode, flags: flags, version: header.u16(6), method: method, crc: header.u32(16),
                                compressed: compressed, expanded: expanded, local: Int64(header.u32(42))))
            cursor = next
        }
        guard cursor == central + centralSize else { throw Failure.invalidZIP }
        for index in result.indices {
            try deadline()
            var entry = result[index]
            guard entry.local + 30 <= central else { throw Failure.invalidZIP }
            let header = try reader.read(entry.local, 30)
            guard header.u32(0) == 0x04034b50, header.u16(4) == entry.version,
                  header.u16(6) == entry.flags, header.u16(8) == entry.method,
                  Int(header.u16(26)) == entry.name.count else { throw Failure.invalidZIP }
            let hasDescriptor = entry.flags & 8 != 0
            for (actual, expected) in [(header.u32(14), entry.crc), (header.u32(18), UInt32(entry.compressed)),
                                       (header.u32(22), UInt32(entry.expanded))] {
                guard actual == expected || hasDescriptor && actual == 0 else { throw Failure.invalidZIP }
            }
            let extraSize = Int(header.u16(28))
            entry.dataOffset = entry.local + 30 + Int64(entry.name.count + extraSize)
            guard entry.dataOffset <= central, entry.compressed <= central - entry.dataOffset,
                  try reader.read(entry.local + 30, entry.name.count) == entry.name else { throw Failure.invalidZIP }
            try validateExtra(reader.read(entry.local + 30 + Int64(entry.name.count), extraSize))
            entry.end = entry.dataOffset + entry.compressed
            if hasDescriptor {
                let signature = try reader.read(entry.end, 4).u32(0)
                let descriptor = try reader.read(entry.end + (signature == 0x08074b50 ? 4 : 0), 12)
                guard descriptor.u32(0) == entry.crc, descriptor.u32(4) == UInt32(entry.compressed),
                      descriptor.u32(8) == UInt32(entry.expanded) else { throw Failure.invalidZIP }
                entry.end += signature == 0x08074b50 ? 16 : 12
            }
            guard entry.end <= central else { throw Failure.invalidZIP }
            result[index] = entry
        }
        var previous: Int64 = 0
        for entry in result.sorted(by: { $0.local < $1.local }) {
            guard entry.local == previous else { throw Failure.invalidZIP }
            previous = entry.end
        }
        guard previous == central else { throw Failure.invalidZIP }
        return result
    }

    private static func canonicalName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func validateExtra(_ extra: Data) throws {
        var offset = 0
        while offset < extra.count {
            guard extra.count - offset >= 4 else { throw Failure.invalidZIP }
            let tag = extra.u16(offset), count = Int(extra.u16(offset + 2))
            guard tag != 1, count <= extra.count - offset - 4 else { throw Failure.invalidZIP }
            offset += 4 + count
        }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
