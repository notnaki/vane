import AppKit
import Darwin
import WebKit

/// Optional handshake with scripts/profile-resize-motion.py. No profiling work or
/// extra wait runs without the explicit private-directory/token contract. File IO
/// occurs outside the measured interval, and sampler completion is awaited only
/// after capture stops. Profiled timing is diagnostic, never a cadence acceptance.
@MainActor final class ResizeMotionProfile {
    private struct ProcessOwner: Codable, Equatable {
        let pid: Int32
        let start: UInt64
        let path: String

        @MainActor init(_ identity: NativeFixtureDiagnostics.Identity) {
            pid = identity.pid
            start = identity.start
            path = NativeFixtureRetirement.canonical(identity.path)
        }
    }

    private struct Record: Codable {
        let schema: Int
        let token: String
        let sidebar: Bool
        let readyAt: Double
        let testBundlePath: String
        let ui: ProcessOwner
        let content: ProcessOwner
        var began: Double?
        var ended: Double?
        var ownershipHeld: Bool?
    }
    private struct Contract: Decodable { let schema: Int; let token: String }
    private struct Release: Decodable { let schema: Int; let token: String; let status: Int }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private let directory: URL
    private var record: Record

    private init(directory: URL, record: Record) {
        self.directory = directory
        self.record = record
    }

    static func begin(environment: [String: String], web: WKWebView, sidebar: Bool) throws -> ResizeMotionProfile? {
        guard environment["VANE_RESIZE_PROFILE_DIR"] != nil || environment["VANE_RESIZE_PROFILE_TOKEN"] != nil else { return nil }
        guard let path = environment["VANE_RESIZE_PROFILE_DIR"],
              let token = environment["VANE_RESIZE_PROFILE_TOKEN"],
              token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              path.hasPrefix("/"), NativeFixtureRetirement.canonical(path) == path else {
            throw Failure("Invalid resize profile contract")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw Failure("Profile directory is not private")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let contract = try JSONDecoder().decode(Contract.self, from: readPrivate(directory.appendingPathComponent("contract.json")))
        guard contract.schema == 1, contract.token == token,
              let ui = NativeFixtureDiagnostics.identity(getpid()),
              let content = NativeFixtureDiagnostics.ownedContentIdentity(for: web) else {
            throw Failure("Profile contract or live fixture identity unavailable")
        }
        let record = Record(schema: 1, token: token, sidebar: sidebar, readyAt: CACurrentMediaTime(),
                            testBundlePath: NativeFixtureRetirement.canonical(Bundle(for: WindowResizeResponsiveMotionTests.self).bundleURL.path),
                            ui: ProcessOwner(ui), content: ProcessOwner(content))
        let result = ResizeMotionProfile(directory: directory, record: record)
        try result.write("ready.json")
        NativeFixtureDiagnostics.emit("RESIZE_PROFILE diagnosticOnly=true uiPID=\(ui.pid) uiStart=\(ui.start) contentPID=\(content.pid) contentStart=\(content.start)")
        return result
    }

    func finish(began: Double, ended: Double, web: WKWebView) async throws {
        record.began = began
        record.ended = ended
        record.ownershipHeld = NativeFixtureDiagnostics.identity(getpid()).map(ProcessOwner.init) == record.ui
            && NativeFixtureDiagnostics.ownedContentIdentity(for: web).map(ProcessOwner.init) == record.content
        try write("finished.json")
        let release = directory.appendingPathComponent("release.json")
        let deadline = ContinuousClock.now + .seconds(25)
        // Keep only this fixture's owners alive until their sampler children exit.
        // This wait starts after the motion interval and SCStream have both ended.
        while !FileManager.default.fileExists(atPath: release.path) {
            guard ContinuousClock.now < deadline else { throw Failure("Owned profile collector did not release the fixture") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let completion = try JSONDecoder().decode(Release.self, from: Self.readPrivate(release))
        guard completion.schema == 1, completion.token == record.token, completion.status == 0,
              record.ownershipHeld == true else { throw Failure("Owned profile collection failed") }
    }

    private func write(_ name: String) throws {
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(record).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(name))
    }

    private static func readPrivate(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure("Cannot open profile contract") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_size <= 16_384 else {
            throw Failure("Profile contract is not a bounded private regular file")
        }
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 16_385) ?? Data()
    }
}
