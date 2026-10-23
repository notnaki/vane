import Foundation
import Darwin

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("vane-launch-ownership-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}
func scene(_ name: String) throws -> (URL, URL) {
    let parent = root.appendingPathComponent(name)
    let source = parent.appendingPathComponent("incoming.app"), target = parent.appendingPathComponent("Vane.app")
    for (url, label) in [(source, "new"), (target, "old")] {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(label.utf8).write(to: url.appendingPathComponent("fixture"))
    }
    try BundleReplacement.install(source: source, at: target, keepPrevious: false,
        verify: { _ in true }, mayReplaceTarget: { _ in true })
    return (source, target)
}
func journal(_ target: URL) -> URL {
    target.deletingLastPathComponent().appendingPathComponent(".Vane.app.vane-transaction.json")
}
func contents(_ target: URL) -> String? { try? String(contentsOf: target.appendingPathComponent("fixture"), encoding: .utf8) }
let browser = BundleReplacement.LaunchOwner(pid: 123_456, start: 987_654, isCurrent: { true })
do {
    let (_, target) = try scene("owner")
    check("helper claims launch for authenticated browser", BundleReplacement.beginLaunch(at: target, owner: browser) == .waitingForHealth)
    let record = try JSONSerialization.jsonObject(with: Data(contentsOf: journal(target))) as! [String: Any]
    check("journal never records helper process identity", record["launchPID"] as? Int32 == browser.pid && record["launchStart"] as? UInt64 == browser.start && browser.pid != getpid())
    for impostor in [BundleReplacement.LaunchOwner(pid: browser.pid + 1, start: browser.start, isCurrent: { true }),
                     BundleReplacement.LaunchOwner(pid: browser.pid, start: browser.start + 1, isCurrent: { true }),
                     BundleReplacement.LaunchOwner(pid: browser.pid, start: browser.start, isCurrent: { false })] {
        check("wrong or stale caller cannot confirm another browser", !BundleReplacement.markHealthy(at: target, owner: impostor) && fm.fileExists(atPath: journal(target).path))
    }
    check("authenticated owner completes health cleanup", BundleReplacement.markHealthy(at: target, owner: browser) && !fm.fileExists(atPath: journal(target).path) && contents(target) == "new")
}
for kind in ["stale", "zero-pid", "missing-start", "changed-under-lock"] {
    let (_, target) = try scene(kind)
    let original = try Data(contentsOf: journal(target))
    var calls = 0
    let owner = BundleReplacement.LaunchOwner(pid: kind == "zero-pid" ? 0 : browser.pid,
        start: kind == "missing-start" ? 0 : browser.start, isCurrent: {
            calls += 1
            return kind == "changed-under-lock" && calls == 1
        })
    check("\(kind) cannot claim launch", BundleReplacement.beginLaunch(at: target, owner: owner) == .needsAttention && (try? Data(contentsOf: journal(target))) == original)
}
do {
    let parent = root.appendingPathComponent("orphan")
    let target = parent.appendingPathComponent("Vane.app")
    let stage = parent.appendingPathComponent(".Vane.app.vane-stage-\(UUID().uuidString)")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    let stale = BundleReplacement.LaunchOwner(pid: browser.pid, start: browser.start, isCurrent: { false })
    check("old executable cannot remove unjournaled stages", BundleReplacement.beginLaunch(at: target, owner: stale) == .needsAttention && fm.fileExists(atPath: stage.path))
    check("authenticated browser removes abandoned stages", BundleReplacement.beginLaunch(at: target, owner: browser) == .unchanged && !fm.fileExists(atPath: stage.path))
}
do {
    let (_, target) = try scene("concurrent")
    _ = BundleReplacement.beginLaunch(at: target, owner: browser)
    let record = try Data(contentsOf: journal(target))
    let other = BundleReplacement.LaunchOwner(pid: browser.pid + 1, start: browser.start, isCurrent: { true })
    check("live browser keeps recovery ownership", BundleReplacement.beginLaunch(at: target, processAlive: { _, _, _ in true }, owner: other) == .needsAttention && (try? Data(contentsOf: journal(target))) == record)
    check("dead browser permits verified rollback", BundleReplacement.beginLaunch(at: target, processAlive: { _, _, _ in false }, owner: other) == .rolledBack && contents(target) == "old")
}
let current = BundleReplacement.processStart(getpid())!
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
check("kernel identity accepts exact running executable", BundleReplacement.LaunchOwner.process(getpid(), start: current, executable: executable).valid)
check("kernel identity rejects reused pid start", !BundleReplacement.LaunchOwner.process(getpid(), start: current + 1, executable: executable).valid)
check("kernel identity rejects another target executable", !BundleReplacement.LaunchOwner.process(getpid(), start: current, executable: root.appendingPathComponent("other")).valid)
exit(failures == 0 ? 0 : 1)
