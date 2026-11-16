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

/// TEMPORARY CI probe: does a burst of released fixture WebContent processes stall a
/// live page and a new window presentation, and does killing them on retire avoid it?
@MainActor final class ZZGPUBacklogProbeTests: XCTestCase {
    private func page(_ i: Int) -> String {
        "<body style='font:16px system-ui'><form><input autocomplete=username value=u\(i)><input type=password>" +
            "<button>Sign in</button></form><iframe srcdoc='<p>frame \(i)</p>'></iframe>" +
            String(repeating: "<p style='box-shadow:0 2px 8px #0006;border-radius:6px'>row</p>", count: 40) + "</body>"
    }
    private func hidden() -> (WKWebView, NSWindow) {
        let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web
        return (web, window)
    }
    private func loaded(_ web: WKWebView, _ i: Int) async throws {
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://login.example.test/\(i)")!), responseHTML: page(i))
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await web.evaluateJavaScript("document.body.offsetHeight")
        try await Task.sleep(for: .milliseconds(150))
    }
    private func burst(kill: Bool) async throws {
        var made: [(WKWebView, NSWindow)] = []
        for i in 0..<16 { let pair = hidden(); try await loaded(pair.0, i); made.append(pair) }
        for (web, window) in made {
            if kill { web.perform(NSSelectorFromString("_killWebContentProcess")) }
            web.stopLoading(); window.contentView = nil; window.close()
        }
        made.removeAll()
    }
    private func liveWorst() async throws -> Double {
        let (web, window) = hidden()
        defer { window.contentView = nil; window.close() }
        try await loaded(web, 99)
        var worst = 0.0
        for n in 0..<40 {
            let t = StallDiag.now()
            _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<p style=\"box-shadow:0 2px 8px #0006\">live \(n)</p>'); document.body.offsetHeight")
            worst = max(worst, StallDiag.now() - t)
            try await Task.sleep(for: .milliseconds(50))
        }
        return worst
    }
    private func presentation() async throws -> Double {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 120, width: 250, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        let start = StallDiag.now()
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        var elapsed = -1.0
        while StallDiag.now() - start < 20 {
            if app.isActive && window.isKeyWindow && window.occlusionState.contains(.visible) { elapsed = StallDiag.now() - start; break }
            if !app.isActive { app.activate(ignoringOtherApps: true) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.orderOut(nil); window.close()
        try await loop.close()
        return elapsed
    }
    private func probe(_ variant: String, kill: Bool) async throws {
        TestEnvironment.prepare(); _ = NSApplication.shared; WebKitStartup.prepare()
        for round in 0..<2 {
            let base = try await liveWorst()
            try await burst(kill: kill)
            let started = StallDiag.now()
            let live = try await liveWorst()
            let shown = try await presentation()
            print("GPU_PROBE variant=\(variant) round=\(round) baselineJsWorst=\(String(format: "%.2f", base)) afterBurstJsWorst=\(String(format: "%.2f", live)) presentation=\(String(format: "%.2f", shown)) span=\(String(format: "%.1f", StallDiag.now() - started))")
            if live > 3 { StallDiag.saveAfter("probe-\(variant)", seconds: live) }
            try await Task.sleep(for: .seconds(8))
        }
    }
    func testAKilledBurst() async throws { try await probe("killed", kill: true) }
    func testBReleasedBurst() async throws { try await probe("released", kill: false) }
}
