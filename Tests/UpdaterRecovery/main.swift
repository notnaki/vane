import Foundation
import Darwin

let fm = FileManager.default
let args = CommandLine.arguments
func label(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("fixture"), encoding: .utf8) }
func install(_ source: URL, _ target: URL, fault: ((BundleReplacement.Step) -> Bool)? = nil) throws {
    try BundleReplacement.install(source: source, at: target, keepPrevious: false,
        verify: { label($0) == "new" }, mayReplaceTarget: { _ in true }, fault: fault)
}
if args.count > 1, args[1] == "child" {
    let source = URL(fileURLWithPath: args[3]), target = URL(fileURLWithPath: args[4])
    if args[2] == "loaded-old" {
        let marker = source.appendingPathComponent("continue")
        while !fm.fileExists(atPath: marker.path) { usleep(10000) }
        let executable = target.appendingPathComponent("Contents/MacOS/Check")
        _ = BundleReplacement.beginLaunch(at: target, expectedExecutable: executable)
        BundleReplacement.markHealthy(at: target, expectedExecutable: executable)
        let remaining = try! fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let keptOld = remaining.contains { $0.lastPathComponent.hasPrefix(".Vane.app.vane-stage-") && label($0) == "old" }
        exit(keptOld ? 0 : 1)
    }
    switch args[2] {
    case "install":
        try install(source, target, fault: { step in
            if String(describing: step) == args[5] { kill(getpid(), SIGKILL) }
            return false
        })
    case "launch", "rollback", "healthy":
        let fault: (BundleReplacement.Step) -> Bool = { step in
            if String(describing: step) == args[5] { kill(getpid(), SIGKILL) }
            return false
        }
        let result = BundleReplacement.beginLaunch(at: target, fault: fault)
        if args[2] == "healthy" {
            guard result == .waitingForHealth else { exit(2) }
            BundleReplacement.markHealthy(at: target, fault: fault)
        } else if args[2] == "launch", args[5] == "none" {
            guard result == .waitingForHealth else { exit(2) }
            kill(getpid(), SIGKILL)
        }
    default: exit(2)
    }
    exit(0)
}
let root = fm.temporaryDirectory.appendingPathComponent("vane-updater-recovery-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { failures += 1 }
}
func scene(_ name: String) throws -> (URL, URL) {
    let directory = root.appendingPathComponent(name)
    let source = directory.appendingPathComponent("incoming.app"), target = directory.appendingPathComponent("Vane.app")
    for (url, value) in [(source, "new"), (target, "old")] {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url.appendingPathComponent("fixture"))
    }
    return (source, target)
}
func stages(_ target: URL) -> [URL] {
    try! fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".Vane.app.vane-stage-") }
}
func journal(_ target: URL) -> URL { target.deletingLastPathComponent().appendingPathComponent(".Vane.app.vane-transaction.json") }
func child(_ operation: String, _ source: URL, _ target: URL, _ step: String = "none") throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = ["child", operation, source.path, target.path, step]
    p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    return p.terminationStatus
}
for (name, ok) in BundleReplacement.check() { check("baseline: " + name, ok) }
for step in ["beforeCopy", "afterCopy", "beforeStageSync", "beforeJournal", "beforeJournalSync", "beforeSwap", "afterSwapBeforeSync", "afterSwap"] {
    let (source, target) = try scene(step)
    check("process killed at \(step)", try child("install", source, target, step) == SIGKILL)
    if step.hasPrefix("afterSwap") {
        check("post-swap process death retains old bundle", label(target) == "new" && stages(target).contains { label($0) == "old" })
        check("replacement first launch retains recovery", BundleReplacement.beginLaunch(at: target) == .waitingForHealth)
        check("dead launch restores old bundle", BundleReplacement.beginLaunch(at: target, processAlive: { _, _, _ in false }) == .rolledBack && label(target) == "old")
    } else {
        check("pre-swap death recovers original at \(step)", BundleReplacement.beginLaunch(at: target) == .unchanged && label(target) == "old" && stages(target).isEmpty)
        try install(source, target)
        check("retry after \(step) stages safely", label(target) == "new" && stages(target).contains { label($0) == "old" })
    }
}
do {
    let (source, target) = try scene("changed-new")
    try install(source, target)
    try Data("incomplete".utf8).write(to: target.appendingPathComponent("fixture"))
    let launch = BundleReplacement.beginLaunch(at: target)
    BundleReplacement.markHealthy(at: target)
    check("changed replacement is never accepted healthy", launch != .waitingForHealth && (label(target) == "old" || stages(target).contains { label($0) == "old" }))
}
do {
    let (source, target) = try scene("changed-old")
    try install(source, target)
    check("crash during launch", try child("launch", source, target) == SIGKILL)
    let stage = stages(target)[0]
    try fm.removeItem(at: stage.appendingPathComponent("fixture"))
    check("rollback refuses incomplete previous bundle", BundleReplacement.beginLaunch(at: target) == .needsAttention && label(target) == "new" && fm.fileExists(atPath: journal(target).path))
}
do {
    let (source, target) = try scene("changed-after-launch")
    try install(source, target)
    _ = BundleReplacement.beginLaunch(at: target)
    try Data("incomplete".utf8).write(to: target.appendingPathComponent("fixture"))
    BundleReplacement.markHealthy(at: target)
    check("health rechecks replacement integrity", stages(target).contains { label($0) == "old" } && fm.fileExists(atPath: journal(target).path))
}
do {
    let (source, target) = try scene("journal-symlink")
    try install(source, target)
    let outside = root.appendingPathComponent("unrelated-record.json")
    try fm.moveItem(at: journal(target), to: outside)
    let data = try Data(contentsOf: outside)
    try fm.createSymbolicLink(at: journal(target), withDestinationURL: outside)
    check("recovery rejects linked transaction record", BundleReplacement.beginLaunch(at: target) == .needsAttention && (try? Data(contentsOf: outside)) == data)
}
do {
    let (source, target) = try scene("target-symlink")
    try install(source, target)
    let outside = root.appendingPathComponent("unrelated.app")
    try fm.moveItem(at: target, to: outside)
    try fm.createSymbolicLink(at: target, withDestinationURL: outside)
    check("recovery rejects linked target", BundleReplacement.beginLaunch(at: target) == .needsAttention && label(outside) == "new")
}
do {
    let (source, target) = try scene("dangling-journal")
    try install(source, target)
    try fm.removeItem(at: journal(target))
    try fm.createSymbolicLink(at: journal(target), withDestinationURL: root.appendingPathComponent("missing-record"))
    check("dangling journal preserves recovery stage", BundleReplacement.beginLaunch(at: target) == .needsAttention && stages(target).contains { label($0) == "old" })
}
do {
    let (source, target) = try scene("loaded-old")
    for bundle in [source, target] {
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: args[0]), to: bundle.appendingPathComponent("Contents/MacOS/Check"))
    }
    let process = Process()
    process.executableURL = target.appendingPathComponent("Contents/MacOS/Check")
    process.arguments = ["child", "loaded-old", source.path, target.path]
    try process.run()
    try install(source, target)
    try Data().write(to: source.appendingPathComponent("continue"))
    process.waitUntilExit()
    check("old executable cannot certify new bundle at same path", process.terminationStatus == 0 && stages(target).contains { label($0) == "old" })
}
for step in ["afterLaunchJournal", "beforeRollback", "afterRollback", "afterHealthyJournal", "beforeCleanup", "afterCleanup"] {
    let (source, target) = try scene(step)
    try install(source, target)
    let operation: String
    if step == "beforeRollback" || step == "afterRollback" {
        check("launch crashes before \(step)", try child("launch", source, target) == SIGKILL)
        operation = "rollback"
    } else if step == "afterLaunchJournal" { operation = "launch" }
    else { operation = "healthy" }
    check("process killed at \(step)", try child(operation, source, target, step) == SIGKILL)
    let recovered = BundleReplacement.beginLaunch(at: target)
    let healthy = operation == "healthy"
    check("recovery after \(step) retains correct bundle", label(target) == (healthy ? "new" : "old")
          && (recovered == .unchanged || recovered == .rolledBack) && stages(target).isEmpty)
    check("repeated recovery after \(step) is inert", BundleReplacement.beginLaunch(at: target) == .unchanged)
}
do {
    let (source, target) = try scene("unwritable")
    let parent = target.deletingLastPathComponent()
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
    do { try install(source, target); check("write failure refuses update", false) }
    catch { check("write failure preserves errno and working app", (error as NSError).domain == NSPOSIXErrorDomain && label(target) == "old") }
}
do {
    let (source, target) = try scene("unavailable")
    let obstruction = target.deletingLastPathComponent().appendingPathComponent("file")
    try Data("unrelated".utf8).write(to: obstruction)
    do { try install(source, obstruction.appendingPathComponent("Vane.app")); check("unavailable destination refuses update", false) }
    catch { check("unavailable destination preserves working app", label(target) == "old" && (try? String(contentsOf: obstruction, encoding: .utf8)) == "unrelated") }
}
for kind in ["malformed", "outside-stage", "wrong-target", "wrong-volume", "legacy-unverified"] {
    let (source, target) = try scene(kind)
    try install(source, target)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: journal(target))) as! [String: Any]
    switch kind {
    case "outside-stage": record["stageName"] = "../unrelated.app"
    case "wrong-target": record["targetPath"] = "/Applications/Vane.app"
    case "wrong-volume": record["volumeID"] = 0
    case "legacy-unverified":
        for key in ["targetPath", "volumeID", "oldDigest", "newDigest"] { record.removeValue(forKey: key) }
    default: break
    }
    try (kind == "malformed" ? Data("{".utf8) : JSONSerialization.data(withJSONObject: record)).write(to: journal(target))
    for _ in 0..<2 { check("\(kind) recovery refuses ambiguous transaction", BundleReplacement.beginLaunch(at: target) == .needsAttention && label(target) == "new" && stages(target).contains { label($0) == "old" }) }
    do { try install(source, target); check("\(kind) cannot overwrite recovery on retry", false) }
    catch { check("\(kind) cannot overwrite recovery on retry", stages(target).contains { label($0) == "old" }) }
}
do {
    let (source, target) = try scene("legacy-verified")
    try install(source, target)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: journal(target))) as! [String: Any]
    for key in ["targetPath", "volumeID", "oldDigest", "newDigest"] { record.removeValue(forKey: key) }
    try JSONSerialization.data(withJSONObject: record).write(to: journal(target))
    let result = BundleReplacement.beginLaunch(at: target, verifyRecovery: { ["old", "new"].contains(label($0) ?? "") })
    check("verified legacy journal migrates without deleting backup", result == .waitingForHealth && stages(target).contains { label($0) == "old" })
    BundleReplacement.markHealthy(at: target)
    check("migrated legacy journal completes", !fm.fileExists(atPath: journal(target).path) && label(target) == "new")
}
do {
    let (source, target) = try scene("finder-icon")
    try install(source, target)
    _ = BundleReplacement.beginLaunch(at: target)
    try Data("Finder custom icon".utf8).write(to: target.appendingPathComponent("Icon\r"))
    BundleReplacement.markHealthy(at: target)
    check("supported Finder icon stamp does not prevent healthy launch", !fm.fileExists(atPath: journal(target).path) && label(target) == "new")
}
do {
    let (source, target) = try scene("legacy-damaged-new")
    try install(source, target)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: journal(target))) as! [String: Any]
    for key in ["targetPath", "volumeID", "oldDigest", "newDigest"] { record.removeValue(forKey: key) }
    try JSONSerialization.data(withJSONObject: record).write(to: journal(target))
    try Data("incomplete".utf8).write(to: target.appendingPathComponent("fixture"))
    check("legacy damaged replacement restores independently verified old bundle", BundleReplacement.beginLaunch(at: target, verifyRecovery: { label($0) == "old" }) == .rolledBack && label(target) == "old")
}
do {
    let (source, target) = try scene("unrelated-recorded-backup")
    try Data("unrelated".utf8).write(to: target.appendingPathComponent("fixture"))
    // Model a forged/stale record whose inode and digest do match an unrelated app.
    try install(source, target)
    _ = BundleReplacement.beginLaunch(at: target, verifyRecovery: { label($0) == "new" }, verifyPrevious: { label($0) == "old" })
    BundleReplacement.markHealthy(at: target, verifyRecovery: { label($0) == "new" }, verifyPrevious: { label($0) == "old" })
    let result = BundleReplacement.beginLaunch(at: target, processAlive: { _, _, _ in false },
        verifyRecovery: { label($0) == "new" }, verifyPrevious: { label($0) == "old" })
    check("matched inode/digest cannot authorize unrelated rollback", result == .needsAttention && label(target) == "new"
          && fm.fileExists(atPath: journal(target).path) && stages(target).contains { label($0) == "unrelated" })
}
do {
    let (source, target) = try scene("different-verification-policies")
    try install(source, target)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: journal(target))) as! [String: Any]
    for key in ["targetPath", "volumeID", "oldDigest", "newDigest"] { record.removeValue(forKey: key) }
    try JSONSerialization.data(withJSONObject: record).write(to: journal(target))
    try Data("incomplete".utf8).write(to: target.appendingPathComponent("fixture"))
    let result = BundleReplacement.beginLaunch(at: target, verifyRecovery: { label($0) == "new" }, verifyPrevious: { label($0) == "old" })
    check("legacy rollback respects separately accepted previous-build policy", result == .rolledBack && label(target) == "old")
}
do {
    let (source, target) = try scene("never-bootstrapped")
    try install(source, target)
    let result = try BundleReplacement.restoreUnlaunched(at: target, verifyPrevious: { label($0) == "old" })
    check("pre-bootstrap relaunch failure restores complete old bundle", result == .rolledBack && label(target) == "old" && stages(target).isEmpty)
    check("repeated external recovery is inert", try BundleReplacement.restoreUnlaunched(at: target, verifyPrevious: { _ in false }) == .unchanged)
}
do {
    let (source, target) = try scene("bootstrapped-owner")
    try install(source, target)
    check("prepared transaction has no claimed launch", BundleReplacement.hasPendingRecord(at: target) && !BundleReplacement.launchClaimed(at: target, by: getpid()))
    _ = BundleReplacement.beginLaunch(at: target)
    check("supervisor recognizes exact bootstrap owner", BundleReplacement.launchClaimed(at: target, by: getpid()))
    check("stale owner cannot certify a different process", !BundleReplacement.launchClaimed(at: target, by: Int32.max))
    let saved = try Data(contentsOf: journal(target))
    var missingStart = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
    missingStart.removeValue(forKey: "launchStart")
    try JSONSerialization.data(withJSONObject: missingStart).write(to: journal(target))
    check("unavailable start times never certify bootstrap ownership", !BundleReplacement.launchClaimed(at: target, by: getpid(), observeStart: { _ in nil }))
    try saved.write(to: journal(target))
    let result = try BundleReplacement.restoreUnlaunched(at: target, verifyPrevious: { _ in true })
    check("external helper cannot take over bootstrapped launch", result == .unchanged && label(target) == "new" && stages(target).contains { label($0) == "old" })
}
do {
    let (source, target) = try scene("unrelated-unlaunched")
    try install(source, target)
    let result = try BundleReplacement.restoreUnlaunched(at: target, verifyPrevious: { _ in false })
    check("external helper refuses unverified previous bundle", result == .needsAttention && label(target) == "new" && stages(target).contains { label($0) == "old" })
}
do {
    let (source, target) = try scene("supervised-restoration")
    try install(source, target)
    let witness = BundleReplacement.launchWitness(at: target)!
    check("prepared witness cannot certify completed replacement", !BundleReplacement.hasCompletedReplacement(at: target, witness: witness, verifyReplacement: { _ in true }))
    check("prepared witness cannot authorize reopening old", !BundleReplacement.isRestoredPrevious(at: target, witness: witness, verifyPrevious: { _ in true }))
    _ = try BundleReplacement.restoreUnlaunched(at: target, verifyPrevious: { label($0) == "old" })
    check("completed rollback permits only its captured verified previous inode", BundleReplacement.isRestoredPrevious(at: target, witness: witness, verifyPrevious: { label($0) == "old" }))
    check("witness cannot override previous signature rejection", !BundleReplacement.isRestoredPrevious(at: target, witness: witness, verifyPrevious: { _ in false }))
    try Data("damaged".utf8).write(to: target.appendingPathComponent("fixture"))
    check("witness cannot reopen damaged restored bundle", !BundleReplacement.isRestoredPrevious(at: target, witness: witness, verifyPrevious: { _ in true }))
}
do {
    let (source, target) = try scene("supervised-health-cleanup")
    try install(source, target)
    let witness = BundleReplacement.launchWitness(at: target)!
    _ = BundleReplacement.beginLaunch(at: target)
    BundleReplacement.markHealthy(at: target, fault: { $0 == .beforeCleanup })
    check("durable health releases supervisor despite interrupted cleanup", BundleReplacement.hasPendingRecord(at: target) && BundleReplacement.hasCompletedReplacement(at: target, witness: witness, verifyReplacement: { label($0) == "new" }))
    check("health witness still requires independent signature", !BundleReplacement.hasCompletedReplacement(at: target, witness: witness, verifyReplacement: { _ in false }))
    let (_, other) = try scene("supervised-wrong-target")
    check("health witness cannot certify another target", !BundleReplacement.hasCompletedReplacement(at: other, witness: witness, verifyReplacement: { _ in true }))
}
check("live originating process delays detached worker", BundleReplacement.parentExit(123, start: 10, observeStart: { _ in 10 }) == .waiting)
check("reused parent PID does not delay original exit", BundleReplacement.parentExit(123, start: 10, observeStart: { _ in 11 }) == .exited)
check("unavailable live parent observation refuses relaunch", BundleReplacement.parentExit(123, start: 10, observeStart: { _ in nil }, exists: { _ in true }) == .unavailable)
check("confirmed absent parent permits worker launch", BundleReplacement.parentExit(123, start: 10, observeStart: { _ in nil }, exists: { _ in false }) == .exited)
do {
    let (source, target) = try scene("legacy-supervised-restoration")
    try install(source, target)
    _ = BundleReplacement.beginLaunch(at: target)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: journal(target))) as! [String: Any]
    for key in ["targetPath", "volumeID", "oldDigest", "newDigest"] { record.removeValue(forKey: key) }
    try JSONSerialization.data(withJSONObject: record).write(to: journal(target))
    check("legacy witness requires independent bundle verifiers", BundleReplacement.launchWitness(at: target) == nil)
    let witness = BundleReplacement.launchWitness(at: target, verifyReplacement: { label($0) == "new" }, verifyPrevious: { label($0) == "old" })!
    check("legacy witness cannot certify pending launch", !BundleReplacement.hasCompletedReplacement(at: target, witness: witness, verifyReplacement: { _ in true }))
    let result = BundleReplacement.beginLaunch(at: target, processAlive: { _, _, _ in false }, verifyRecovery: { label($0) == "new" }, verifyPrevious: { label($0) == "old" })
    check("legacy selfrollback retains witnessed complete previous launch", result == .rolledBack && BundleReplacement.isRestoredPrevious(at: target, witness: witness, verifyPrevious: { label($0) == "old" }))
}
print("\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
