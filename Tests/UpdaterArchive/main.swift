import Foundation
import Darwin

let arguments = CommandLine.arguments
let zip = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])
var limits = UpdateArchive.Limits()
if arguments.count > 3 {
    switch arguments[3] {
    case "compressed": limits.compressedBytes = 100
    case "runtime": limits.seconds = 0.005
    case "total": limits.totalBytes = 100
    case "file": limits.fileBytes = 100
    case "entries": limits.entries = 2
    case "path": limits.pathBytes = 20
    case "depth": limits.pathComponents = 2
    case "deadline": limits.seconds = 0
    default: break
    }
}
let existing = arguments.last == "existing"
if existing {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("preserve".utf8).write(to: destination.appendingPathComponent("marker"))
}
do {
    try UpdateArchive.extract(zip: zip, to: destination, limits: limits)
    print("ACCEPT")
} catch {
    print("REJECT: \(error)")
    if existing {
        guard (try? Data(contentsOf: destination.appendingPathComponent("marker"))) == Data("preserve".utf8) else { exit(2) }
    } else if FileManager.default.fileExists(atPath: destination.path) {
        fputs("FAIL: partial destination remains\n", stderr)
        exit(2)
    }
    exit(1)
}
