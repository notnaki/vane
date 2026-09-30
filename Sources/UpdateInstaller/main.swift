import Foundation

let service = InstallerService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
