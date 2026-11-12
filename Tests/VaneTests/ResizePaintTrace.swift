import Foundation
@testable import vane

#if DEBUG
/// A fixture owns this bounded log. Capture callbacks can append off-main; JSON
/// encoding and output happen only after the stream has stopped.
final class ResizePaintTrace: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let event: String
        let time: TimeInterval
        let fields: [String: String]
    }

    let attempt = UUID().uuidString
    let label: String
    private let limit: Int
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var dropped = 0
    @MainActor private var restoreSinks: (() -> Void)?

    init(label: String, limit: Int = 20_000) {
        self.label = label
        self.limit = max(0, limit)
        entries.reserveCapacity(min(self.limit, 8192))
    }

    func append(_ event: String, time: TimeInterval, fields: [String: String] = [:]) {
        lock.withLock {
            guard entries.count < limit else { dropped += 1; return }
            entries.append(Entry(event: event, time: time, fields: fields))
        }
    }

    @MainActor func install() {
        guard restoreSinks == nil else { return }
        let timing = ResizeTimingDiagnostics.sink
        let state = ResizeTimingDiagnostics.stateSink
        restoreSinks = {
            ResizeTimingDiagnostics.sink = timing
            ResizeTimingDiagnostics.stateSink = state
        }
        ResizeTimingDiagnostics.sink = { [weak self] event, time, width, height in
            self?.append(event, time: time, fields: [
                "width": width.map { String(Double($0)) } ?? "nil",
                "height": height.map { String(Double($0)) } ?? "nil"
            ])
        }
        ResizeTimingDiagnostics.stateSink = { [weak self] event, time, fields in
            self?.append(event, time: time, fields: fields)
        }
    }

    @MainActor func stop() {
        restoreSinks?()
        restoreSinks = nil
    }

    func snapshot() -> (entries: [Entry], dropped: Int) {
        lock.withLock { (entries, dropped) }
    }

    func encodedEntries() throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try snapshot().entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    }

    func dump() {
        let snapshot = snapshot()
        print("RESIZE_PAINT_TRACE_BEGIN attempt=\(attempt) label=\(label)")
        do {
            for line in try encodedEntries() { print("RESIZE_PAINT_TRACE \(line)") }
        } catch {
            print("RESIZE_PAINT_TRACE_ENCODING_ERROR \(error)")
        }
        print("RESIZE_PAINT_TRACE_END attempt=\(attempt) events=\(snapshot.entries.count) dropped=\(snapshot.dropped)")
    }
}
#endif
