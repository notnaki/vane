import AppKit
import MetricKit
import SwiftUI
import UniformTypeIdentifiers

/// Local performance numbers: how long launch takes, how often the main thread stalls, what a
/// Space switch costs. Each sample is a fixed metric name, a duration, the app version and the
/// day. Nothing names a page, tab, Space or person, and nothing leaves the Mac: the user sees
/// the numbers in Settings › Advanced › Diagnostics and can export them as a file.
@MainActor final class PerformanceLog: ObservableObject {
    enum Metric: String, Codable, CaseIterable {
        case launch, hang, spaceSwitch

        var title: String {
            switch self {
            case .launch: "Launch"
            case .hang: "Main-thread hangs"
            case .spaceSwitch: "Space switches"
            }
        }
    }

    struct Sample: Codable, Equatable {
        let metric: Metric
        let ms: Int
        let day: String
        let version: String
    }

    struct Summary: Codable, Equatable {
        let count: Int
        let medianMs: Int
        let p95Ms: Int
        let maxMs: Int
    }

    static let shared = PerformanceLog(directory: Store.directory)
    /// Per metric. A hang-heavy week cannot crowd out the launches.
    static let maximumSamples = 500
    /// Apple's own line for a hang. Shorter stalls are dropped frames, which the signposts in
    /// `Trace` are for.
    static let hangThresholdMs = 250
    static let includeMacKey = "diagnosticsIncludeMac"

    let directory: URL
    @Published private(set) var samples: [Sample]
    private var saveScheduled = false

    var file: URL { directory.appendingPathComponent("performance.json") }
    nonisolated var metricKitDirectory: URL { directory.appendingPathComponent("MetricKit", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
        samples = (try? Data(contentsOf: directory.appendingPathComponent("performance.json")))
            .flatMap { try? JSONDecoder().decode([Sample].self, from: $0) } ?? []
    }

    func record(_ metric: Metric, ms: Int, at date: Date = .now) {
        samples.append(.init(metric: metric, ms: max(0, ms), day: Self.day(date), version: Self.version))
        let mine = samples.indices.filter { samples[$0].metric == metric }
        if mine.count > Self.maximumSamples {
            let drop = Set(mine.prefix(mine.count - Self.maximumSamples))
            samples = samples.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        scheduleSave()
    }

    func summary(_ metric: Metric) -> Summary? {
        let values = samples.filter { $0.metric == metric }.map(\.ms).sorted()
        guard !values.isEmpty else { return nil }
        func at(_ q: Double) -> Int { values[min(values.count - 1, Int(Double(values.count - 1) * q + 0.5))] }
        return Summary(count: values.count, medianMs: at(0.5), p95Ms: at(0.95), maxMs: values.last!)
    }

    func clear() {
        samples = []
        saveScheduled = false
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: metricKitDirectory)
    }

    // MARK: Export

    /// Apple puts the region format in every report's metadata; it says nothing about speed.
    /// The rest of this list is what "Include Mac details" adds back.
    static let alwaysStripped: Set<String> = ["regionFormat"]
    static let macDetailKeys: Set<String> = ["deviceType", "osVersion", "platformArchitecture"]

    var metricKitReports: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: metricKitDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func export(includeMac: Bool, now: Date = .now) throws -> Data {
        var totals: [String: Any] = [:]
        for metric in Metric.allCases {
            guard let s = summary(metric) else { continue }
            totals[metric.rawValue] = ["count": s.count, "medianMs": s.medianMs, "p95Ms": s.p95Ms, "maxMs": s.maxMs]
        }
        let stripped = includeMac ? Self.alwaysStripped : Self.alwaysStripped.union(Self.macDetailKeys)
        let reports: [Any] = metricKitReports.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .map { Self.removing(stripped, from: $0) }
        }
        var root: [String: Any] = [
            "vane": Self.version,
            "exported": Self.day(now),
            "summary": totals,
            "samples": samples.map { ["metric": $0.metric.rawValue, "ms": $0.ms, "day": $0.day, "version": $0.version] },
            "appleReports": reports,
        ]
        if includeMac { root["mac"] = Self.macDetails }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    nonisolated static func removing(_ keys: Set<String>, from value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.filter { !keys.contains($0.key) }.mapValues { removing(keys, from: $0) }
        }
        if let array = value as? [Any] { return array.map { removing(keys, from: $0) } }
        return value
    }

    static var macDetails: [String: Any] {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let info = ProcessInfo.processInfo
        return ["model": String(decoding: model.prefix { $0 != 0 }, as: UTF8.self), "macOS": info.operatingSystemVersionString,
                "memoryGB": Int(info.physicalMemory >> 30), "cores": info.processorCount]
    }

