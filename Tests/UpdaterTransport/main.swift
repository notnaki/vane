// This probes the real URLSession transport used by Updater. Loopback is explicitly a
// simulated release host; production GitHub trust/signature policies are not disabled.
import Foundation
import Darwin
let base = CommandLine.arguments[1]
var failures = 0
for path in ["complete", "truncated", "interrupted", "cancel", "http-error"] {
    let session = URLSession(configuration: .ephemeral)
    let finished = DispatchSemaphore(value: 0)
    let task = session.downloadTask(with: URL(string: base + "/" + path)!) { file, response, error in
        let http = response as? HTTPURLResponse
        let data = file.flatMap { try? Data(contentsOf: $0) }
        let ok: Bool
        switch path {
        case "complete": ok = error == nil && http?.statusCode == 200 && data == Data("complete archive fixture".utf8)
        case "http-error": ok = http?.statusCode == 503
        default: ok = error != nil && file == nil
        }
        print("\(ok ? "PASS" : "FAIL"): real URLSession \(path), status=\(http?.statusCode ?? -1), error=\(String(describing: error))")
        if !ok { failures += 1 }
        finished.signal()
    }
    task.resume()
    if path == "cancel" { Thread.sleep(forTimeInterval: 0.1); task.cancel() }
    if finished.wait(timeout: .now() + 10) == .timedOut { print("FAIL: transport timed out"); failures += 1; task.cancel() }
    session.invalidateAndCancel()
}
exit(failures == 0 ? 0 : 1)
