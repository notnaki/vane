import AppKit
import Security
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--restart" {
    let target = URL(fileURLWithPath: CommandLine.arguments[2])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", UpdateRelaunch.script(parentPID: Int32.max, target: target,
        isolatedDirectory: ProcessInfo.processInfo.environment["VANE_DATA_DIR"],
        recoveryTool: target.appendingPathComponent("Contents/XPCServices/io.github.notnaki.vane.UpdateInstaller.xpc/Contents/MacOS/VaneUpdateInstaller"))]
    try process.run(); process.waitUntilExit()
    exit(process.terminationStatus)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--quit" {
    _ = NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[2])!)?.terminate()
    exit(0)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let target = URL(fileURLWithPath: CommandLine.arguments[2])
// Native launch tests use locally signed bundles. Real Developer ID + notarization is
// tested separately by test-update-installer; this predicate is not distribution trust.
try BundleReplacement.install(source: source, at: target, keepPrevious: false,
    verify: { bundle in
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code,
            SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }, mayReplaceTarget: { _ in true })
