import Foundation

struct UpdateVersion: Comparable {
    let core: [Int]
    /// The `-beta.2` part, split on dots. Empty means a real release, which by semver
    /// outranks every pre-release of the same core.
    let pre: [String]

    init?(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while let f = s.first, f == "v" || f == "V" { s = s.dropFirst() }
        // Build metadata (`+7`) is not part of precedence, so it is dropped unparsed.
        s = s.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let halves = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in halves[0].split(separator: ".") {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        guard !numbers.isEmpty else { return nil }
        core = numbers
        pre = halves.count > 1 ? halves[1].split(separator: ".").map(String.init) : []
    }

    static func < (l: UpdateVersion, r: UpdateVersion) -> Bool {
        for i in 0..<max(l.core.count, r.core.count) {
            // `1.2` and `1.2.0` are the same version, so a missing component is a zero.
            let a = i < l.core.count ? l.core[i] : 0, b = i < r.core.count ? r.core[i] : 0
            if a != b { return a < b }
        }
        // 1.0.0-beta < 1.0.0. Without this the release *after* a pre-release looks equal
        // to it and nobody on a beta is ever offered the real thing.
        if l.pre.isEmpty != r.pre.isEmpty { return !l.pre.isEmpty }
        for i in 0..<max(l.pre.count, r.pre.count) {
            guard i < l.pre.count else { return true }
            guard i < r.pre.count else { return false }
            let a = l.pre[i], b = r.pre[i]
            if a == b { continue }
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y      // beta.2 < beta.10, not "10" < "2"
            case (_?, nil):    return true       // numeric identifiers rank below alphanumeric
            case (nil, _?):    return false
            default:           return a < b
            }
        }
        return false
    }
}
