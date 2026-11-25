import AppKit
import MetricKit
import SwiftUI
import UniformTypeIdentifiers

/// Local performance numbers: how long launch takes, how often the main thread stalls, what a
/// Space switch costs. Each sample is a fixed metric name, a duration, the app version and the
/// day. Nothing names a page, tab, Space or person, and nothing leaves the Mac: the user sees
/// the numbers in Settings › Advanced › Performance › Diagnostics and can export them as a file.
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
    @Published private(set) var reportCount = 0
    private var saveScheduled = false

    var file: URL { directory.appendingPathComponent("performance.json") }
    nonisolated var metricKitDirectory: URL { directory.appendingPathComponent("MetricKit", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
        samples = (try? Data(contentsOf: directory.appendingPathComponent("performance.json")))
            .flatMap { try? JSONDecoder().decode([Sample].self, from: $0) } ?? []
        refreshReports()
    }

    func refreshReports() { reportCount = metricKitReports.count }

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
        reportCount = 0
        saveScheduled = false
        let (file, reports) = (file, metricKitDirectory)
        // Behind any write already queued, so a save in flight cannot bring them back.
        Self.disk.async {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: reports)
        }
    }

    /// Every write and delete of these files, in the order they were asked for.
    nonisolated static let disk = DispatchQueue(label: "app.vane.performance", qos: .utility)

    // MARK: Export

    /// Never exported. The region format and pid say nothing about speed; an exception's
    /// message, a termination reason and the memory map can quote a URL, title or file path.
    nonisolated static let alwaysStripped: Set<String> = [
        "regionFormat", "pid", "composedMessage", "formatString", "arguments",
        "terminationReason", "virtualMemoryRegionInfo",
    ]
    /// What "Include Mac details" adds back. A system framework's binary UUID
    /// names the exact macOS build, and a source build's own UUID is unique to that Mac.
    static let macDetailKeys: Set<String> = ["deviceType", "osVersion", "platformArchitecture", "binaryUUID"]
    /// Always cut to the day, like the samples.
    nonisolated static let timestampKeys: Set<String> = ["timeStampBegin", "timeStampEnd"]

    nonisolated var metricKitReports: [URL] {
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
                .map { Self.scrub($0, removing: stripped) }
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

    nonisolated static func scrub(_ value: Any, removing keys: Set<String>) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict where !keys.contains(key) {
                if timestampKeys.contains(key), let text = value as? String {
                    out[key] = String(text.prefix(10))
                } else {
                    out[key] = scrub(value, removing: keys)
                }
            }
            return out
        }
        if let array = value as? [Any] { return array.map { scrub($0, removing: keys) } }
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
        await withCheckedContinuation { done in
            Self.disk.async {
                try? data.write(to: file, options: .atomic)
                done.resume()
            }
        }
    }

    nonisolated static func day(_ date: Date) -> String { String(date.ISO8601Format().prefix(10)) }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "source build"
    }

    // MARK: Measuring

    private static var busySince: CFTimeInterval = 0
    private static var inbox: MetricKitInbox?
    private static var started = false

    /// Call first thing in launch. Installs the hang watch and MetricKit, once.
    static func start() {
        guard !started else { return }
        started = true
        // MetricKit hands each report over once, per app, not per data directory: a test copy
        // run with VANE_DATA_DIR would take the real app's reports into its throwaway folder.
        if getenv("VANE_DATA_DIR") == nil {
            let inbox = MetricKitInbox(directory: shared.metricKitDirectory)
            Self.inbox = inbox
            MXMetricManager.shared.add(inbox)
        }
        // ponytail: run loop observers, not a watchdog thread. A stall is seen once it ends, so
        // one that never ends (a deadlock) is MetricKit's to report. The clock starts before
        // anything else wakes and stops after everything else is done before sleeping, Core
        // Animation's commit and AppKit's display pass included: layout and drawing count.
        let main = CFRunLoopGetMain()
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue,
                                                      true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { busySince = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                       true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                guard busySince > 0 else { return }
                let ms = Int((CACurrentMediaTime() - busySince) * 1000)
                busySince = 0
                if ms >= hangThresholdMs { shared.record(.hang, ms: ms) }
            }
        }
        CFRunLoopAddObserver(main, wake, .commonModes)
        CFRunLoopAddObserver(main, sleep, .commonModes)
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
/// filed as they came, the most recent 30 of each kind; nothing here sends them anywhere.
final class MetricKitInbox: NSObject, MXMetricManagerSubscriber, Sendable {
    static let keep = 30
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func didReceive(_ payloads: [MXMetricPayload]) { file(payloads.map { $0.jsonRepresentation() }, "metrics") }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { file(payloads.map { $0.jsonRepresentation() }, "diagnostics") }

    private func file(_ reports: [Data], _ kind: String) {
        let directory = directory
        PerformanceLog.disk.async {
            let fm = FileManager.default
            // Not intermediate directories: after Erase Everything the data folder stays gone.
            try? fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let stamp = Int(Date().timeIntervalSince1970)
            for (i, data) in reports.enumerated() {
                // Scrubbed before it touches disk, so the kept copy is no richer than an export.
                guard let json = try? JSONSerialization.jsonObject(with: data),
                      let clean = try? JSONSerialization.data(withJSONObject: PerformanceLog.scrub(
                          json, removing: PerformanceLog.alwaysStripped))
                else { continue }
                let name = String(format: "%d-%04d-%@.json", stamp, i, kind)
                try? clean.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
            // Per kind, so a month of daily metrics cannot push out the crash reports.
            let mine = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix("-\(kind).json") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in mine.dropLast(Self.keep) { try? fm.removeItem(at: old) }
            Task { @MainActor in PerformanceLog.shared.refreshReports() }
        }
    }
}

/// Settings › Advanced › Performance › Diagnostics: the numbers, an export, and a way to throw them away.
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
                Text(log.reportCount == 0 ? "None yet" : "\(log.reportCount) saved")
                    .foregroundStyle(.secondary)
            }
            SettingsRow("Include Mac details in exports") {
                Toggle("Include Mac details in exports", isOn: $includeMac).labelsHidden()
            }
            SettingsRow("Performance data") {
                Button("Clear") { log.clear(); status = "" }
                Button("Export…") { export() }
            }
            Footnote("Measured on this Mac and never sent. Exports contain timings, counts, the Vane version and Apple’s crash and hang reports with their messages and file paths removed — not sites, tabs, Spaces or names. Mac details add the model, macOS version, memory, core count and binary identifiers."
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
