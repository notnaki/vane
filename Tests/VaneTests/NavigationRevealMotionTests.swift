import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor private final class NavigationRevealState: ObservableObject {
    @Published var revealed = false
}

private struct NavigationRevealFixture: View {
    @ObservedObject var state: NavigationRevealState
    let tab: vane.Tab

    var body: some View {
        NavButtons(tab: tab)
            .font(Look.icon)
            .foregroundStyle(.white)
            .disabled(!state.revealed)
            .offset(x: state.revealed ? 80 : -80)
            .frame(width: 400, height: 60)
            .background(.black)
            .animation(.linear(duration: 0.4), value: state.revealed)
            .vaneMotionPolicy()
    }
}

/// Sample the actual glyph paint: layout frames alone miss per-button transaction
/// overrides that make disabled controls travel differently from enabled controls.
@MainActor final class NavigationRevealMotionTests: XCTestCase {
    private func glyphCenters(_ host: NSView) throws -> [CGFloat] {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var ranges: [ClosedRange<Int>] = []
        for x in 0..<bitmap.pixelsWide {
            let painted = (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.2
            }
            guard painted else { continue }
            if let last = ranges.last, x - last.upperBound <= 2 {
                ranges[ranges.count - 1] = last.lowerBound...x
            } else {
                ranges.append(x...x)
            }
        }
        return ranges.map { CGFloat($0.lowerBound + $0.upperBound) / (2 * scale) }
    }

    func testEnabledAndDisabledNavigationKeepTheirSpacingThroughoutReveal() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let saver = BatterySaver.shared
            let previousMode = saver.mode
            saver.setMode(.off)
            defer { saver.setMode(previousMode) }
            try XCTSkipIf(Motion.spaceReduced, "Normal-motion render check requires system motion")
            let tab = Tab(isPrivate: true)
            tab.canGoBack = true
            tab.canGoForward = false
            let state = NavigationRevealState()
            let host = NSHostingView(rootView: NavigationRevealFixture(state: state, tab: tab))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 60),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await compatibilityWait {
                NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                    && window.occlusionState.contains(.visible) && host.window === window
                    && (try? self.glyphCenters(host).count) == 3
            }
            let initial = try glyphCenters(host)
            state.revealed = true
            var frames: [[CGFloat]] = []
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(20))
                frames.append(try glyphCenters(host))
            }
            try await Task.sleep(for: .milliseconds(150))
            let final = try glyphCenters(host)
            XCTAssertEqual(final.count, 3)
            guard initial.count == 3, final.count == 3 else { return }
            XCTAssertEqual(final[0] - initial[0], 160, accuracy: 1)
            XCTAssertTrue(frames.contains { $0.count == 3 && $0[0] > initial[0] + 3 && $0[0] < final[0] - 3 },
                          "The render check must observe intermediate sidebar travel")
            for centers in frames {
                XCTAssertEqual(centers.count, 3, "Navigation glyphs must never overlap: \(centers)")
                guard centers.count == 3 else { continue }
                for index in 1...2 {
                    XCTAssertEqual(centers[index] - centers[0], final[index] - final[0], accuracy: 1.5,
                                   "All navigation glyphs must follow the same reveal: \(centers)")
                }
            }
        } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") } }
        if let failure { throw failure }
    }
}
