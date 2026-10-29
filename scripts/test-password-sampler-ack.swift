import Foundation

@main struct PasswordSamplerAcknowledgmentChecks {
    struct Failure: Error { let name: String }
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Password acknowledgment control failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        typealias Ack = PasswordDocumentSamplerAcknowledgment
        let ui = Ack.Identity(pid: 10, start: 100, path: "/Applications/xctest")
        let content = Ack.Identity(pid: 11, start: 101, path: "/System/WebContent")
        let a = Ack.Identity(pid: 20, start: 200, path: "/usr/bin/sample")
        let b = Ack.Identity(pid: 21, start: 201, path: "/usr/bin/sample")
        let contract = Ack.Contract(channelToken: String(repeating: "a", count: 32),
            nativeToken: String(repeating: "b", count: 32), navigationToken: "navigation",
            host: ui, content: content, heldMonotonicNs: 1_000_000_000, deadlineMonotonicNs: 4_000_000_000)
        let proof = Ack(schema: 1, channelToken: contract.channelToken, nativeToken: contract.nativeToken,
            navigationToken: contract.navigationToken, issuedMonotonicNs: 1_900_000_000,
            samples: [.init(role: "ui", target: ui, sampler: a, captureStartedMonotonicNs: 1_500_000_000,
                            progressMonotonicNs: 1_700_000_000),
                      .init(role: "content", target: content, sampler: b, captureStartedMonotonicNs: 1_600_000_000,
                            progressMonotonicNs: 1_800_000_000)])
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as! [String: Any]
        let live: [Int32: Ack.Identity] = [10: ui, 11: content, 20: a, 21: b]
        var checks = 0
        func check(_ name: String, valid: Bool = false, now: UInt64 = 2_000_000_000,
                   observations: [Int32: Ack.Identity]? = nil, mutate: (inout [String: Any]) -> Void = { _ in }) throws {
            var value = base
            mutate(&value)
            let data = try JSONSerialization.data(withJSONObject: value)
            let accepted = (try? Ack.validated(data, contract: contract, now: now,
                                             identity: { (observations ?? live)[$0] })) != nil
            guard accepted == valid else { throw Failure(name: name) }
            checks += 1
        }
        try check("valid exact live two-role proof", valid: true)
        for key in ["channelToken", "nativeToken", "navigationToken"] {
            try check("wrong " + key) { $0[key] = "wrong" }
        }
        try check("schema Bool is not Int") { $0["schema"] = true }
        try check("future proof") { $0["issuedMonotonicNs"] = 2_100_000_000 }
        try check("stale proof", now: 2_500_000_001)
        try check("expired total budget", now: 4_000_000_000)
        try check("missing content") { $0["samples"] = Array(($0["samples"] as! [[String: Any]]).prefix(1)) }
        try check("duplicate roles") {
            var rows = $0["samples"] as! [[String: Any]]; rows[1]["role"] = "ui"; $0["samples"] = rows
        }
        for row in 0...1 {
            for key in ["target", "sampler"] {
                for (field, wrong) in [("pid", 99 as Any), ("start", 999 as Any), ("path", "/wrong" as Any)] {
                    try check("wrong \(row) \(key) \(field)") {
                        var rows = $0["samples"] as! [[String: Any]]
                        var value = rows[row][key] as! [String: Any]; value[field] = wrong
                        rows[row][key] = value; $0["samples"] = rows
                    }
                }
            }
            for field in ["captureStartedMonotonicNs", "progressMonotonicNs"] {
                for wrong: UInt64 in [500_000_000, 2_100_000_000] {
                    try check("out-of-hold \(row) \(field)") {
                        var rows = $0["samples"] as! [[String: Any]]; rows[row][field] = wrong; $0["samples"] = rows
                    }
                }
            }
        }
        for pid: Int32 in [10, 11, 20, 21] {
            var dead = live; dead.removeValue(forKey: pid)
            try check("dead observed process \(pid)", observations: dead)
            var reused = live
            reused[pid] = .init(pid: pid, start: live[pid]!.start + 1, path: live[pid]!.path)
            try check("reused PID \(pid)", observations: reused)
        }
        try check("stale progress inside freshly issued proof") {
            var rows = $0["samples"] as! [[String: Any]]
            rows[0]["captureStartedMonotonicNs"] = 1_050_000_000
            rows[0]["progressMonotonicNs"] = 1_100_000_000
            $0["samples"] = rows
        }
        try check("duplicate sampler children") {
            var rows = $0["samples"] as! [[String: Any]]; rows[1]["sampler"] = rows[0]["sampler"]; $0["samples"] = rows
        }
        try check("sampler path contains NUL") {
            var rows = $0["samples"] as! [[String: Any]]
            var child = rows[0]["sampler"] as! [String: Any]; child["path"] = "/usr/bin/sample\0"
            rows[0]["sampler"] = child; $0["samples"] = rows
        }
        try check("PID Bool is not Int32") {
            var rows = $0["samples"] as! [[String: Any]]
            var child = rows[0]["sampler"] as! [String: Any]; child["pid"] = true
            rows[0]["sampler"] = child; $0["samples"] = rows
        }
        try check("oversized record") { $0["extra"] = String(repeating: "x", count: 20_000) }
        try check("wrong target role with valid live identity") {
            var rows = $0["samples"] as! [[String: Any]]; rows[0]["target"] = rows[1]["target"]; $0["samples"] = rows
        }
        print("Password sampler acknowledgment: \(checks) actual Swift validation controls passed")
    }
}
