import Combine
import Foundation

struct BlockerReport: Codable, Equatable, Sendable {
    struct Diagnostic: Codable, Equatable, Sendable {
        var line: Int
        var reason: String
        var sample: String
    }
    var rules = 0
    var skipped = 0
    var reasonCounts: [String: Int] = [:]
    var diagnostics: [Diagnostic] = []
    var summary: String { "\(rules) supported rules · \(skipped) unsupported rules" }
    var details: String {
        summary + "\n" + reasonCounts.keys.sorted().map { "\($0): \(reasonCounts[$0]!)" }.joined(separator: "\n")
        + "\n\n" + diagnostics.map { "Line \($0.line): \($0.reason)\n\($0.sample)" }.joined(separator: "\n\n")
        + (skipped > diagnostics.count ? "\n\nShowing the first \(diagnostics.count) unsupported rules." : "")
    }
}

struct BlockerConversion: Sendable {
    var json: String
    var report: BlockerReport
    var rules: Int { report.rules }
    var skipped: Int { report.skipped }
    var reasonCounts: [String: Int] { report.reasonCounts }
    var diagnostics: [BlockerReport.Diagnostic] { report.diagnostics }
}

@MainActor final class BlockerStatus: ObservableObject {
    static let shared = BlockerStatus()
    @Published var message = "Preparing blocking rules…"
    @Published var report: BlockerReport?
    @Published var updating = false
    @Published var revision = 0
}
