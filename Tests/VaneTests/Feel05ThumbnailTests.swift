import AppKit
import SwiftUI
import XCTest
@testable import vane

final class Feel05ThumbnailTests: XCTestCase {
    func testMissingAndReplacedFilesInvalidateDecodedAndFailedResults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("picture.png")
        let loader = Feel05ThumbnailLoader()
        let missing = await loader.load(file, knownSignature: nil)
        XCTAssertNil(missing.image)
        func write(width: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file, options: .atomic)
        }
        try write(width: 20)
        let first = await loader.load(file, knownSignature: missing.signature)
        XCTAssertNotNil(first.image)
        XCTAssertFalse(first.unchanged)
        let cached = await loader.load(file, knownSignature: first.signature)
        XCTAssertTrue(cached.unchanged)
        try write(width: 40)
        let replaced = await loader.load(file, knownSignature: first.signature)
        XCTAssertFalse(replaced.unchanged)
        XCTAssertNotEqual(replaced.signature, first.signature)
        XCTAssertEqual(replaced.image?.size.width, 40)
        try FileManager.default.removeItem(at: file)
        let removed = await loader.load(file, knownSignature: replaced.signature)
        XCTAssertNil(removed.image)
        XCTAssertFalse(removed.unchanged)
    }

    @MainActor func testVisibleDownloadPreviewValidatesAnAlreadyCachedImage() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cached.png")
        func write(width: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file, options: .atomic)
        }
        func waitForWidth(_ width: CGFloat) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while Thumbnails.shared.image(for: file)?.size.width != width, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Thumbnails.shared.image(for: file)?.size.width, width)
        }
        try write(width: 20)
        await Thumbnails.shared.requestVisible(file)
        try await waitForWidth(20)
        try write(width: 40)
        let downloads = Downloads(directory: dir, sandboxed: true)
        let item = downloads.add(.init(name: "cached.png", destination: file, state: "done"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: Feel05DownloadThumbnail(item: item))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForWidth(40)
    }

    @MainActor func testHiddenDownloadMountAndCompletionWaitForLatestExposureAndCancelQueuedDecode() async throws {
        try XCTSkipUnless(RenderPerformanceExperiment.hiddenSurfaces,
                          "Run with VANE_RENDER_EXPERIMENT=1 to exercise hidden thumbnail admission")
        TestEnvironment.prepare()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func image(_ name: String, width: Int) throws -> URL {
            let file = dir.appendingPathComponent(name)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            return file
        }
        let first = try image("mounted.png", width: 20)
        let completed = try image("completed.png", width: 40)
        let latest = try image("latest.png", width: 60)
        let downloads = Downloads(directory: dir, sandboxed: true)
        let done = downloads.add(.init(name: "mounted.png", destination: first, state: "done"))
        let finishing = downloads.add(.init(name: "completed.png", destination: completed, state: "running"))
        let loader = Feel05ThumbnailLoader()
        var requests: [URL] = []
        let thumbnails = Thumbnails(loader: loader, didRequestVisible: { requests.append($0) })
        let gate = Feel05DecodeGate()
        let blocking = Task.detached { await loader.hold(gate) }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertEqual(entered, .success)
        defer { gate.release.signal() }
        let activity = Feel05ThumbnailActivity()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: Feel05HiddenThumbnailFixture(
            activity: activity, mounted: done, finishing: finishing, thumbnails: thumbnails))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(requests.isEmpty, "A completed image mounted in the hidden retained list must not request a decode")
        finishing.status = .done
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(requests.isEmpty, "Completing while hidden must not admit the newly mounted image branch")
        activity.active = true
        let admittedDeadline = ContinuousClock.now + .seconds(2)
        while requests.count < 2, ContinuousClock.now < admittedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(requests), Set([first, completed]))
        activity.active = false
        try await Task.sleep(for: .milliseconds(100))
        gate.release.signal()
        await blocking.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(thumbnails.image(for: first))
        XCTAssertNil(thumbnails.image(for: completed))
        XCTAssertEqual(thumbnails.revision, 0, "Hiding must cancel queued decodes and revoke late publication")
        finishing.url = latest
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(requests.count, 2, "A hidden file replacement must not schedule work")
        activity.active = true
        let visibleDeadline = ContinuousClock.now + .seconds(3)
        while thumbnails.image(for: latest) == nil, ContinuousClock.now < visibleDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(thumbnails.image(for: latest)?.size.width, 60)
        XCTAssertEqual(requests.filter { $0 == completed }.count, 1,
                       "Re-exposure must request the current file, not replay the cancelled old destination")
        XCTAssertEqual(requests.filter { $0 == latest }.count, 1)
    }

    @MainActor func testVisibleRequestOwnsQueuedWorkAndDropsCancelledResults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("queued.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let loader = Feel05ThumbnailLoader()
        let thumbnails = Thumbnails(loader: loader)
        let gate = Feel05DecodeGate()
        let blocking = Task.detached { await loader.hold(gate) }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertEqual(entered, .success)
        defer { gate.release.signal() }
        var started = false
        var returned = false
        let visible = Task {
            started = true
            await thumbnails.requestVisible(file)
            returned = true
        }
        while !started { await Task.yield() }
        // The worker is blocked, so a structured request cannot have completed yet.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(returned)
        visible.cancel()
        gate.release.signal()
        await blocking.value
        await visible.value
        XCTAssertNil(thumbnails.image(for: file))
        XCTAssertEqual(thumbnails.revision, 0)
        await thumbnails.requestVisible(file)
        XCTAssertEqual(thumbnails.image(for: file)?.size.width, 20)
        XCTAssertEqual(thumbnails.revision, 1)
    }

    func testCancelledQueuedDecodeSkipsImageIO() async throws {
        let loader = Feel05ThumbnailLoader()
        let gate = Feel05DecodeGate()
        let blocking = Task.detached { await loader.hold(gate) }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertEqual(entered, .success)
        defer { gate.release.signal() }
        let queued = Task { await loader.load(URL(fileURLWithPath: "/nonexistent/feel05.png"), knownSignature: nil) }
        queued.cancel()
        gate.release.signal()
        await blocking.value
        let result = await queued.value
        XCTAssertTrue(result.unchanged, "Cancellation must skip metadata and ImageIO, not cache a missing-file result")
    }

    @MainActor func testFireAndForgetRequestSurvivesAFullDecodeBacklog() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("last.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        let loader = Feel05ThumbnailLoader()
        let thumbnails = Thumbnails(loader: loader)
        let gate = Feel05DecodeGate()
        let blocking = Task.detached { await loader.hold(gate) }
        let entered = await Task.detached { gate.waitForEntry() }.value
        XCTAssertEqual(entered, .success)
        defer { gate.release.signal() }
        // Before the worker can drain anything, fill its entire admission budget.
        for index in 0..<64 {
            let queued = dir.appendingPathComponent("queued-\(index).png")
            try FileManager.default.linkItem(at: file, to: queued)
            thumbnails.want(queued)
        }
        thumbnails.want(file)
        // Repeated fallback requests must coalesce rather than multiply work.
        for _ in 0..<100 { thumbnails.want(file) }
        gate.release.signal()
        await blocking.value
        let deadline = ContinuousClock.now + .seconds(5)
        while thumbnails.revision < 65, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(thumbnails.image(for: file)?.size.width, 20,
                       "The one-shot caller cannot retry a request dropped at capacity")
        XCTAssertEqual(thumbnails.revision, 65)
    }

}


private final class Feel05DecodeGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitForEntry() -> DispatchTimeoutResult { entered.wait(timeout: .now() + 5) }
}

private extension Feel05ThumbnailLoader {
    func hold(_ gate: Feel05DecodeGate) {
        gate.entered.signal()
        _ = gate.release.wait(timeout: .now() + 10)
    }
}


@MainActor private final class Feel05ThumbnailActivity: ObservableObject {
    @Published var active = false
}

private struct Feel05HiddenThumbnailFixture: View {
    @ObservedObject var activity: Feel05ThumbnailActivity
    let mounted: Downloads.Item
    let finishing: Downloads.Item
    let thumbnails: Thumbnails
    var body: some View {
        VStack {
            Feel05DownloadThumbnail(item: mounted, thumbnails: thumbnails)
            Feel05DownloadThumbnail(item: finishing, thumbnails: thumbnails)
        }
        .environment(\.renderSurfaceActive, activity.active)
    }
}
