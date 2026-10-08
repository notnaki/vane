import Foundation

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--relaunch-after-exit",
   let pid = Int32(CommandLine.arguments[3]), pid > 0,
   let start = UInt64(CommandLine.arguments[4]), start > 0 {
    var unavailableSince: Date?
    parentWait: while true {
        switch BundleReplacement.parentExit(pid, start: start) {
        case .waiting:
            unavailableSince = nil
            Thread.sleep(forTimeInterval: 0.1)
        case .exited: break parentWait
        case .unavailable:
            // An exited-but-unreaped parent can briefly retain its PID. Give the
            // kernel/launcher time to confirm absence; uncertainty never permits launch.
            unavailableSince = unavailableSince ?? Date()
            if Date().timeIntervalSince(unavailableSince!) >= 5 {
                NSLog("[vane] parent process observation unavailable; refused relaunch")
                exit(1)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    InstallerRelaunch.relaunch(target: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--relaunch" {
    InstallerRelaunch.relaunch(target: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let service = InstallerService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
