import Foundation
import CoreFoundation

/// Arc's versioned link-routing file. Parsing never reads or changes Vane preferences.
struct ArcLinkRouting: Sendable {
    enum Destination: Equatable, Sendable {
        case littleArc, mostRecentSpace, space(String)
    }
    struct Rule: Sendable {
        var id: UUID
        var match: AirTraffic.Match
        var pattern: String
        var destination: Destination
    }
    var rules: [Rule] = []
    var defaultTarget: String?
    var skippedRules = 0
    var unsupportedDefault = false

    /// Nil means the file itself cannot be read, rather than an empty set of rules.
    static func parse(_ data: Data) -> ArcLinkRouting? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = top["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let rules = top["rules"] as? [Any] else { return nil }
        var parsed = ArcLinkRouting()
        if let value = top["defaultDestination"] {
            if let target = destination(value) {
                switch target {
                case .littleArc: parsed.defaultTarget = LinkTarget.littleArc
                case .mostRecentSpace: parsed.defaultTarget = LinkTarget.currentSpace
                case .space: parsed.unsupportedDefault = true
                }
            } else { parsed.unsupportedDefault = true }
        }
        for value in rules {
            guard let rule = value as? [String: Any],
                  let components = rule["sourceComponents"] as? [[String: Any]], components.count == 1,
                  let component = components[0]["componentType"] as? [String: Any], component.count == 1,
                  let urlMatch = component["urlMatch"] as? [String: Any],
                  let match = urlMatch["_0"] as? [String: Any], match.count == 1,
                  let matchName = match.keys.first, match[matchName] is [String: Any],
                  let mode = AirTraffic.Match(rawValue: matchName),
                  let pattern = urlMatch["_1"] as? String,
                  !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let destination = destination(rule["destination"]) else {
                parsed.skippedRules += 1
                continue
            }
            parsed.rules.append(.init(id: (rule["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                                      match: mode, pattern: pattern, destination: destination))
        }
        return parsed
    }

    private static func destination(_ value: Any?) -> Destination? {
        guard let value = value as? [String: Any], value.count == 1 else { return nil }
        if value["littleArc"] is [String: Any] { return .littleArc }
        guard let space = value["space"] as? [String: Any], let selection = space["_0"] else { return nil }
        if let id = selection as? String, !id.isEmpty { return .space(id) }
        guard let selection = selection as? [String: Any], selection.count == 1,
              let key = selection.keys.first, selection[key] is [String: Any] else { return nil }
        if key == "mostRecent" { return .mostRecentSpace }
        // Arc's enum payload uses the explicit Arc Space id as its key. Resolve only
        // through the imported-space map; never reinterpret an unmapped id as recent.
        return .space(key)
    }

    struct Plan {
        var rules: [AirTraffic.Rule]
        var added = 0
        var already = 0
        var skipped = 0
    }

    func plan(existing: [AirTraffic.Rule], spaceIDs: [String: UUID]) -> Plan {
        var plan = Plan(rules: existing, skipped: skippedRules)
        for rule in rules {
            let target: String
            switch rule.destination {
            case .littleArc: target = AirTraffic.Destination.littleTag
            case .mostRecentSpace: target = AirTraffic.Destination.recentTag
            case .space(let arcID):
                guard let id = spaceIDs[arcID] else { plan.skipped += 1; continue }
                target = id.uuidString
            }
            guard !plan.rules.contains(where: {
                $0.match == rule.match && $0.pattern == rule.pattern && $0.destination == target
            }) else { plan.already += 1; continue }
            // A repeated source id must not create two Identifiable rows with the same id.
            let id = plan.rules.contains { $0.id == rule.id } ? UUID() : rule.id
            plan.rules.append(.init(id: id, match: rule.match, pattern: rule.pattern, destination: target))
            plan.added += 1
        }
        return plan
    }

    var consent: String {
        var parts = ["Air Traffic Control: append up to \(rules.count) rule\(rules.count == 1 ? "" : "s") after existing Vane rules; duplicates are kept once."]
        if let defaultTarget {
            parts.append("Change ‘Open links from other apps in’ to \(defaultTarget == LinkTarget.littleArc ? "Little Vane" : "the current Space").")
        }
        if skippedRules > 0 { parts.append("\(skippedRules) unsupported Air Traffic Control rules will be skipped.") }
        if unsupportedDefault { parts.append("Arc's default link destination is unsupported; Vane's default will be kept.") }
        return parts.joined(separator: " ")
    }
}
