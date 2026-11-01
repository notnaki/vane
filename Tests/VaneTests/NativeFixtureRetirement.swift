import AppKit
import Darwin
import WebKit
import XCTest
@testable import vane

/// Test-only ownership handoff. The wrapper keeps this manifest outside the scratch
/// directory and waits for its producer hosts to exit before starting retirement.
@MainActor enum NativeFixtureRetirement {
    struct Host: Codable, Equatable, Sendable {
        let pid: Int32
        let start: UInt64
        let path: String
        let processName: String
        let bundleIdentifier: String
        let testBundlePath: String
    }
    struct Entry: Codable, Equatable, Sendable {
        let profileID: UUID
        let dataDirectory: String
        let storeID: UUID
    }
    struct Manifest: Codable, Sendable {
        let schema: Int
        let token: String
        let host: Host
        var profiles: [Entry]
    }
    struct Contract: Codable { let schema: Int; let token: String }
    struct Completion: Codable { let schema: Int; let token: String; let retiredIDs: [String] }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private final class BundleMarker: NSObject {}
    private static var current: Manifest?
    private static var registrationFailed = false
    private static let directoryKey = "VANE_NATIVE_FIXTURE_MANIFEST_DIR"
    private static let tokenKey = "VANE_NATIVE_FIXTURE_MANIFEST_TOKEN"
    private static let phaseKey = "VANE_NATIVE_FIXTURE_RETIREMENT_PHASE"

    static func registerHostIfEnabled() {
        guard !registrationFailed else { return }
        do {
            guard let (root, token) = try contract() else { return }
            guard ProcessInfo.processInfo.environment[phaseKey] == nil else {
                throw Failure("Normal fixture executed during the retirement-only phase")
            }
            if current == nil {
                current = Manifest(schema: 1, token: token, host: try host(), profiles: [])
                try write(current!, to: hostFile(current!.host, root: root))
            }
        } catch {
            registrationFailed = true
            NativeFixtureDiagnostics.emit("retirement contract rejected: \(error)")
            XCTFail("Native fixture retirement contract rejected: \(error)")
        }
    }

    /// False means the ordinary in-process cleanup path remains mandatory.
    static func recordIfEnabled(profile: UUID, directory: String) throws -> Bool {
        guard let (root, token) = try contract() else { return false }
        guard ProcessInfo.processInfo.environment[phaseKey] == nil else {
            throw Failure("A normal fixture cannot defer cleanup from the retirement-only host")
        }
        let entry = Entry(profileID: profile, dataDirectory: directory,
                          storeID: try XCTUnwrap(ProfileManager.dataStoreIdentifier(for: profile, dataDirectory: directory)))
        try validate(entry)
        guard root.path != directory, !root.path.hasPrefix(directory + "/"), !directory.hasPrefix(root.path + "/") else {
            throw Failure("Retirement manifest must be outside the fixture scratch directory")
        }
        if current == nil { current = Manifest(schema: 1, token: token, host: try host(), profiles: []) }
        guard current!.token == token else { throw Failure("Retirement contract changed during a test host") }
        if !current!.profiles.contains(entry) { current!.profiles.append(entry) }
        try write(current!, to: hostFile(current!.host, root: root))
        return true
    }

    static func validate(_ entry: Entry) throws {
        guard entry.profileID != ProfileManager.defaultID, entry.profileID != Profile.incognito.id,
              entry.dataDirectory.hasPrefix("/"), !entry.dataDirectory.hasPrefix("//"), entry.dataDirectory != "/",
              !entry.dataDirectory.contains("\0"),
              URL(fileURLWithPath: entry.dataDirectory).standardizedFileURL.path == entry.dataDirectory,
              ProfileManager.dataStoreIdentifier(for: entry.profileID, dataDirectory: entry.dataDirectory) == entry.storeID else {
            throw Failure("Manifest contains a non-disposable profile or mismatched isolated backend")
        }
    }

