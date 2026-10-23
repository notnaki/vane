import Foundation
import Darwin

let args = CommandLine.arguments
let fm = FileManager.default
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL"): \(name)")
    if !ok { exit(1) }
}
if args[1] == "--access" {
    for path in args.dropFirst(2) {
        let root = URL(fileURLWithPath: path)
        check("browser reads Applications canary", (try? String(contentsOf: root.appendingPathComponent("read"), encoding: .utf8)) == "canary")
        do {
            try Data("unexpected".utf8).write(to: root.appendingPathComponent("write"))
            check("browser denied Applications file creation", false)
        } catch { check("browser denied Applications file creation", true) }
        do {
            try fm.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: false)
            check("browser denied Applications directory creation", false)
        } catch { check("browser denied Applications directory creation", true) }
        do {
            try Data("unexpected".utf8).write(to: root.appendingPathComponent("read"))
            check("browser denied existing Applications file modification", false)
        } catch { check("browser denied existing Applications file modification", true) }
        do {
            try fm.removeItem(at: root.appendingPathComponent("read"))
            check("browser denied existing Applications file deletion", false)
        } catch { check("browser denied existing Applications file deletion", true) }
    }
    exit(0)
}
let target = Bundle.main.bundleURL
if args[1] == "--wrong-target" {
    let other = target.deletingLastPathComponent().appendingPathComponent("other/Vane.app")
    for health in [false, true] {
        do {
            if health { _ = try UpdateInstaller.markHealthy(target: other) }
            else { _ = try UpdateInstaller.beginLaunch(target: other) }
            check("helper rejects recovery for another executable", false)
        } catch {
            check("helper rejects recovery for another executable", error.localizedDescription == "Invalid update recovery destination or caller")
        }
    }
    exit(0)
}
if args[1] == "--unauthorized" {
    do {
        _ = try UpdateInstaller.beginLaunch(target: target)
        check("wrong signer identity rejected before policy", false)
    } catch {
        check("wrong signer identity rejected before policy", error.localizedDescription != "Invalid update recovery destination or caller")
    }
    exit(0)
}
if args[1] == "--displaced" {
    let ready = URL(fileURLWithPath: args[2]), go = URL(fileURLWithPath: args[3])
    try Data("ready".utf8).write(to: ready)
    let deadline = Date().addingTimeInterval(20)
    while !fm.fileExists(atPath: go.path), Date() < deadline { usleep(10000) }
    check("displaced caller received test signal", fm.fileExists(atPath: go.path))
    for health in [false, true] {
        do {
            if health { _ = try UpdateInstaller.markHealthy(target: target) }
            else { _ = try UpdateInstaller.beginLaunch(target: target) }
            check("displaced old executable rejected", false)
        } catch { check("displaced old executable rejected", true) }
    }
    exit(0)
}
let record = target.deletingLastPathComponent().appendingPathComponent(".Vane.app.vane-transaction.json")
if args[1] == "--recover-orphans" {
    check("restored app can finish deferred recovery cleanup", try UpdateInstaller.beginLaunch(target: target) == .unchanged)
    let stages = try fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(".Vane.app.vane-stage-") }
    check("restored app removes deferred failed stage", stages.isEmpty)
    exit(0)
}
if args[1] == "--crash" {
    check("browser claims launch before simulated crash", try UpdateInstaller.beginLaunch(target: target) == .waitingForHealth)
    exit(0) // The next process observes this dead claim; avoid an OS crash report.
}
if args[1] == "--rollback" {
    check("helper rolls back failed browser launch", try UpdateInstaller.beginLaunch(target: target) == .rolledBack)
    check("rollback durably removes pending record", !fm.fileExists(atPath: record.path))
    let info = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
    let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as! [String: Any]
    check("rollback restored previous signed version", plist["CFBundleShortVersionString"] as? String == "1.0.0")
    exit(0)
}
check("unclaimed browser cannot confirm health", try !UpdateInstaller.markHealthy(target: target))
check("browser claims its own launch through XPC", try UpdateInstaller.beginLaunch(target: target) == .waitingForHealth)
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
check("XPC journal records browser PID", json["launchPID"] as? Int32 == getpid())
check("XPC journal records browser start", (json["launchStart"] as? UInt64 ?? 0) > 0)
check("helper confirms browser health and cleans transaction", try UpdateInstaller.markHealthy(target: target))
check("browser observes read-only completed transaction", !fm.fileExists(atPath: record.path))
