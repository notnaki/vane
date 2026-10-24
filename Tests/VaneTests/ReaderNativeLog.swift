import Foundation
import Darwin
import CoreFoundation

/// CI-only, failure-only system-log classifications. Never retain or print raw log text.
enum ReaderNativeLog {
    struct Query: Sendable {
        let arguments: [String]
        let basename: String
        let ownerPID: Int32
    }

    static func query(image: URL, ownerPID: Int32, startedAt: Date, failedAt: Date,
                      environment: [String: String]) -> Query? {
        let images = image.deletingLastPathComponent()
        let basename = images.deletingLastPathComponent().lastPathComponent
        let prefix = "vane-saved-reader-"
        guard environment["GITHUB_ACTIONS"] == "true", ownerPID > 0, image.isFileURL,
              images.lastPathComponent == "images", basename.hasPrefix(prefix),
              basename.count == prefix.count + 36,
              UUID(uuidString: String(basename.dropFirst(prefix.count))) != nil,
              image.lastPathComponent.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
              startedAt.timeIntervalSince1970.isFinite, failedAt.timeIntervalSince1970.isFinite,
              failedAt >= startedAt else { return nil }
        let start = max(startedAt.addingTimeInterval(-2), failedAt.addingTimeInterval(-30))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let predicate = """
        (composedMessage CONTAINS[c] "\(basename)") OR \
        (processIdentifier == \(ownerPID) AND (category CONTAINS[c] "Sandbox" OR \
        composedMessage CONTAINS[c] "sandbox extension" OR composedMessage CONTAINS[c] "Operation not permitted")) OR \
        ((process == "kernel" OR process == "sandboxd") AND composedMessage CONTAINS "(\(ownerPID))" AND \
        (composedMessage CONTAINS[c] "deny" OR composedMessage CONTAINS[c] "sandbox"))
        """
        return Query(arguments: ["show", "--start", format.string(from: start), "--end", format.string(from: failedAt),
            "--timezone", "UTC", "--style", "ndjson", "--info", "--debug", "--no-signpost", "--no-backtrace",
            "--no-pager", "--predicate", predicate], basename: basename, ownerPID: ownerPID)
    }

    static func classify(_ record: Data, query: Query) -> String? {
        guard record.count <= 16_384, let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              let message = (object["eventMessage"] ?? object["composedMessage"]) as? String,
              let number = (object["processID"] ?? object["processIdentifier"]) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue == Double(number.int64Value), (0...Int64(Int32.max)).contains(number.int64Value)
        else { return nil }
        let pid = number.int32Value
        let names = ["kernel": "kernel", "sandboxd": "sandboxd", "com.apple.WebKit.Networking": "webkit-networking",
                     "com.apple.WebKit.WebContent": "webkit-content"]
        var process = object["process"] as? String ?? ""
        if names[process] == nil, let path = object["processImagePath"] as? String,
           path.utf8.count <= 4_096, path.hasPrefix("/"),
           !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            let basename = URL(fileURLWithPath: path).lastPathComponent
            if names[basename] != nil { process = basename }
        }
        let category = object["category"] as? String ?? ""
        let text = message.lowercased()
        let sandbox = text.contains("sandbox") || category.lowercased().contains("sandbox")
        let scope: String
        if text.contains(query.basename.lowercased()) { scope = "owned-reader" }
        else if pid == query.ownerPID, sandbox || text.contains("operation not permitted") { scope = "owner-process" }
        else if ["kernel", "sandboxd"].contains(process), message.contains("(\(query.ownerPID))"), sandbox || text.contains("deny") {
            scope = "owner-kernel"
        } else { return nil }
        let classification: String
        // Published WebKit consume failure: token is quoted; errno is NOT quoted.
        let errnoRange = text.range(of: #"', errno = ([0-9]{1,3})$"#, options: .regularExpression)
        let consumeErrno = errnoRange.flatMap { text[$0].split(separator: "=").last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 <= 255 ? $0 : nil }
        let fileGrantLabels = [
            "unable to create sandbox extension": "issue-failure",
            "process is launching": "process-launch-pending",
            "created sandbox extension to resource directory": "resource-handle-ready",
            "has sandbox access to resource directory": "resource-access-confirmed",
        ]
        let method = text.range(of: "webpageproxy::maybeinitializesandboxextensionhandle: ")
        let fileGrantLabel = method.flatMap { fileGrantLabels[String(text[$0.upperBound...])] }
        if pid == query.ownerPID, category == "Sandbox", let fileGrantLabel {
            classification = fileGrantLabel
        } else if text.contains("could not create a sandbox extension for"), consumeErrno != nil {
            classification = "consume-failure"
        } else if text.contains("could not create a sandbox extension for"), !text.contains("errno") {
            classification = "issue-failure"
        } else if text.contains("sandbox extension"), text.contains("failed") {
            classification = "extension-failure"
        } else if text.contains("could not create a sandbox extension for") {
            classification = "extension-failure"
        } else if text.contains("deny("), text.contains("file-read") {
            classification = "read-denial"
        } else if sandbox, text.contains("deny(") {
            classification = "sandbox-denial"
        } else if text.contains("operation not permitted") {
            classification = "permission-denial"
        } else { return nil }
        // All output values come from fixed vocabularies or validated integers.
        // In particular, never copy quoted sandbox tokens, paths, UUIDs or messages.
        var fields = [classification, "process=\(pid == query.ownerPID ? "owner" : names[process] ?? "other")", "pid=\(pid)", "scope=" + scope]
        if classification == "read-denial",
           let operation = text.range(of: #"(?<![A-Za-z0-9_-])file-read-(?:data|metadata)(?![A-Za-z0-9_-])"#, options: .regularExpression) {
            fields.append(text[operation] == "file-read-data" ? "operation=file-read-data" : "operation=file-read-metadata")
        }
        if let range = message.range(of: #"com\.apple\.WebKit\.(Networking|WebContent)\([0-9]{1,10}\)"#, options: .regularExpression) {
            let target = String(message[range]).split(separator: "(")
            if target.count == 2, let name = names[String(target[0])],
               let targetPID = Int32(target[1].dropLast()), targetPID > 0 {
                fields.append("reportedTarget=\(name)"); fields.append("reportedPID=\(targetPID)")
            }
        }
        if let subsystem = object["subsystem"] as? String,
           ["com.apple.WebKit", "com.apple.sandbox", "com.apple.kernel", "com.apple.CFNetwork"].contains(subsystem) {
            fields.append("subsystem=" + subsystem)
        }
        if ["Sandbox", "Network", "Loading", "default", "Security"].contains(category) { fields.append("category=" + category) }
        if let consumeErrno { fields.append("errno=\(consumeErrno)") }
        return fields.joined(separator: ",")
    }

