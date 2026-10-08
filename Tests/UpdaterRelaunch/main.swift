import Foundation
import Darwin
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("vane-relaunch-check-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let receipt = root.appendingPathComponent("receipt")
let opener = root.appendingPathComponent("fake open")
// The controlled opener records literal arguments and can simulate LaunchServices failure.
try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" >> '\(receipt.path)'\nexit 1\n".utf8).write(to: opener)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
let verifier = root.appendingPathComponent("verify")
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: verifier)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: verifier.path)
let target = root.appendingPathComponent("Vane '$(touch should-not-exist)'.app")
let directory = root.appendingPathComponent("isolated data ' with spaces")
let helper = Process()
helper.executableURL = URL(fileURLWithPath: "/bin/sh")
helper.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: target,
    isolatedDirectory: directory.path, opener: opener, verifier: verifier)]
try helper.run(); helper.waitUntilExit()
let entries = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").map(String.init)
let expected = ["-n", "--env", "VANE_DATA_DIR=" + directory.path, target.path]
let ok = helper.terminationStatus == 1 && entries == Array(repeating: expected, count: 3).flatMap { $0 }
    && !fm.fileExists(atPath: "should-not-exist")
print("\(ok ? "PASS" : "FAIL"): failed relaunch retries literal target and preserves isolated data directory")
try fm.removeItem(at: receipt)
try Data("#!/bin/sh\nexit 1\n".utf8).write(to: verifier)
let rejected = Process()
rejected.executableURL = URL(fileURLWithPath: "/bin/sh")
rejected.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: target,
    isolatedDirectory: directory.path, opener: opener, verifier: verifier)]
try rejected.run(); rejected.waitUntilExit()
let refused = rejected.terminationStatus != 0 && !fm.fileExists(atPath: receipt.path)
print("\(refused ? "PASS" : "FAIL"): relaunch refuses a target that fails Vane signature identity verification")
let recovery = root.appendingPathComponent("recover")
let recovered = root.appendingPathComponent("recovered")
try Data("#!/bin/sh\nprintf '%s\n' \"$@\" > '\(recovered.path)'\nexit 1\n".utf8).write(to: recovery)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recovery.path)
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: verifier)
let unlaunched = Process()
unlaunched.executableURL = URL(fileURLWithPath: "/bin/sh")
unlaunched.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: target,
    isolatedDirectory: directory.path, opener: opener, verifier: verifier, recoveryTool: recovery)]
try unlaunched.run(); unlaunched.waitUntilExit()
let recoveryArgs = (try String(contentsOf: recovered, encoding: .utf8)).split(separator: "\n").map(String.init)
let callback = unlaunched.terminationStatus == 1 && recoveryArgs == ["--relaunch", target.path] && !fm.fileExists(atPath: receipt.path)
print("\(callback ? "PASS" : "FAIL"): failed launch invokes recovery helper without reporting success")
try fm.removeItem(at: recovered)
try Data("#!/bin/sh\nexit 1\n".utf8).write(to: verifier)
let untrusted = Process()
untrusted.executableURL = URL(fileURLWithPath: "/bin/sh")
untrusted.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: target,
    isolatedDirectory: directory.path, verifier: verifier, recoveryTool: recovery)]
try untrusted.run(); untrusted.waitUntilExit()
let guarded = untrusted.terminationStatus != 0 && !fm.fileExists(atPath: recovered.path)
print("\(guarded ? "PASS" : "FAIL"): unverified replacement cannot execute its recovery helper")
// Exercise the real codesign parser: -R needs '=' for an inline requirement.
let signed = root.appendingPathComponent("signed")
try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: signed)
let signer = Process()
signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
signer.arguments = ["--force", "--sign", "-", "--identifier", "io.github.notnaki.vane", signed.path]
try signer.run(); signer.waitUntilExit()
let real = Process()
real.executableURL = URL(fileURLWithPath: "/bin/sh")
real.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: signed,
    isolatedDirectory: nil, opener: URL(fileURLWithPath: "/usr/bin/true"))]
try real.run(); real.waitUntilExit()
let valid = signer.terminationStatus == 0 && real.terminationStatus == 0
print("\(valid ? "PASS" : "FAIL"): real codesign accepts the relaunch identity requirement")
let directExecutable = root.appendingPathComponent("direct app ' executable")
let directReceipt = root.appendingPathComponent("direct environment")
try Data("#!/bin/sh\nprintf '%s' \"$VANE_DATA_DIR\" > '\(directReceipt.path)'\n".utf8).write(to: directExecutable)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directExecutable.path)
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: verifier)
let direct = Process()
direct.executableURL = URL(fileURLWithPath: "/bin/sh")
direct.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: target,
    isolatedDirectory: directory.path, verifier: verifier, directExecutable: directExecutable)]
try direct.run(); direct.waitUntilExit()
let directValue = try String(contentsOf: directReceipt, encoding: .utf8)
let preserved = direct.terminationStatus == 0 && directValue == directory.path
print("\(preserved ? "PASS" : "FAIL"): isolated rollback starts verified executable with literal data directory")
exit(ok && refused && callback && guarded && valid && preserved ? 0 : 1)
