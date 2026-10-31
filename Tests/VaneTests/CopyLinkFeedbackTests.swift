import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class CopyLinkFeedbackTests: XCTestCase {
    private var frame = 0
    func testCheckmarkFinishesPromptlyAndUsesAdaptiveNeutralInk() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Symbol timing requires system motion")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        let saver = BatterySaver.shared
        let mode = saver.mode
        defer { saver.setMode(mode); app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            saver.setMode(.off)
            let state = CopyGlyphState()
            let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 100, height: 60),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = "Copy link feedback fixture"
            let host = NSHostingView(rootView: CopyGlyphSurface(state: state))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            defer { window.contentView = nil; window.close() }
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return app.isRunning && app.isActive && app.keyWindow === window && window.isKeyWindow
                    && window.isVisible && window.occlusionState.contains(.visible)
                    && app.modalWindow == nil && window.attachedSheet == nil && host.window === window
                    && state.mounted && host.bounds.size == CGSize(width: 100, height: 60)
            }
            let idle = try pixels(host)
            state.copied = true
            try await Task.sleep(for: .milliseconds(250))
            let prompt = try pixels(host)
            XCTAssertGreaterThan(difference(prompt, idle), 10, "Copy must visibly acknowledge the action promptly")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertLessThanOrEqual(difference(prompt, try pixels(host)), 2,
                                     "The checkmark must be settled by 250ms, rather than still replacing the link")
            try assertNeutralInk(in: host, dark: true)
            window.appearance = NSAppearance(named: .aqua)
            host.rootView = CopyGlyphSurface(state: state, dark: false)
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return !state.presentedDark && host.window === window
                    && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            }
            try assertNeutralInk(in: host, dark: false)
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Copy feedback loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func pixels(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_COPY_FEEDBACK_CAPTURE_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent("copy-\(frame).png"))
            frame += 1
        }
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func assertNeutralInk(in host: NSView, dark: Bool) throws {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var visibleInk = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let high = max(color.redComponent, color.greenComponent, color.blueComponent)
                let low = min(color.redComponent, color.greenComponent, color.blueComponent)
                if (dark ? high : 1 - low) > 0.2 {
                    visibleInk += 1
                    XCTAssertLessThan(high - low, 0.04, "Confirmation ink must be neutral, without an accent tint")
                }
            }
        }
        XCTAssertGreaterThan(visibleInk, 10, "The checkmark must remain visible against both light and dark backgrounds")
    }

    private func difference(_ lhs: Data, _ rhs: Data) -> Int {
        guard lhs.count == rhs.count else { return 255 }
        return zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}

@MainActor private final class CopyGlyphState: ObservableObject {
    @Published var copied = false
    var mounted = false
    var presentedDark = true
}

private struct CopyGlyphSurface: View {
    @ObservedObject var state: CopyGlyphState
    var dark = true
    var body: some View {
        CopyLinkGlyph(copied: state.copied).font(.system(size: 14))
            .frame(width: 100, height: 60).background(dark ? Color.black : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
            .onAppear { state.mounted = true }
            .onChange(of: dark, initial: true) { _, dark in state.presentedDark = dark }
    }
}
