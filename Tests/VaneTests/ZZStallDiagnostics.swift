import Foundation
import WebKit
import XCTest

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
        guard captures < 8 else { return }
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
        guard saves < 4 else { return }
        saves += 1
        let n = saves
        print("STALL_DIAG save#\(n) reason=\(reason) stall=\(String(format: "%.2f", seconds))s uptime=\(String(format: "%.1f", now()))")
        let window = Int(seconds) + 8
        shell("""
            sudo -n /usr/bin/tailspin save -l 25 -r \(reason) \(dir)/tail-\(n).tailspin > \(dir)/tail-\(n).err 2>&1 && \
              sudo -n /usr/sbin/spindump -i \(dir)/tail-\(n).tailspin -timeline -o \(dir)/tail-\(n).txt > /dev/null 2>&1
            /usr/bin/log show --last \(window)s --info --debug --style compact \
              --predicate 'process == "runningboardd" OR subsystem == "com.apple.WebKit" OR process CONTAINS "WebKit" OR process == "xctest"' \
              > \(dir)/log-\(n).txt 2>&1
            sudo -n chmod -R a+r \(dir) 2>/dev/null
            """)
    }

    final class Observer: NSObject, XCTestObservation {
        func testCaseWillStart(_ testCase: XCTestCase) {
            print("STALL_DIAG start \(testCase.name) uptime=\(String(format: "%.1f", StallDiag.now()))")
        }
    }
    nonisolated(unsafe) static let observer = Observer()

    static let watchdog: Void = {
        DispatchQueue.main.async { MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(observer) } }
        Thread.detachNewThread {
            while true {
                let sent = now()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 0.5) == .timedOut {
                    if sem.wait(timeout: .now() + 2.5) == .timedOut {
                        capture("main", target: ProcessInfo.processInfo.processIdentifier)
                        sem.wait()
                        saveAfter("main", seconds: now() - sent)
                    }
                    print("STALL_DIAG main stall \(String(format: "%.2f", now() - sent))s from uptime \(String(format: "%.1f", sent))")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }()

    /// Wraps one evaluateJavaScript round-trip.
    @MainActor static func measure<T>(_ web: WKWebView, _ label: String, _ body: () async throws -> T) async rethrows -> T {
        _ = watchdog
        let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        let start = now()
        let watcher = Task.detached {
            try? await Task.sleep(for: .milliseconds(2500))
            if !Task.isCancelled { capture("js", target: pid) }
        }
        defer { watcher.cancel() }
        let result = try await body()
        let elapsed = now() - start
        if elapsed > 0.75 {
            print("STALL_DIAG js \(String(format: "%.2f", elapsed))s pid=\(pid.map(String.init) ?? "-") from uptime \(String(format: "%.1f", start)) label=\(label.prefix(80).replacingOccurrences(of: "\n", with: " "))")
        }
        if elapsed > 3 { saveAfter("js", seconds: elapsed) }
        return result
    }
}
