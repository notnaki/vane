import Darwin
import Dispatch
import Foundation
import XCTest

/// Diagnostic-only direct transport. SwiftPM may replay stdout after XCTest exits.
@MainActor final class PasswordDocumentPhaseChannel {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class BundleMarker: NSObject {}
    private let descriptor: Int32
    private let channelToken: String
    private let nativeToken: String
    private let host: [String: Any]
    private let producer: NativeFixtureDiagnostics.Identity
    private var sequence = 0
    private(set) var failure: String?

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["VANE_PASSWORD_PHASE_DIRECTORY"],
              let token = environment["VANE_PASSWORD_PHASE_TOKEN"],
              token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
              let nativeDirectory = environment["VANE_NATIVE_FIXTURE_MANIFEST_DIR"],
              let expectedNativeToken = environment["VANE_NATIVE_FIXTURE_MANIFEST_TOKEN"] else {
            throw Failure(description: "Missing private password phase contract")
        }
        let root = try Self.privateDirectory(directory)
        do {
            let context = try JSONSerialization.jsonObject(with: Self.readPrivate(root, "context.json")) as? [String: Any]
            guard context?["schema"] as? Int == 1, context?["channelToken"] as? String == token,
                  context?["nativeDirectory"] as? String == nativeDirectory,
                  context?["nativeToken"] as? String == expectedNativeToken,
                  let identity = NativeFixtureDiagnostics.identity(getpid()) else {
                throw Failure(description: "Password phase context does not match the native runner")
            }
            let native = try Self.privateDirectory(nativeDirectory)
            defer { _ = Darwin.close(native) }
            let contract = try JSONSerialization.jsonObject(with: Self.readPrivate(native, "contract.json")) as? [String: Any]
            guard contract?["schema"] as? Int == 1, contract?["token"] as? String == expectedNativeToken else {
                throw Failure(description: "Password phase native contract changed")
            }
            let name = "host-\(identity.pid)-\(identity.start).json"
            let manifest = try JSONDecoder().decode(NativeFixtureRetirement.Manifest.self, from: Self.readPrivate(native, name, limit: 1_048_576))
            func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
            guard manifest.schema == 1, manifest.token == expectedNativeToken,
                  manifest.host.pid == identity.pid, manifest.host.start == identity.start,
                  canonical(manifest.host.path) == canonical(identity.path),
                  canonical(manifest.host.testBundlePath) == canonical(Bundle(for: BundleMarker.self).bundleURL.path),
                  manifest.host.testBundlePath.hasSuffix(".xctest") else {
                throw Failure(description: "Password phase producer is not the exact registered XCTest launch")
            }
            descriptor = root
            channelToken = token
            nativeToken = expectedNativeToken
            host = ["pid": Int(identity.pid), "start": identity.start, "path": identity.path]
            producer = identity
        } catch {
            _ = Darwin.close(root)
            throw error
        }
    }

    deinit { _ = Darwin.close(descriptor) }

    func samplerAcknowledgment(token: String, content: NativeFixtureDiagnostics.Identity,
                               held: UInt64, deadline: UInt64) throws -> [String: Any]? {
        var metadata = stat()
        if fstatat(descriptor, "samplers-ready.json", &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure(description: "Cannot inspect sampler acknowledgment") }
            return nil
        }
        let data = try Self.readPrivate(descriptor, "samplers-ready.json")
        typealias Ack = PasswordDocumentSamplerAcknowledgment
        func row(_ identity: NativeFixtureDiagnostics.Identity) -> Ack.Identity {
            .init(pid: identity.pid, start: identity.start, path: identity.path)
        }
        let contract = Ack.Contract(channelToken: channelToken, nativeToken: nativeToken, navigationToken: token,
            host: row(producer), content: row(content), heldMonotonicNs: held, deadlineMonotonicNs: deadline)
        _ = try Ack.validated(data, contract: contract, now: DispatchTime.now().uptimeNanoseconds,
                              identity: { NativeFixtureDiagnostics.identity($0).map(row) })
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func record(_ phase: String, fields: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) {
        guard failure == nil else { return }
        do {
            guard sequence < 256, phase.range(of: "^[a-z][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
                throw Failure(description: "Password phase record/count bound exceeded")
            }
            let next = sequence + 1
            let event: [String: Any] = ["schema": 1, "channelToken": channelToken, "nativeToken": nativeToken,
                "host": host, "sequence": next, "phase": phase,
                "wallSeconds": Date.now.timeIntervalSince1970,
                "monotonicNs": DispatchTime.now().uptimeNanoseconds, "fields": fields]
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            guard data.count <= 16_384 else { throw Failure(description: "Password phase record exceeds16384 bytes") }
            let temporary = ".phase-" + UUID().uuidString
            let name = String(format: "event-%04d.json", next)
            let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw Failure(description: "Cannot create private password phase record") }
            defer { _ = unlinkat(descriptor, temporary, 0) }
            do {
                guard fchmod(output, 0o600) == 0 else { throw Failure(description: "Cannot protect password phase record") }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw Failure(description: "Cannot write complete password phase record") }
                        offset += count
                    }
                }
            } catch {
                _ = Darwin.close(output)
                throw error
            }
            guard Darwin.close(output) == 0, linkat(descriptor, temporary, descriptor, name, 0) == 0 else {
                throw Failure(description: "Cannot atomically publish password phase record without replacement")
            }
            sequence = next
        } catch {
            failure = String(describing: error)
            NativeFixtureDiagnostics.emit("password phase transport failure: \(error)")
            XCTFail("Password phase transport failed: \(error)", file: file, line: line)
        }
    }

    private static func privateDirectory(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"), components.first == "",
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure(description: "Password phase root must be absolute and canonical")
        }
        var cursor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw Failure(description: "Cannot open password phase root") }
        do {
            for component in path.split(separator: "/") {
                let next = openat(cursor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure(description: "Password phase directory traversal rejected") }
                _ = Darwin.close(cursor)
                cursor = next
            }
            var info = stat()
            guard fstat(cursor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw Failure(description: "Password phase directory must be current-owner mode0700")
            }
            return cursor
        } catch {
            _ = Darwin.close(cursor)
            throw error
        }
    }

    private static func readPrivate(_ directory: Int32, _ name: String, limit: Int = 16_384) throws -> Data {
        guard !name.contains("/") else { throw Failure(description: "Invalid password phase file name") }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Failure(description: "Cannot open private password phase contract") }
        defer { _ = Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= limit else {
            throw Failure(description: "Password phase contract must be bounded current-owner regular mode0600")
        }
        let data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure(description: "Password phase contract read bound exceeded") }
        return data
    }
}
