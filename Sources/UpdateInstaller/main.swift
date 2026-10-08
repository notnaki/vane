import Foundation

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--relaunch" {
    InstallerRelaunch.relaunch(target: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let service = InstallerService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
