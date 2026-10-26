import AppKit
import QuartzCore
import Darwin

/// Opt-in diagnosis only. No observable state, display link, layout, or AX queries.
@MainActor final class SidebarScrollTrace {
    static let enabled = ProcessInfo.processInfo.environment["VANE_DIAG_SCROLL_TRACE"] == "1"
    private static var claimed = false
    private static weak var activeTrace: SidebarScrollTrace?
    private struct Record: Codable, Sendable {
        var kind: Int = 0 // 1=input, 2=bounds, 3=start, 4=end, 5=row-window update
        var rowLower: Int?
        var rowUpper: Int?
        var rowCount: Int?
        var ticks: UInt64 = 0
        var uptime: Double = 0
        var eventTime: Double = 0
        var phase: UInt = 0
        var momentum: UInt = 0
        var dx: Double = 0
        var dy: Double = 0
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        var documentHeight: Double = 0
        var key = false
        var active = false
        var visible = false
        var hit = false
    }
    private struct Export: Codable, Sendable {
        let pid: Int32
        let reason: String
        let dropped: Int
        let timebaseNumer: UInt32
        let timebaseDenom: UInt32
        let records: [Record]
    }
    private weak var clip: NSClipView?
    private weak var marker: NSView?
    private var input: Any?
    private var bounds: NSObjectProtocol?
    private var deadline: DispatchWorkItem?
    private var buffer = Array(repeating: Record(), count: 32768)
    private var used = 0
    private var dropped = 0
    private var armed = false
    private var finished = false
    private let output: URL

    init(clip: NSClipView, marker: NSView) {
        self.clip = clip
        self.marker = marker
        output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "vane-scroll-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).json")
        // One startup log; never log in the input/bounds paths.
        print("VANE_DIAG_SCROLL_TRACE output=\(output.path)")
        clip.postsBoundsChangedNotifications = true
        bounds = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordBounds() }
            }
        input = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return event
        }
    }

    private func snapshot(kind: Int) -> Record {
        var record = Record()
        record.kind = kind
        record.ticks = mach_absolute_time()
        record.uptime = ProcessInfo.processInfo.systemUptime
        if let clip {
            let rect = clip.bounds
            record.x = rect.minX; record.y = rect.minY
            record.width = rect.width; record.height = rect.height
            record.documentHeight = Double(clip.documentView?.bounds.height ?? 0)
            record.key = clip.window?.isKeyWindow ?? false
            record.active = NSApp.isActive
            record.visible = clip.window?.occlusionState.contains(.visible) == true
                && !clip.isHiddenOrHasHiddenAncestor
        }
        return record
    }
    private func append(_ record: Record) {
        guard used < buffer.count else { dropped += 1; return }
        buffer[used] = record
        used += 1
    }
    static func recordRowWindow(_ range: Range<Int>, count: Int, clip: NSClipView?) {
        guard enabled, let clip, let trace = activeTrace, trace.clip === clip,
              trace.armed, !trace.finished else { return }
        var record = trace.snapshot(kind: 5)
        record.rowLower = range.lowerBound
        record.rowUpper = range.upperBound
        record.rowCount = count
        trace.append(record)
    }
    private func receive(_ event: NSEvent) {
        guard !finished, armed || !Self.claimed, event.hasPreciseScrollingDeltas,
              let clip, let marker, let window = clip.window, event.window === window else { return }
        if !armed && (marker.isHiddenOrHasHiddenAncestor || clip.isHiddenOrHasHiddenAncestor) { return }
        let point = clip.convert(event.locationInWindow, from: nil)
        let hit = clip.visibleRect.contains(point) && !marker.isHiddenOrHasHiddenAncestor
            && !clip.isHiddenOrHasHiddenAncestor
        if !armed {
            guard !Self.claimed, hit, window.isKeyWindow, NSApp.isActive,
                  window.occlusionState.contains(.visible) else { return }
            Self.claimed = true
            armed = true
            Self.activeTrace = self
            append(snapshot(kind: 3))
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.finish(reason: "deadline") }
            }
            deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        }
        var record = snapshot(kind: 1)
        record.eventTime = event.timestamp
        record.phase = event.phase.rawValue
        record.momentum = event.momentumPhase.rawValue
        record.dx = event.scrollingDeltaX; record.dy = event.scrollingDeltaY
        record.hit = hit
        append(record)
    }
    private func recordBounds() {
        guard armed, !finished else { return }
        append(snapshot(kind: 2))
    }
    func detach() {
        finish(reason: "detached")
        if let input { NSEvent.removeMonitor(input); self.input = nil }
        if let bounds { NotificationCenter.default.removeObserver(bounds); self.bounds = nil }
    }
    private func finish(reason: String) {
        guard armed, !finished else { return }
        append(snapshot(kind: 4))
        finished = true
        if Self.activeTrace === self { Self.activeTrace = nil }
        deadline?.cancel(); deadline = nil
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let export = Export(pid: ProcessInfo.processInfo.processIdentifier, reason: reason,
            dropped: dropped, timebaseNumer: timebase.numer, timebaseDenom: timebase.denom,
            records: Array(buffer.prefix(used)))
        let destination = output
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(export)
                try data.write(to: destination, options: .atomic)
            } catch {
                print("VANE_DIAG_SCROLL_TRACE write failed: \(error)")
            }
        }
    }
}
