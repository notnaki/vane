import AppKit
import CoreVideo
@preconcurrency import ScreenCaptureKit
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
    private func glyphCenters(_ host: NSView) async throws -> [CGFloat] {
        let window = try XCTUnwrap(host.window)
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let screenRect = window.convertToScreen(host.convert(host.bounds, to: nil))
        configuration.sourceRect = CGRect(x: screenRect.minX - window.frame.minX,
            y: window.frame.maxY - screenRect.maxY, width: host.bounds.width, height: host.bounds.height)
        configuration.width = Int(host.bounds.width * window.backingScaleFactor)
        configuration.height = Int(host.bounds.height * window.backingScaleFactor)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // cacheDisplay can paint a model-layer endpoint before the compositor's
        // intermediate frame. Read the actual displayed glyphs instead.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let data = try XCTUnwrap(image.dataProvider?.data)
        defer { withExtendedLifetime(data) {} }
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8,
              CFDataGetLength(data) >= image.bytesPerRow * image.height else {
            throw NSError(domain: "NavigationCaptureFormat", code: 1)
        }
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let scale = CGFloat(image.width) / host.bounds.width
        var ranges: [ClosedRange<Int>] = []
        for x in 0..<image.width {
            let painted = (0..<image.height).contains { y in bytes[y * image.bytesPerRow + x * 4 + 2] > 51 }
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
        try await exerciseReveal()
    }

    func testHiddenOwnerIsAdmittedBeforeSamplingNavigationReveal() async throws {
        try await exerciseReveal(hideBeforeAdmission: true)
    }

    private func exerciseReveal(hideBeforeAdmission: Bool = false) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
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
            if hideBeforeAdmission { window.orderOut(nil) }
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            var admitted = false
            var admissionGlyphs: [CGFloat] = []
            defer {
                if !admitted {
                    print("NAV_REVEAL_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) owner=\(host.window === window) glyphs=\(admissionGlyphs)")
                }
            }
            try await compatibilityWait {
                if NSApp.isHidden { NSApp.unhide(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                if NSApp.keyWindow !== window || !window.isVisible { window.makeKeyAndOrderFront(nil) }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                guard NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                    && window.occlusionState.contains(.visible) && host.window === window else { return false }
                admissionGlyphs = try await self.glyphCenters(host)
                return admissionGlyphs.count == 3
            }
            admitted = true
            let initial = try await glyphCenters(host)
            state.revealed = true
            var frames: [[CGFloat]] = []
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(20))
                frames.append(try await glyphCenters(host))
            }
            try await Task.sleep(for: .milliseconds(150))
            let final = try await glyphCenters(host)
            XCTAssertEqual(final.count, 3)
            guard initial.count == 3, final.count == 3 else {
                throw NSError(domain: "NavigationRevealGlyphCount", code: 1)
            }
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
