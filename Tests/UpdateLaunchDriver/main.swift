import Foundation

// Only fixture setup is unsandboxed. The browser clients perform every recovery/health
// mutation through the production authenticated XPC service.
try BundleReplacement.install(source: URL(fileURLWithPath: CommandLine.arguments[1]),
    at: URL(fileURLWithPath: CommandLine.arguments[2]), keepPrevious: false,
    verify: { _ in true }, mayReplaceTarget: { _ in true })