    static func validate(_ manifest: Manifest, token: String, matching expected: Host) throws {
        guard manifest.schema == 1, manifest.token == token,
              manifest.host.pid > 0, manifest.host.start > 0,
              canonical(manifest.host.path) == canonical(expected.path),
              manifest.host.processName == expected.processName,
              manifest.host.bundleIdentifier == expected.bundleIdentifier,
              canonical(manifest.host.testBundlePath) == canonical(expected.testBundlePath),
              manifest.host.testBundlePath.hasSuffix(".xctest"), manifest.profiles.count <= 4_096 else {
            throw Failure("Retirement must use the same XCTest executable, bundle, and WebKit namespace")
        }
        // Validate the complete record before any native deletion is allowed.
        for entry in manifest.profiles { try validate(entry) }
    }

    static func retireManifest() async throws {
        guard ProcessInfo.processInfo.environment[phaseKey] == "cleanup" else {
            throw XCTSkip("Retirement runs only in the wrapper's fresh host after the primary host exits")
        }
        guard let (root, token) = try contract() else { throw Failure("Retirement requires a wrapper contract") }
        let ownHost = try host()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let manifests = try files.filter { $0.lastPathComponent.hasPrefix("host-") && $0.pathExtension == "json" }.map { file in
            let record = try JSONDecoder().decode(Manifest.self, from: readPrivate(file))
            guard file.lastPathComponent == hostFile(record.host, root: root).lastPathComponent else { throw Failure("Host manifest filename mismatch") }
            try validate(record, token: token, matching: ownHost)
            try requireExited(record.host)
            return record
        }
        guard manifests.count <= 256 else { throw Failure("Too many test host manifests") }
        if files.contains(where: { $0.lastPathComponent == "cleanup-host.json" }) {
            let prior = try JSONDecoder().decode(Manifest.self, from: readPrivate(root.appendingPathComponent("cleanup-host.json")))
            try validate(prior, token: token, matching: ownHost)
            try requireExited(prior.host)
        }
        let allowed = Set(["contract.json", "cleanup-host.json", "complete.json"] + manifests.map { hostFile($0.host, root: root).lastPathComponent })
        guard files.allSatisfy({ allowed.contains($0.lastPathComponent) }) else { throw Failure("Unexpected file in private retirement manifest directory") }
        let identifiers = Set(manifests.flatMap(\.profiles).map(\.storeID)).sorted { $0.uuidString < $1.uuidString }
        try write(Manifest(schema: 1, token: token, host: ownHost, profiles: []), to: root.appendingPathComponent("cleanup-host.json"))
        _ = NSApplication.shared
        WebKitStartup.prepare()
        // Full suites retire hundreds of IDs after the primary host has exited.
        let deadline = ContinuousClock.now + .seconds(60)
        var lastObserved: Set<UUID>?
        do {
            try await retireOwned(Set(identifiers), registered: {
                let value = try await registeredIDs(deadline: deadline)
                lastObserved = value
                return value
            }, remove: { identifier in
                while true {
                    guard let error = try await remove(identifier, deadline: deadline) else { return }
                    let native = error as NSError
                    guard native.domain == "WKWebSiteDataStore", native.code == 1,
                          native.localizedDescription.contains("Data store is in use"), ContinuousClock.now < deadline else {
                        throw Failure("Owned backend \(identifier) removal failed: \(native.domain)/\(native.code)")
                    }
                    // Settle only an observed in-use result; never delay a normal removal.
                    try await Task.sleep(for: .milliseconds(100))
                }
            })
            try write(Completion(schema: 1, token: token, retiredIDs: identifiers.map { $0.uuidString.lowercased() }.sorted()),
                      to: root.appendingPathComponent("complete.json"))
            NativeFixtureDiagnostics.emit("retirement complete: \(identifiers.count) exact owned backends absent")
        } catch {
            let remaining = lastObserved.map { String(describing: $0.intersection(identifiers).map(\.uuidString).sorted()) } ?? "unavailable"
            NativeFixtureDiagnostics.emit("retirement failed: \(error); lastObservedRemainingOwnedIDs=\(remaining); requestedOwnedIDs=\(identifiers.map(\.uuidString))")
            throw error
        }
    }

