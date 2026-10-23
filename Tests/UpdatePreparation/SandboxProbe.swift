// Opt-in native probe. Compile into a uniquely identified temporary app bundle, sign
// with Vane.entitlements, and directly run its executable with a helper-temp canary path.
// Never give it Vane's bundle identity or pass an existing user file as the canary.
import Foundation
import Darwin

guard CommandLine.arguments.count == 2 else {
    fputs("usage: WorkspaceProbe /path/to/owned/helper-temp/canary\n", stderr)
    exit(2)
}

func attempt(_ path: String, flags: Int32) -> [String: Any] {
    errno = 0
    let descriptor = open(path, flags | O_NOFOLLOW)
    let result: [String: Any] = ["allowed": descriptor >= 0, "errno": descriptor >= 0 ? 0 : errno]
    if descriptor >= 0 { close(descriptor) }
    return result
}

let canary = CommandLine.arguments[1]
let own = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-probe-" + UUID().uuidString)
var ownSuccess = false
let marker = Data("probe-owned-temp".utf8)
do {
    try marker.write(to: own, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: own) }
    let matches = try Data(contentsOf: own) == marker
    try FileManager.default.removeItem(at: own)
    ownSuccess = matches
} catch { }

var info = proc_bsdinfo()
let size = Int32(MemoryLayout<proc_bsdinfo>.size)
let observed = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size)
var executable = [CChar](repeating: 0, count: 4096)
let observedPath = proc_pidpath(getpid(), &executable, UInt32(executable.count))
let read = attempt(canary, flags: O_RDONLY)
let write = attempt(canary, flags: O_WRONLY)
let result: [String: Any] = [
    "pid": getpid(),
    "startMicros": observed == size ? UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec) : 0,
    "executable": observedPath > 0 ? String(cString: executable) : "unavailable",
    "sandboxHome": NSHomeDirectory(),
    "ownTemporaryFileCreatedReadAndDeleted": ownSuccess,
    "readCanary": read,
    "writeCanary": write,
]
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
let denied = [EPERM, EACCES]
let isolated = ownSuccess && read["allowed"] as? Bool == false && write["allowed"] as? Bool == false
    && denied.contains(read["errno"] as? Int32 ?? 0) && denied.contains(write["errno"] as? Int32 ?? 0)
exit(isolated ? 0 : 1)