    struct Capture {
        private var pending = Data()
        private(set) var records = 0, oversized = 0
        private(set) var truncated = false
        private(set) var events: [String] = []

        mutating func append(_ bytes: ArraySlice<UInt8>, query: Query) {
            guard !truncated else { return }
            for byte in bytes {
                if byte == 10 {
                    records += 1
                    if let event = classify(pending, query: query) {
                        guard events.joined(separator: "; ").utf8.count + event.utf8.count < 16_000 else {
                            truncated = true; return
                        }
                        events.append(event)
                    }
                    pending.removeAll(keepingCapacity: true)
                    if records == 100 { truncated = true; return }
                } else if pending.count < 16_384 { pending.append(byte) }
                else { pending.removeAll(); oversized += 1; truncated = true; return }
            }
        }
    }

    static func report(image: URL, startedAt: Date, failedAt: Date) async -> String {
        guard let query = query(image: image, ownerPID: getpid(), startedAt: startedAt, failedAt: failedAt,
                                environment: ProcessInfo.processInfo.environment) else {
            return "reader-native-log status=unavailable,inconclusive=true"
        }
        return await Task.detached(priority: .utility) { await collect(query) }.value
    }

    private struct ChildIdentity: Equatable {
        let start: UInt64
        let path: String
        init?(_ pid: Int32) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
            self.path = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    // SwiftPM has no default MainActor isolation. This explicit nonisolated worker
    // also documents that neither launching nor draining runs on the caller's actor.
    nonisolated private static func collect(_ query: Query) async -> String {
        let deadline = ContinuousClock.now + .milliseconds(7_500)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = query.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        defer { handles.forEach { $0.closeFile() } }
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return "reader-native-log status=unavailable,inconclusive=true"
            }
        }
        do { try process.run() } catch { return "reader-native-log status=unavailable,inconclusive=true" }
        let child = ChildIdentity(process.processIdentifier)
        output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        var bytes = 0, capture = Capture()
        var truncated = false, cancelled = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while ContinuousClock.now < deadline, !truncated {
            // If exit happens during an EAGAIN drain, the next iteration must
            // still drain final bytes. Only a drain begun after exit is final.
            let exitedBeforeDrain = !process.isRunning
            for (index, handle) in handles.enumerated() {
                while bytes < 65_536, !capture.truncated, ContinuousClock.now < deadline {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, min(buffer.count, 65_536 - bytes))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    bytes += count
                    guard index == 0 else { continue } // Never emit raw stderr.
                    capture.append(buffer.prefix(count), query: query)
                }
                if bytes == 65_536 || capture.truncated { truncated = true }
                if truncated { break }
            }
            if exitedBeforeDrain { break }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { cancelled = true; break }
        }
        let timedOut = ContinuousClock.now >= deadline && !truncated && !cancelled
        // Reserve the final half-second for revalidated cleanup of this child only.
        for signal in [SIGTERM, SIGKILL] {
            guard process.isRunning, let child, child.path == "/usr/bin/log",
                  ChildIdentity(process.processIdentifier) == child else { break }
            _ = kill(process.processIdentifier, signal)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let running = process.isRunning
        let status = running ? "cleanup-unverified" : timedOut ? "timeout" : truncated ? "truncated"
            : cancelled ? "cancelled" : process.terminationStatus != 0 ? "unavailable" : capture.events.isEmpty ? "empty" : "collected"
        let cleanup = running ? ",childPID=\(process.processIdentifier),childStart=\(child.map { String($0.start) } ?? "unavailable"),childRunning=true" : ",childRunning=false,exitStatus=\(process.terminationStatus)"
        return "reader-native-log status=\(status),inconclusive=true,records=\(capture.records),oversized=\(capture.oversized)\(cleanup); " + capture.events.joined(separator: "; ")
    }
}
