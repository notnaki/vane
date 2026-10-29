import Foundation

/// Pure diagnostic protocol validation; no AppKit or process launch is needed.
struct PasswordDocumentSamplerAcknowledgment: Codable {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Identity: Codable, Equatable {
        let pid: Int32
        let start: UInt64
        let path: String
    }
    struct Sample: Codable {
        let role: String
        let target: Identity
        let sampler: Identity
        let captureStartedMonotonicNs: UInt64
        let progressMonotonicNs: UInt64
    }
    struct Contract {
        let channelToken: String
        let nativeToken: String
        let navigationToken: String
        let host: Identity
        let content: Identity
        let heldMonotonicNs: UInt64
        let deadlineMonotonicNs: UInt64
    }
    let schema: Int
    let channelToken: String
    let nativeToken: String
    let navigationToken: String
    let issuedMonotonicNs: UInt64
    let samples: [Sample]

    static func validated(_ data: Data, contract: Contract, now: UInt64,
                          identity: (Int32) -> Identity?) throws -> Self {
        guard data.count <= 16_384 else { throw Failure(description: "Sampler acknowledgment exceeds size bound") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.channelToken == contract.channelToken,
              value.nativeToken == contract.nativeToken, value.navigationToken == contract.navigationToken,
              now < contract.deadlineMonotonicNs, value.issuedMonotonicNs >= contract.heldMonotonicNs,
              value.issuedMonotonicNs <= now, now - value.issuedMonotonicNs <= 500_000_000 else {
            throw Failure(description: "Sampler acknowledgment token or monotonic lifetime mismatch")
        }
        func same(_ a: Identity, _ b: Identity?) -> Bool {
            guard let b, a.pid > 0, a.start > 0, b.pid == a.pid, b.start == a.start,
                  a.path.hasPrefix("/"), b.path.hasPrefix("/"), !a.path.contains("\0"), !b.path.contains("\0") else { return false }
            return URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path ==
                URL(fileURLWithPath: b.path).resolvingSymlinksInPath().path
        }
        guard value.samples.count == 2, value.samples.map(\.role).sorted() == ["content", "ui"],
              Set([contract.host.pid, contract.content.pid] + value.samples.map { $0.sampler.pid }).count == 4 else {
            throw Failure(description: "Sampler acknowledgment needs two distinct exact process roles")
        }
        for row in value.samples {
            let expected = row.role == "ui" ? contract.host : contract.content
            guard row.sampler.path.hasPrefix("/"), !row.sampler.path.contains("\0") else {
                throw Failure(description: "Sampler acknowledgment executable path is invalid")
            }
            let samplerPath = URL(fileURLWithPath: row.sampler.path).resolvingSymlinksInPath().path
            guard same(row.target, expected), same(row.target, identity(row.target.pid)),
                  row.sampler.pid > 0, row.sampler.start > 0,
                  samplerPath == URL(fileURLWithPath: "/usr/bin/sample").resolvingSymlinksInPath().path,
                  same(row.sampler, identity(row.sampler.pid)),
                  row.captureStartedMonotonicNs >= contract.heldMonotonicNs,
                  row.captureStartedMonotonicNs <= row.progressMonotonicNs,
                  row.progressMonotonicNs <= value.issuedMonotonicNs,
                  value.issuedMonotonicNs - row.progressMonotonicNs <= 500_000_000 else {
                throw Failure(description: "Sampler acknowledgment process identity or real progress mismatch")
            }
        }
        return value
    }
}
