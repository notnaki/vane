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
// Declining a redirect may still deliver its original 302 response before the
// cancellation completes. Drive that real delegate sequence without a network race.
do {
    let destination = root.appendingPathComponent("rejected-redirect-response")
    let box = ResultBox()
    let operation = try UpdateDownload(destination: destination, maxBytes: 1024,
        trusted: { $0.path != "/forbidden" }, progress: { _, _ in }, completion: { box.store($0) })
    let session = URLSession(configuration: .ephemeral)
    let source = URL(string: base + "/redirect-bad")!
    let task = session.dataTask(with: source) // Never resumed: callbacks below are serialized here.
    let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: "HTTP/1.1",
                                   headerFields: ["Location": base + "/forbidden"])!
    operation.urlSession(session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: URL(string: base + "/forbidden")!)) {
            precondition($0 == nil, "Untrusted redirect must be declined")
        }
    operation.urlSession(session, dataTask: task, didReceive: response) {
        precondition($0 == .cancel, "A response after rejection must stay canceled")
    }
    operation.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    let preserved: Bool
    if case .failure(UpdateDownload.Failure.untrustedURL) = box.result { preserved = true }
    else { preserved = false }
    let ok = preserved && !FileManager.default.fileExists(atPath: destination.path)
    print("\(ok ? "PASS" : "FAIL"): redirect rejection remains terminal after its 302 response")
    if !ok { failures += 1 }
} catch {
    print("FAIL: rejected redirect response sequence: \(error)")
    failures += 1
}
for path in ["complete", "asset-api", "asset-api-redirect", "browser-to-api", "api-to-browser", "partial-fallback", "empty-fallback", "both-fail", "slow-fallback", "exact-cap", "truncated", "interrupted", "cancel", "http-error", "advertised-large", "unknown-large", "chunked-large", "redirect-good", "redirect-bad", "redirect-loop", "slow", "encoded"] {
    let destination = root.appendingPathComponent(path)
    let box = ResultBox(), finished = DispatchSemaphore(value: 0)
    do {
        let routes: [String: (String, String)] = [
            "browser-to-api": ("http-error", "asset-api-redirect"),
            "api-to-browser": ("api-http-error", "complete"),
            "partial-fallback": ("interrupted", "complete"),
            "empty-fallback": ("empty", "complete"),
            "both-fail": ("http-error", "api-http-error"),
            "slow-fallback": ("delayed-http-error", "slow")]
        let route = routes[path]
        let mustNotRetry = ["complete", "cancel", "advertised-large", "unknown-large", "chunked-large", "redirect-bad", "redirect-loop", "slow", "encoded"].contains(path)
        let fallback = route?.1 ?? (mustNotRetry ? "fallback-must-not-fetch" : nil)
        let started = ProcessInfo.processInfo.systemUptime
        let operation = try UpdateDownload.start(url: URL(string: base + "/" + (route?.0 ?? path))!,
            fallbackURL: fallback.flatMap { URL(string: base + "/" + $0) }, destination: destination,
            maxBytes: 1024, timeout: path == "slow" ? 0.2 : path == "slow-fallback" ? 1 : 3,
            trusted: { url in url.scheme == "http" && url.host == "127.0.0.1" && url.path != "/forbidden" },
            progress: { _, _ in
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                box.wrote(size)
            }, completion: { result in box.store(result); finished.signal() })
        if path == "cancel" { Thread.sleep(forTimeInterval: 0.05); operation.cancel() }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            operation.cancel(); print("FAIL: \(path) timed out"); failures += 1; continue
        }
        let success = ["complete", "asset-api", "asset-api-redirect", "browser-to-api", "api-to-browser", "partial-fallback", "empty-fallback", "exact-cap", "redirect-good"].contains(path)
        var ok = box.peak <= 1024
        if path == "slow-fallback" {
            ok = ok && ProcessInfo.processInfo.systemUptime - started < 1.5
        }
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
