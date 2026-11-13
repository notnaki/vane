import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

@MainActor private final class SidebarSlideState: ObservableObject {
    @Published var visible = false
    let counts = SidebarSlideCounts()
    weak var marker: NSView?
}

private final class SidebarSlideCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var placements = 0
    func place() { lock.withLock { placements += 1 } }
    func reset() { lock.withLock { placements = 0 } }
    var count: Int { lock.withLock { placements } }
}

private struct SidebarSlideMarker: NSViewRepresentable {
    let state: SidebarSlideState
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        state.marker = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct SidebarSlideLayout: Layout {
    let counts: SidebarSlideCounts
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        return proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        counts.place()
        for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

private struct SidebarSlideFixture: View {
    @ObservedObject var state: SidebarSlideState
    let store: TabStore
    var body: some View {
        SidebarSlideLayout(counts: state.counts) { SidebarSlideMarker(state: state) }
            .frame(width: 230, height: 400)
            .modifier(SidebarTrafficLightMotion(store: store, slide: state.visible ? 0 : -240,
                inset: 5, visibility: state.visible ? 1 : 0, libraryOpen: false, peeking: state.visible))
            .frame(width: 600, height: 500, alignment: .leading)
            .animation(.linear(duration: 0.4), value: state.visible)
    }
}

@MainActor final class SidebarSlideWorkTests: XCTestCase {
    // A translation must not place every row/control again for each interpolated
    // offset. Sample real presentation layers as well, so disabling motion cannot
    // satisfy the work budget. Layout may execute off the main actor.
    func testTranslationDoesNotRelayoutUnchangedSidebarContentOnEveryFrame() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await exerciseSlide() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseSlide() async throws {
        let app = NSApplication.shared
        let state = SidebarSlideState()
        let store = TabStore(isPrivate: true, session: [])
        let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: SidebarSlideFixture(state: state, store: store))
        host.wantsLayer = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            window.orderOut(nil); window.contentView = nil; store.window = nil; window.close()
            store.dropStashes(); TabStore.all.removeAll { $0 === store }
        }
        try await compatibilityWait {
            if !app.isActive { app.activate(ignoringOtherApps: true) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            guard app.isRunning, app.isActive, app.keyWindow === window,
                  window.occlusionState.contains(.visible),
                  state.marker?.window === window, state.counts.count > 0,
                  let marker = state.marker?.layer?.presentation(),
                  let root = host.layer?.presentation() else { return false }
            return abs(marker.convert(marker.bounds, to: root).minX + 235) < 0.5
        }
        state.counts.reset()
        state.visible = true
        var samples: [CGFloat] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            if let layer = state.marker?.layer?.presentation(), let root = host.layer?.presentation() {
                samples.append(layer.convert(layer.bounds, to: root).minX)
            }
        }
        let placements = state.counts.count
        print("SIDEBAR_SLIDE_WORK placements=\(placements) samples=\(samples)")
        XCTAssertTrue(samples.contains { $0 > -220 && $0 < -5 }, "The probe must observe actual intermediate sidebar travel")
        XCTAssertEqual(try XCTUnwrap(samples.last), 5, accuracy: 0.5, "The slide must reach the visible endpoint")
        // Allow endpoint reconciliation, but never work proportional to display ticks.
        XCTAssertLessThanOrEqual(placements, 2,
            "A fixed-size sidebar must translate without laying out its unchanged content for every animation step")
    }
}
