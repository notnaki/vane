import AppKit
import Security
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--restart" {
    let target = URL(fileURLWithPath: CommandLine.arguments[2])
    try UpdateInstaller.scheduleRelaunch(target: target,
        isolatedDirectory: ProcessInfo.processInfo.environment["VANE_DATA_DIR"]!)
    exit(0)
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
