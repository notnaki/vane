import Foundation
import WebKit
import XCTest
import AppKit
@testable import vane

// TEMPORARY CI diagnostic: drop before merge.
enum StallDiag {
    static let dir = "/tmp/vane-stall-diag"
    nonisolated(unsafe) static var captures = 0
    nonisolated(unsafe) static var saves = 0
    static let lock = NSLock()
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func shell(_ script: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
    }

    /// Live, system-wide timeline spindump while something is stalled.
    static func capture(_ reason: String, target: Int32?) {
        lock.lock(); defer { lock.unlock() }
        guard captures < 6 else { return }
        captures += 1
        let n = captures, t = String(format: "%.1f", now())
        print("STALL_DIAG capture#\(n) reason=\(reason) target=\(target.map(String.init) ?? "-") uptime=\(t)")
        shell("""
            ps -axo pid,ppid,stat,pri,ni,%cpu,rss,time,comm > \(dir)/ps-\(n).txt 2>&1
            sudo -n /usr/sbin/spindump \(target.map(String.init) ?? "-notarget") 4 20 -timeline -o \(dir)/spindump-\(n)-\(reason).txt > /dev/null 2>&1
            """)
    }

    /// Retroactive: tailspin holds the last ~20s, log show the stall window.
    static func saveAfter(_ reason: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard saves < 6 else { return }
        saves += 1
        let n = saves
        print("STALL_DIAG save#\(n) reason=\(reason) stall=\(String(format: "%.2f", seconds))s uptime=\(String(format: "%.1f", now()))")
        let window = Int(seconds) + 8
        shell("""
            /usr/bin/log show --last \(window)s --info --debug --style compact \
              --predicate 'process == "runningboardd" OR subsystem == "com.apple.WebKit" OR process CONTAINS "WebKit" OR process == "xctest"' \
              > \(dir)/log-\(n).txt 2>&1
            sudo -n chmod -R a+r \(dir) 2>/dev/null
            """)
    }

    /// Wraps one evaluateJavaScript round-trip.
    @MainActor static func measure<T>(_ web: WKWebView, _ label: String, _ body: () async throws -> T) async rethrows -> T {
        let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        let start = now()
        let watcher = Task.detached {
            try? await Task.sleep(for: .milliseconds(4000))
            if !Task.isCancelled { capture("js", target: pid) }
        }
        defer { watcher.cancel() }
        let result = try await body()
        let elapsed = now() - start
        if elapsed > 0.75 {
            print("STALL_DIAG js \(String(format: "%.2f", elapsed))s pid=\(pid.map(String.init) ?? "-") from uptime \(String(format: "%.1f", start)) label=\(label.prefix(80).replacingOccurrences(of: "\n", with: " "))")
        }
        if elapsed > 5 { saveAfter("js", seconds: elapsed) }
        return result
    }
}

/// TEMPORARY CI probe: does a fixture-style WebContent paint touch Metal on CI, with
/// accelerated drawing on vs off?
@MainActor final class ZZMetalPaintProbeTests: XCTestCase {
    private func metalFrames(accelerated: Bool) async throws -> String {
        TestEnvironment.prepare(); _ = NSApplication.shared; WebKitStartup.prepare()
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.setValue(accelerated, forKey: "acceleratedDrawingEnabled")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web
        defer { window.contentView = nil; window.close() }
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://login.example.test/")!),
            responseHTML: "<body style='font:16px system-ui'><form><input autocomplete=username><input type=password><button>Go</button></form>")
        while web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let pid = try XCTUnwrap(web.value(forKey: "_webProcessIdentifier") as? NSNumber).int32Value
        let out = "/tmp/vane-stall-diag/paint-\(accelerated).txt"
        try? FileManager.default.createDirectory(atPath: "/tmp/vane-stall-diag", withIntermediateDirectories: true)
        let sampler = Process(); sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = ["\(pid)", "3", "-file", out]
        sampler.standardOutput = FileHandle.nullDevice; sampler.standardError = FileHandle.nullDevice
        try sampler.run()
        var n = 0
        while sampler.isRunning {
            _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<p style=\"box-shadow:0 2px 8px #0006;border-radius:6px\">row \(n)</p>');window.scrollTo(0,1e6);1")
            n += 1
            try await Task.sleep(for: .milliseconds(15))
        }
        let text = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        func count(_ s: String) -> Int { text.components(separatedBy: s).count - 1 }
        return "accelerated=\(accelerated) mutations=\(n) metal=\(count("MetalContext")) accelQueue=\(count("AccelQueue")) " +
            "inProcess=\(count("RemoteLayerWithInProcessRenderingBackingStore")) remote=\(count("RemoteLayerWithRemoteRenderingBackingStore")) " +
            "updateRendering=\(count("updateRendering"))"
    }
    func testMetalUseByAcceleration() async throws {
        print("METAL_PROBE " + (try await metalFrames(accelerated: true)))
        print("METAL_PROBE " + (try await metalFrames(accelerated: false)))
    }
}