    // MARK: Storage

    /// Coalesced: a burst of hangs is one write half a minute later, off the main thread.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            await saveNow()
        }
    }

    /// Also awaited on quit, so the last half-minute is not lost.
    func saveNow() async {
        saveScheduled = false
        guard let data = try? JSONEncoder().encode(samples) else { return }
        let file = file
        await Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }.value
    }

    nonisolated static func day(_ date: Date) -> String { String(date.ISO8601Format().prefix(10)) }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "source build"
    }

    // MARK: Measuring

    private static var busySince: CFTimeInterval = 0
    private static var inbox: MetricKitInbox?

    /// Call first thing in launch. Installs the hang watch and MetricKit, once.
    static func start() {
        guard inbox == nil else { return }
        let inbox = MetricKitInbox(directory: shared.metricKitDirectory)
        Self.inbox = inbox
        MXMetricManager.shared.add(inbox)
        // ponytail: a run loop observer, not a watchdog thread. It sees a stall only once the
        // stall ends, so a hang that never ends (a deadlock) is MetricKit's to report.
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { busySince = now; return }
                guard busySince > 0 else { return }
                let ms = Int((now - busySince) * 1000)
                busySince = 0
                if ms >= hangThresholdMs { shared.record(.hang, ms: ms) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Process start to the first windows being open, dyld included.
    static func recordLaunch(now: Date = .now) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return }
        let start = info.kp_proc.p_un.__p_starttime
        let began = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        shared.record(.launch, ms: Int(now.timeIntervalSince(began) * 1000))
    }

    /// Times `body` and keeps it only when it actually did something.
    static func measure(_ metric: Metric, if kept: () -> Bool = { true }, _ body: () -> Void) {
        let start = CACurrentMediaTime()
        body()
        if kept() { shared.record(metric, ms: Int((CACurrentMediaTime() - start) * 1000)) }
    }
}

/// MetricKit hands over Apple's daily hang, CPU, disk and crash reports for this app. They are
/// filed as they came, up to the most recent 30; nothing here sends them anywhere.
final class MetricKitInbox: NSObject, MXMetricManagerSubscriber, Sendable {
    static let keep = 30
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func didReceive(_ payloads: [MXMetricPayload]) { file(payloads.map { $0.jsonRepresentation() }, "metrics") }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { file(payloads.map { $0.jsonRepresentation() }, "diagnostics") }

    private func file(_ reports: [Data], _ kind: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for (i, data) in reports.enumerated() {
            try? data.write(to: directory.appendingPathComponent("\(stamp)-\(i)-\(kind).json"), options: .atomic)
        }
        let all = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in all.dropLast(Self.keep) { try? fm.removeItem(at: old) }
    }
}

/// Settings › Advanced › Diagnostics: the numbers, an export, and a way to throw them away.
struct PerformanceSettingsCard: View {
    @ObservedObject private var log = PerformanceLog.shared
    @AppStorage(PerformanceLog.includeMacKey) private var includeMac = false
    @State private var status = ""

    var body: some View {
        SettingsCard {
            ForEach(PerformanceLog.Metric.allCases, id: \.self) { metric in
                SettingsRow(metric.title) {
                    Text(Self.describe(log.summary(metric)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            SettingsRow("Apple reports") {
                Text(log.metricKitReports.isEmpty ? "None yet" : "\(log.metricKitReports.count) saved")
                    .foregroundStyle(.secondary)
            }
            SettingsRow("Include Mac model and macOS version in exports") {
                Toggle("Include Mac model and macOS version in exports", isOn: $includeMac).labelsHidden()
            }
            SettingsRow("Performance data") {
                Button("Clear") { log.clear(); status = "" }
                Button("Export…") { export() }
            }
            Footnote("Measured on this Mac and never sent. Exports contain timings, counts, the Vane version and Apple’s crash and hang reports — not sites, tabs, Spaces or names."
                     + (status.isEmpty ? "" : " " + status))
        }
    }

    static func describe(_ s: PerformanceLog.Summary?) -> String {
        guard let s else { return "No data yet" }
        return "\(s.count) · median \(ms(s.medianMs)) · slowest \(ms(s.maxMs))"
    }

    static func ms(_ value: Int) -> String {
        value < 1000 ? "\(value) ms" : String(format: "%.1f s", Double(value) / 1000)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Performance Data"
        panel.nameFieldStringValue = "Vane-performance-\(PerformanceLog.day(.now)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try log.export(includeMac: includeMac).write(to: url, options: .atomic)
            status = "Exported."
        } catch {
            status = "Could not export: \(error.localizedDescription)"
        }
    }
}