    /// The deletion plan is explicit ownership intersected with the existing registry.
    /// A fresh registry read verifies absence and preservation after every removal.
    static func retireOwned(_ identifiers: Set<UUID>, registered: () async throws -> Set<UUID>, remove: (UUID) async throws -> Void) async throws {
        // An empty manifest cannot delete anything. Comparing global registry
        // snapshots here would attribute another host's retirement to this no-op.
        guard !identifiers.isEmpty else { return }
        let before = try await registered()
        for identifier in identifiers.intersection(before).sorted(by: { $0.uuidString < $1.uuidString }) {
            try await remove(identifier)
            let afterRemoval = try await registered()
            guard !afterRemoval.contains(identifier) else { throw Failure("Owned backend \(identifier) remains registered after removal") }
        }
        let after = try await registered()
        guard after.intersection(identifiers).isEmpty else { throw Failure("Owned backends remain registered: \(after.intersection(identifiers))") }
        guard before.subtracting(identifiers).isSubset(of: after) else { throw Failure("Unrelated registered backends disappeared during owned retirement") }
    }

    private static func host() throws -> Host {
        guard let identity = NativeFixtureDiagnostics.identity(getpid()) else { throw Failure("Cannot identify this XCTest host") }
        return Host(pid: identity.pid, start: identity.start, path: canonical(identity.path),
                    processName: ProcessInfo.processInfo.processName, bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                    testBundlePath: canonical(Bundle(for: BundleMarker.self).bundleURL.path))
    }
    private static func requireExited(_ host: Host) throws {
        if let observed = NativeFixtureDiagnostics.identity(host.pid) {
            guard observed.start != host.start else { throw Failure("Owned test host has not exited: pid=\(host.pid), start=\(host.start)") }
        } else {
            errno = 0
            guard kill(host.pid, 0) == -1, errno == ESRCH else { throw Failure("Cannot verify owned test-host exit: pid=\(host.pid)") }
        }
    }
    static func canonical(_ path: String) -> String {
        // Foundation deliberately rewrites /private/var to /var even after resolving
        // symlinks. The wrapper uses POSIX realpath; ownership paths must agree.
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    private static func hostFile(_ host: Host, root: URL) -> URL { root.appendingPathComponent("host-\(host.pid)-\(host.start).json") }

    private static func contract() throws -> (URL, String)? {
        let environment = ProcessInfo.processInfo.environment
        guard environment[directoryKey] != nil || environment[tokenKey] != nil else { return nil }
        guard let directory = environment[directoryKey], let token = environment[tokenKey],
              token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              directory.hasPrefix("/"), canonical(directory) == directory else { throw Failure("Invalid wrapper contract environment") }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw Failure("Wrapper manifest directory is not private") }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let record = try JSONDecoder().decode(Contract.self, from: readPrivate(root.appendingPathComponent("contract.json")))
        guard record.schema == 1, record.token == token else { throw Failure("Wrapper contract does not match") }
        return (root, token)
    }
    private static func readPrivate(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure("Cannot open private retirement manifest") }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_size <= 1_048_576 else {
            throw Failure("Retirement manifest must be a bounded private regular file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw Failure("Retirement manifest is too large") }
        return data
    }
    private static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw Failure("Retirement manifest is too large") }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private final class RegistryReply { var identifiers: Set<UUID>? }
    private static func registeredIDs(deadline: ContinuousClock.Instant) async throws -> Set<UUID> {
        let reply = RegistryReply()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { reply.identifiers = Set($0) }
        while reply.identifiers == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard let identifiers = reply.identifiers else { throw Failure("Owned retirement registry query exceeded its deadline") }
        return identifiers
    }
    private final class RemovalReply { var complete = false; var error: Error? }
    private static func remove(_ identifier: UUID, deadline: ContinuousClock.Instant) async throws -> Error? {
        let reply = RemovalReply()
        WKWebsiteDataStore.remove(forIdentifier: identifier) { reply.error = $0; reply.complete = true }
        while !reply.complete, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard reply.complete else { throw Failure("Owned backend \(identifier) removal exceeded its deadline") }
        return reply.error
    }
}
