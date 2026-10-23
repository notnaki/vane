// Compile with the production UpdateDownload.swift; loopback trust is test-local.
import Foundation
import Darwin

final class ResultBox: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<URL, Error>?
    var peak: Int64 = 0
    func store(_ value: Result<URL, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
    func wrote(_ value: Int64) { lock.lock(); defer { lock.unlock() }; peak = max(peak, value) }
}
let base = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2])
var failures = 0
for path in ["complete", "exact-cap", "truncated", "interrupted", "cancel", "http-error", "advertised-large", "unknown-large", "chunked-large", "redirect-good", "redirect-bad", "redirect-loop", "slow", "encoded"] {
    let destination = root.appendingPathComponent(path)
    let box = ResultBox(), finished = DispatchSemaphore(value: 0)
    do {
        let operation = try UpdateDownload.start(url: URL(string: base + "/" + path)!, destination: destination,
            maxBytes: 1024, timeout: path == "slow" ? 0.2 : 3,
            trusted: { url in url.scheme == "http" && url.host == "127.0.0.1" && url.path != "/forbidden" },
            progress: { _, _ in
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                box.wrote(size)
            }, completion: { result in box.store(result); finished.signal() })
        if path == "cancel" { Thread.sleep(forTimeInterval: 0.05); operation.cancel() }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            operation.cancel(); print("FAIL: \(path) timed out"); failures += 1; continue
        }
        let success = ["complete", "exact-cap", "redirect-good"].contains(path)
        var ok = box.peak <= 1024
        switch box.result {
        case .success(let file):
            let data = try Data(contentsOf: file)
            ok = ok && success && file == destination && data == (path == "exact-cap" ? Data(repeating: 120, count: 1024) : Data("complete archive fixture".utf8))
        case .failure(let error):
            if ["advertised-large", "unknown-large", "chunked-large"].contains(path) {
                if case UpdateDownload.Failure.tooLarge = error {} else { print("unexpected cap error: \(error)"); ok = false }
            }
            ok = ok && !success && !FileManager.default.fileExists(atPath: destination.path)
        case .none: ok = false
        }
        print("\(ok ? "PASS" : "FAIL"): production download \(path), written=\(box.peak), success=\(success)")
        if !ok { failures += 1 }
    } catch {
        print("FAIL: could not start \(path): \(error)"); failures += 1
    }
}
exit(failures == 0 ? 0 : 1)
