import Foundation

/// Only these fixed events and numeric codes may enter shareable diagnostics. In
/// particular, never accept error descriptions, URLs, titles, IDs, or console output.
struct DiagnosticEvent: Equatable {
    enum Kind: String {
        case launched = "app.launched"
        case navigationStarted = "navigation.started"
        case navigationCommitted = "navigation.committed"
        case navigationFinished = "navigation.finished"
        case navigationFailed = "navigation.failed"
        case provisionalNavigationFailed = "navigation.provisional_failed"
        case webContentTerminated = "web_content.terminated"
    }

    let timestamp: Date
    let kind: Kind
    let code: Int?
}

enum DiagnosticPeriod: Int, CaseIterable {
    case thirtySeconds = 30, minute = 60, fiveMinutes = 300

    var label: String {
        switch self {
        case .thirtySeconds: "Last 30 seconds"
        case .minute: "Last minute"
        case .fiveMinutes: "Last 5 minutes"
        }
    }
}

struct DiagnosticSnapshot {
    let capturedAt: Date
    let events: [DiagnosticEvent]

    func events(in period: DiagnosticPeriod) -> [DiagnosticEvent] {
        let cutoff = capturedAt.addingTimeInterval(-Double(period.rawValue))
        return events.filter { $0.timestamp >= cutoff && $0.timestamp <= capturedAt }
    }
}

/// A small memory-only tail. No timer, disk writes, OS log access, or telemetry.
@MainActor final class DiagnosticLog {
    static let shared = DiagnosticLog()
    static let maximumEvents = 2_000
    private let capacity: Int
    private var events: [DiagnosticEvent] = []

    init(capacity: Int = DiagnosticLog.maximumEvents) {
        self.capacity = max(1, min(capacity, Self.maximumEvents))
    }

    func record(_ kind: DiagnosticEvent.Kind, code: Int? = nil,
                isPrivate: Bool = false, at timestamp: Date = .now) {
        guard !isPrivate else { return }
        let cutoff = timestamp.addingTimeInterval(-Double(DiagnosticPeriod.fiveMinutes.rawValue))
        events.removeAll { $0.timestamp < cutoff }
        events.append(.init(timestamp: timestamp, kind: kind, code: code))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    func snapshot(at timestamp: Date = .now) -> DiagnosticSnapshot {
        let cutoff = timestamp.addingTimeInterval(-Double(DiagnosticPeriod.fiveMinutes.rawValue))
        events.removeAll { $0.timestamp < cutoff }
        return DiagnosticSnapshot(capturedAt: timestamp,
                                  events: events.filter { $0.timestamp <= timestamp })
    }
}

struct IssueReportDraft {
    var title = ""
    var details = ""
    var includeLogs = false
    var period: DiagnosticPeriod = .minute
    let snapshot: DiagnosticSnapshot
    let environment: String

    var selectedEvents: [DiagnosticEvent] { snapshot.events(in: period) }
    var canShare: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var markdown: String {
        var text = "## What happened\n\n\(details)\n\n## Environment\n\n\(environment)\n"
        guard includeLogs else { return text }
        let captured = snapshot.capturedAt.ISO8601Format()
        let lines = selectedEvents.map { event in
            event.timestamp.ISO8601Format() + " " + event.kind.rawValue
                + (event.code.map { " code=\($0)" } ?? "")
        }
        let log = lines.isEmpty ? "No diagnostic events in this window." : lines.joined(separator: "\n")
        text += """

        <details>
        <summary>Recent diagnostics — \(period.rawValue) seconds</summary>

        Snapshot: \(captured). Memory-only tail; at most 2,000 events from the last 5 minutes. Older events may have been evicted. Private-tab events are excluded.

        ```text
        \(log)
        ```
        </details>

        """
        return text
    }

    var handoff: IssueReportHandoff { IssueReportHandoff(title: title, markdown: markdown) }

    static var currentEnvironment: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "source build"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "- Vane: \(version) (\(build))\n- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// GitHub's issue-draft URL can prefill text, but cannot upload attachments. Keep
/// every byte for large reports and explicitly ask the user to paste the copy.
struct IssueReportHandoff {
    static let maximumURLBytes = 7_500
    private static let baseURL = URL(string: "https://github.com/notnaki/vane/issues/new")!
    let url: URL
    let requiresPaste: Bool
    let clipboardText: String

    init(title: String, markdown: String) {
        clipboardText = markdown
        func draftURL(title: String, body: String) -> URL {
            var parts = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            // URLComponents permits literal +, which form query decoding treats as space.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return parts.url!
        }
        let candidate = draftURL(title: title, body: markdown)
        requiresPaste = candidate.absoluteString.utf8.count > Self.maximumURLBytes
        if requiresPaste {
            // Keep this bounded even for arbitrarily long Unicode titles. The original
            // title remains in the report window; the full body goes on the clipboard.
            let instruction = "Paste the report copied by Vane here (Command-V)."
            let fallback = draftURL(title: String(title.prefix(120)), body: instruction)
            url = fallback.absoluteString.utf8.count <= Self.maximumURLBytes
                ? fallback : draftURL(title: "Vane problem report", body: instruction)
        } else {
            url = candidate
        }
    }
}
