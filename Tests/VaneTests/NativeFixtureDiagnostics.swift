import AppKit
import Darwin
import WebKit

/// Failure-only diagnostics for the WebContent process owned by a fixture's live view.
/// Never enumerate or sample another application's WebKit processes.
@MainActor enum NativeFixtureDiagnostics {
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
        // Omit process arguments, paths and binary-image metadata; keep only bounded stacks.
        return String(graph[..<end].prefix(16_384))
    }

    static func failureReport(for web: WKWebView) async -> String {
        let window = web.window
        let pid = contentPID(web)
        let ui = "uiPID=\(getpid()), appActive=\(NSApplication.shared.isActive), " +
            "windowVisible=\(window?.isVisible ?? false), windowOcclusion=\(window?.occlusionState.rawValue ?? 0), " +
            "contentPID=\(pid.map(String.init) ?? "unavailable")"
        guard let pid, let captured = identity(pid) else { return ui + "; native process identity unavailable" }
        let metadata = ui + ", contentStart=\(captured.start), contentPath=\(captured.path), contentState=\(captured.state)"
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
        let deadline = ContinuousClock.now + .milliseconds(1750)
        do { try sampler.run() } catch { return "sample unavailable: \(error.localizedDescription)" }
        let samplerIdentity = identity(sampler.processIdentifier)
        let samplerMetadata = "samplerPID=\(sampler.processIdentifier), samplerStart=\(samplerIdentity?.start ?? 0), samplerPath=\(samplerIdentity?.path ?? "unavailable")"
        // One second of stack collection, with a two-second bound including symbolication.
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
            return samplerMetadata + "; sample unavailable: exceeded diagnostic bound; samplerRunning=\(sampler.isRunning)"
        }
        guard stillOwned(), maySample(captured, observed: identity(captured.pid), ownedPID: captured.pid) else {
            return samplerMetadata + "; sample discarded: fixture process changed during collection"
        }
        guard sampler.terminationStatus == 0, let data = try? Data(contentsOf: output) else {
            return samplerMetadata + "; sample unavailable: sampler exit \(sampler.terminationStatus)"
        }
        return samplerMetadata + ", samplerRunning=false; WebContent symbolic stacks:\n" + symbolsOnly(String(decoding: data, as: UTF8.self))
    }
}
