import Foundation
import Darwin
@testable import vane

/// Diagnostic-only: sample this exact XCTest UI process if its main queue stops
/// acknowledging a background heartbeat. No WebKit behavior or deadline changes.
final class NativeNavigationLagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vane.navigation-lag"))
    private let target: NativeFixtureDiagnostics.Identity
    private let directory: URL
    private let label: String
    private var acknowledged = DispatchTime.now().uptimeNanoseconds
    private var pending = false
    private var active = true
    private var sampled = false
    private var largestGap: UInt64 = 0
    private var sampler: Process?
    private var samplerIdentity: NativeFixtureDiagnostics.Identity?
    private var output: URL?
    var didSample: Bool { lock.withLock { sampled } }
    var sampleOutput: URL? { lock.withLock { output } }

    init?(label: String) {
        guard let path = ProcessInfo.processInfo.environment["VANE_NAVIGATION_LAG_DIR"],
              let target = NativeFixtureDiagnostics.identity(getpid()) else { return nil }
        self.target = target
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
        self.label = label
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let action = lock.withLock { () -> (Bool, Bool) in
            guard active else { return (false, false) }
            let gap = now - acknowledged
            largestGap = max(largestGap, gap)
            let sample = gap > 500_000_000 && !sampled
            if sample { sampled = true }
            let enqueue = !pending
            pending = true
            return (enqueue, sample)
        }
        if action.0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.acknowledged = DispatchTime.now().uptimeNanoseconds
                    self.pending = false
                }
            }
        }
        if action.1 { sample() }
    }

    private func sample() {
        guard let observed = NativeFixtureDiagnostics.identity(target.pid),
              observed.start == target.start, observed.path == target.path else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        let output = directory.appendingPathComponent("ui-\(label)-\(target.pid)-\(UUID()).txt")
        // -mayDie reads symbols before sampling and can miss the entire stall.
        // This fixture keeps its own UI process alive through analysis instead.
        process.arguments = [String(target.pid), "1", "10", "-file", output.path]
        let progress = output.appendingPathExtension("progress")
        FileManager.default.createFile(atPath: progress.path, contents: nil)
        let diagnostics = try? FileHandle(forWritingTo: progress)
        process.standardOutput = diagnostics ?? FileHandle.nullDevice
        process.standardError = diagnostics ?? FileHandle.nullDevice
        do { try process.run() } catch { return }
        lock.withLock {
            sampler = process
            self.output = output
            samplerIdentity = NativeFixtureDiagnostics.identity(process.processIdentifier)
        }
    }

    func close() async {
        lock.withLock { active = false }
        // Drain the private queue before inspecting its sampler publication.
        await withCheckedContinuation { continuation in
            timer.setCancelHandler { continuation.resume() }
            timer.cancel()
        }
        let (process, captured, gap) = lock.withLock { (sampler, samplerIdentity, largestGap) }
        // Symbolication happens after the timed navigation assertion. This is
        // solely a diagnostic cleanup budget, not a longer navigation deadline.
        let deadline = ContinuousClock.now + .seconds(30)
        while process?.isRunning == true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let process, process.isRunning, let captured,
           let current = NativeFixtureDiagnostics.identity(captured.pid),
           current.start == captured.start, current.path == "/usr/bin/sample" {
            process.terminate()
        }
        let exitDeadline = ContinuousClock.now + .seconds(1)
        while process?.isRunning == true, ContinuousClock.now < exitDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let process, process.isRunning, let captured,
           let current = NativeFixtureDiagnostics.identity(captured.pid),
           current.start == captured.start, current.path == "/usr/bin/sample" {
            kill(captured.pid, SIGKILL)
        }
        NativeFixtureDiagnostics.emit("navigation UI lag: path=\(label), maxGapMilliseconds=\(Double(gap) / 1_000_000), sampled=\(sampled)")
    }
}

import XCTest
@MainActor final class NativeNavigationLagProbeTests: XCTestCase {
    func testSamplesOwnedUIThreadDuringAControlledStall() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let probe = try XCTUnwrap(NativeNavigationLagProbe(label: "controlled-stall"))
            // A real blocked UI actor, not a mocked heartbeat or native getter.
            probeControlledUIStall()
            await probe.close()
            XCTAssertTrue(probe.didSample)
            let output = try XCTUnwrap(probe.sampleOutput)
            let stacks = try String(contentsOf: output, encoding: .utf8)
            XCTAssertTrue(stacks.contains("Call graph:"))
            XCTAssertTrue(stacks.contains("probeControlledUIStall"),
                          "The collector must actually observe the controlled blocked UI frame")
        } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
}

@inline(never) private func probeControlledUIStall() {
    usleep(4_000_000)
}
