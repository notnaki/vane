import Foundation

/// The MV2 adapter translates static lists, never synchronous webRequest callbacks.
/// Keep each exception in the same compiled list as every block it can override.
enum ExtensionFilterRules {
    struct Compilation: Sendable {
        let chunks: [String]
        let report: BlockerReport
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func compile(texts: [String], trustedSites: [String], chunkLimit: Int = 40_000) throws -> Compilation {
        // Enforce the existing byte/line limits before expanding any arrays.
        try Blocker.validateSourceBounds(texts)
        guard trustedSites.count <= 10_000, chunkLimit > 0 else { throw Failure("The filter policy exceeds the bridge limits.") }
        let exclusions = try trustedSites.compactMap(trustedPattern)
        // A conditional in one list cannot change the meaning of the next list.
        let lines = texts.enumerated().flatMap { source, text in text.components(separatedBy: .newlines).map { (source, $0) } }
        var ordinary: [String] = [], important: [String] = []
        var report = BlockerReport(), conditionalDepth = 0, currentSource = -1
        for (source, raw) in lines {
            if source != currentSource { conditionalDepth = 0; currentSource = source }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("!#if") { conditionalDepth += 1; continue }
            if line.hasPrefix("!#endif") { conditionalDepth = max(0, conditionalDepth - 1); continue }
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            let opts = options(line)
            if line.contains("##") || (line.hasPrefix("@@") && opts.contains("important")) {
                report.skipped += 1
                report.reasonCounts[line.contains("##") ? "Cosmetic filtering remains controlled by uBlock" : "Invalid important exception", default: 0] += 1
                continue
            }
            // WebKit's `raw` and `document` buckets combine several uBO types.
            // Dropping these rules avoids cancelling unrelated requests/navigation.
            let imprecise: Set<String> = ["document", "subdocument", "xmlhttprequest", "xhr", "websocket", "ping", "other", "popup"]
            if conditionalDepth > 0 || !opts.intersection(imprecise).isEmpty {
                report.skipped += 1
                report.reasonCounts[conditionalDepth > 0 ? "Conditional rule" : "Resource type cannot be represented precisely", default: 0] += 1
                continue
            }
            let hosts = line.split(whereSeparator: \.isWhitespace)
            if hosts.count >= 2, ["0.0.0.0", "127.0.0.1", "::"].contains(String(hosts[0])) {
                guard hosts.count == 2, validHost(String(hosts[1])), hosts[1] != "localhost" else { continue }
                line = "||\(hosts[1])^"
            }
            let parts = networkParts(line)
            if opts.contains("important"), let declared = parts.options {
                let rest = Blocker.networkOptions(declared).filter { $0 != "important" }
                line = parts.pattern + (rest.isEmpty ? "" : "$" + rest.joined(separator: ","))
                important.append(line)
            } else { ordinary.append(line) }
        }
        func convert(_ lines: [String]) throws -> [[String: Any]] {
            let result = Blocker.convertSources([lines.joined(separator: "\n")])
            report.skipped += result.report.skipped
            for (reason, count) in result.reasonCounts { report.reasonCounts[reason, default: 0] += count }
            var rules = try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]] ?? []
            for index in rules.indices {
                var trigger = rules[index]["trigger"] as? [String: Any] ?? [:]
                if trigger["resource-type"] == nil {
                    // uBlock performs separate strict-block decisions for a main
                    // document. A generic URL match must not cancel navigation.
                    trigger["resource-type"] = ["image", "style-sheet", "script", "font", "media", "raw"]
                    rules[index]["trigger"] = trigger
                }
            }
            return rules
        }
        // Let the shared compiler canonicalize and validate badfilters within
        // each priority tier; a modifier cannot disable a different tier's rule.
        let normal = try convert(ordinary), high = try convert(important)
        func exception(_ rule: [String: Any]) -> Bool {
            (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules"
        }
        let tail = normal.filter(exception), highTail = high.filter(exception)
        let blocks = normal.filter { !exception($0) }.map { ($0, false) }
            + high.filter { !exception($0) }.map { ($0, true) }
        report.rules = normal.count + high.count
        guard report.rules > 0 else { return Compilation(chunks: [], report: report) }
        let capacity = chunkLimit - tail.count - highTail.count
        guard capacity > 0, blocks.count <= capacity * 8 else {
            throw Failure("The selected filters exceed the bridge’s eight compiled-list limit. No partial policy was installed.")
        }
        var chunks: [String] = []
        for offset in stride(from: 0, to: max(1, blocks.count), by: capacity) {
            let part = blocks.isEmpty ? [] : Array(blocks[offset..<min(offset + capacity, blocks.count)])
            var rules = part.filter { !$0.1 }.map(\.0) + tail + part.filter(\.1).map(\.0) + highTail
            if !exclusions.isEmpty {
                for index in rules.indices {
                    var trigger = rules[index]["trigger"] as? [String: Any] ?? [:]
                    trigger["unless-top-url"] = exclusions
                    rules[index]["trigger"] = trigger
                }
            }
            let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys, .withoutEscapingSlashes])
            chunks.append(String(decoding: data, as: UTF8.self))
        }
        return Compilation(chunks: chunks, report: report)
    }

    private static func networkParts(_ line: String) -> (pattern: String, options: String?) {
        let exception = line.hasPrefix("@@")
        // Share the compiler's delimiter: a regex's terminal `$` is an anchor,
        // and must never hide resource restrictions from the bridge's safety gate.
        let parts = Blocker.networkParts(exception ? String(line.dropFirst(2)) : line)
        return ((exception ? "@@" : "") + parts.pattern, parts.options)
    }

    private static func options(_ line: String) -> Set<String> {
        guard !line.contains("##"), let declared = networkParts(line).options else { return [] }
        return Set(Blocker.networkOptions(declared))
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func trustedPattern(_ raw: String) throws -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 4096 else { throw Failure("A trusted-site directive exceeds the bridge limit.") }
        if value.isEmpty || value.hasPrefix("#") || value.hasSuffix("-scheme") { return nil }
        if validHost(value) {
            return "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: value.lowercased()) + "(:[0-9]+)?/"
        }
        guard value.hasPrefix("http://") || value.hasPrefix("https://"), !value.contains(where: \.isWhitespace),
              !value.contains("\\"), !value.contains("@") else {
            throw Failure("A trusted-site directive cannot be translated safely. Static filter compatibility is paused.")
        }
        guard let scheme = value.range(of: "://"), let slash = value[scheme.upperBound...].firstIndex(of: "/") else {
            throw Failure("A trusted URL cannot be translated safely.")
        }
        let authority = String(value[scheme.upperBound..<slash])
        guard !authority.isEmpty, authority.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-*_:[]".contains($0)) }) else {
            throw Failure("A trusted URL has an unsupported host.")
        }
        if authority.contains("*"), !authority.hasPrefix("*.") || authority.dropFirst(2).contains("*") {
            throw Failure("A trusted URL wildcard cannot preserve uBlock’s hostname boundary.")
        }
        func wildcard(_ text: String, replacement: String) -> String {
            text.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: replacement)
        }
        let pattern = NSRegularExpression.escapedPattern(for: String(value[..<scheme.upperBound]))
            + wildcard(authority, replacement: "[^/]*") + wildcard(String(value[slash...]), replacement: ".*")
        // uBO compares literal URLs exactly; wildcard URL directives match a substring.
        return "^" + pattern + (value.contains("*") ? "" : "$")
    }
}
