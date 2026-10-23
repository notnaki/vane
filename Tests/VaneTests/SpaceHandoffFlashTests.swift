import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceHandoffFlashTests: XCTestCase {
    func testCommittedSidebarHandoffDoesNotDoubleCompositeText() async throws {
        try await assertHandoff(returning: false)
    }

    func testCanceledSidebarHandoffDoesNotDoubleCompositeText() async throws {
        try await assertHandoff(returning: true)
    }

    private func assertHandoff(returning: Bool) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires animated handoff")
        let profile = ProfileManager.shared.create(name: "Presented sidebar fixture").id
        let spaces = ["First", "Second"].map { Space(name: $0, profileID: profile) }
        XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
        let store = TabStore(profileID: profile, space: spaces[0], session: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        window.orderFront(nil)
        let monitor = store.spaceGesture.monitor
        monitor.install(store)
        addTeardownBlock { @MainActor in
            monitor.remove()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        for space in spaces {
            store.switchTo(space: space)
            for index in 0..<10 {
                let tab = store.newBlankTab(focus: false)
                tab.park(url: URL(string: "about:blank#\(index)")!, Parked(title: "Document \(index)"))
            }
        }
        store.switchTo(space: spaces[0])
        store.palette = nil
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let sampler = PresentedSidebarSampler(host: host, store: store)
        sampler.start(on: try XCTUnwrap(window.screen))
        defer { sampler.stop() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        if returning {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -8))
            try await Task.sleep(for: .milliseconds(100))
        } else {
            for _ in 0..<10 {
                NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
                try await Task.sleep(for: .milliseconds(8))
            }
        }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        let animationDeadline = ProcessInfo.processInfo.systemUptime + 1
        while store.spaceSwiping, ProcessInfo.processInfo.systemUptime < animationDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.spaceSwiping, "The actual native landing must complete")
        // Retirement waits for SwiftUI's resting-sidebar acknowledgement, separately
        // from landing. Covered endpoint samples cannot stand in for displayed frames
        // after the native cover disappears, especially when callbacks arrive late.
        let handoffDeadline = ProcessInfo.processInfo.systemUptime + 2
        while (host.spaceSlide != nil || sampler.samples.filter { !$0.covered }.count < 4),
              ProcessInfo.processInfo.systemUptime < handoffDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.currentSpaceID, spaces[returning ? 0 : 1].id)
        XCTAssertNil(host.spaceSlide)
        let covered = sampler.samples.filter(\.covered)
        let uncovered = sampler.samples.filter { !$0.covered }
        XCTAssertTrue(sampler.observedGesture, "A display callback must observe the actual gesture")
        XCTAssertGreaterThan(uncovered.count, 3, "Sample several displayed frames after retirement")
        print("HANDOFF_EDGES \(sampler.samples.map { ($0.covered, $0.edges) })")
        let settled = try XCTUnwrap(uncovered.last?.edges)
        XCTAssertGreaterThan(settled, 1, "The destination must contain rendered sidebar text")
        for frame in covered + uncovered {
            XCTAssertLessThan(frame.edges, settled * 1.15,
                              "Live and native text must not brighten through double alpha compositing")
            XCTAssertGreaterThan(frame.edges, settled * 0.85,
                                 "Sidebar content must not disappear for a frame at native handoff")
        }
    }
}

/// Render the presentation tree on display callbacks, outside state-publication callbacks.
@MainActor private final class PresentedSidebarSampler: NSObject {
    struct Sample { let covered: Bool; let edges: Double }
    private weak var host: BrowserWindowHost?
    private weak var store: TabStore?
    private(set) var observedGesture = false
    private var link: CADisplayLink?
    private var reachedEndpoint = false
    var samples: [Sample] = []
    init(host: BrowserWindowHost, store: TabStore) {
        self.host = host
        self.store = store
    }
    func start(on screen: NSScreen) {
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick(_ link: CADisplayLink) {
        guard let host, let layer = host.layer?.presentation() else { return }
        guard let store else { return }
        if store.spaceSwiping { observedGesture = true }
        if observedGesture, !store.spaceSwiping { reachedEndpoint = true }
        guard reachedEndpoint else { return }
        let pixelsWide = max(1, Int(SidebarWidth.shared.width) - 16), pixelsHigh = 280
        guard let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                      bitsPerComponent: 8, bytesPerRow: pixelsWide * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        context.translateBy(x: -8, y: -70)
        layer.render(in: context)
        var edges = 0.0
        for y in stride(from: 0, to: pixelsHigh, by: 2) {
            for x in stride(from: 0, to: pixelsWide - 1, by: 2) {
                let offset = (y * pixelsWide + x) * 4
                for component in 0..<3 {
                    edges += Double(abs(Int(bytes[offset + component]) - Int(bytes[offset + 4 + component]))) / 255
                }
            }
        }
        samples.append(Sample(covered: host.spaceSlide != nil, edges: edges))
    }
}
