import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class ThemeWashSurfaceTests: XCTestCase {
    private func wash(_ hex: String) -> ThemeWash {
        ThemeWash(colors: [ThemeColor(hex: hex)!], strength: 1, opacity: 1, grain: 0)
    }

    func testFloatingCopyKeepsTheWindowWashAndNativeTransitions() throws {
        let source = ThemeWashSurface(), floating = ThemeWashSurface()
        source.apply(wash("#FF0000"), duration: 0)
        source.addCopy(floating)
        XCTAssertEqual(floating.base.colors as? [CGColor], source.base.colors as? [CGColor])
        let animation = CABasicAnimation(keyPath: "colors")
        animation.duration = 0.4
        let token = source.animateNative(from: wash("#FF0000"), to: wash("#0000FF"), animation: animation)
        XCTAssertEqual(floating.base.colors as? [CGColor], source.base.colors as? [CGColor])
        XCTAssertEqual(floating.base.animation(forKey: "colors")?.duration, 0.4)
        source.finishNative(token: token, wash: wash("#0000FF"))
        XCTAssertNil(floating.base.animation(forKey: "colors"))
        source.apply(wash("#00FF00"), duration: 0.2)
        source.finishAnimations()
        XCTAssertNil(floating.base.animation(forKey: "colors"), "Reduced motion must finish both surfaces")
        XCTAssertEqual(floating.base.colors as? [CGColor], source.base.colors as? [CGColor])
    }

    func testFloatingGradientSamplesTheWindowInsteadOfRestartingInsideThePanel() throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let source = ThemeWashSurface(), floating = ThemeWashSurface(copyOrigin: CGPoint(x: -5, y: -5))
        source.frame = window.contentView!.bounds
        window.contentView!.addSubview(source)
        floating.frame = NSRect(x: 5, y: 5, width: 228, height: 490)
        window.contentView!.addSubview(floating)
        defer { window.contentView = nil; window.close() }
        source.apply(ThemeWash(colors: [ThemeColor(hex: "#FF0000")!, ThemeColor(hex: "#00FF00")!,
                                        ThemeColor(hex: "#0000FF")!],
                               strength: 1, opacity: 1, grain: 0), duration: 0)
        source.addCopy(floating)
        source.layoutSubtreeIfNeeded()
        floating.layoutSubtreeIfNeeded()
        XCTAssertEqual(floating.base.frame.size, source.bounds.size,
                       "A panel-width gradient would use different colours from the docked sidebar")
        let expectedFrame = CGRect(x: -5, y: -5, width: 800, height: 500)
        XCTAssertEqual(floating.base.superlayer?.frame, expectedFrame)
        floating.frame.origin = NSPoint(x: 11, y: 11)
        floating.layoutSubtreeIfNeeded()
        XCTAssertEqual(floating.base.superlayer?.frame, expectedFrame,
                       "The wash travels with the floating panel instead of resampling its translated position")
        source.frame.size.width = 1000
        source.layoutSubtreeIfNeeded()
        floating.layoutSubtreeIfNeeded()
        XCTAssertEqual(floating.base.frame.width, 1000, "Resizing must preserve the shared gradient coordinates")
    }

    func testBrowserFloatingSidebarSharesTheWindowWash() async throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Floating colour fixture").id
        let space = Space(name: "Floating colour fixture", profileID: profile, colorHex: "#8190AA",
                          appearance: "dark", tint: 0.4, colors: ["#8190AA", "#759F99", "#AFA3BF"])
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        store.palette = nil
        store.sidebarShown = true
        let window = VaneWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
            .environmentObject(ProfileManager.shared).transaction { $0.disablesAnimations = true })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            store.spaceGesture.monitor.remove()
            window.orderOut(nil); window.contentView = nil; store.window = nil; window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile)
            _ = ProfileManager.shared.delete(profile)
        }
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            guard let source = store.spaceGesture.groundSurface,
                  let copy = store.spaceGesture.groundCopies.allObjects.first else { return false }
            return source.window === window && copy.window === window
                && source.bounds.width == host.bounds.width && copy.bounds.width == SidebarWidth.shared.width
        }
        let source = try XCTUnwrap(store.spaceGesture.groundSurface)
        let copy = try XCTUnwrap(store.spaceGesture.groundCopies.allObjects.first)
        for cycle in 0..<2 {
            if cycle > 0 {
                store.sidebarShown = true
                try await compatibilityWait {
                    host.layoutSubtreeIfNeeded()
                    return abs(copy.convert(copy.bounds, to: host).minX) < 0.5
                }
            }
            store.sidebarShown = false
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return copy.convert(copy.bounds, to: host).maxX <= 0
            }
            store.sidebarPeeking = true
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return abs(copy.convert(copy.bounds, to: host).minX - Look.floatingSidebarGap) < 0.5
            }
            XCTAssertEqual(copy.base.colors as? [CGColor], source.base.colors as? [CGColor])
            XCTAssertEqual(copy.base.frame.size, source.bounds.size)
            XCTAssertEqual(copy.base.superlayer?.frame,
                           CGRect(x: -Look.floatingSidebarGap, y: -Look.floatingSidebarGap,
                                  width: source.bounds.width, height: source.bounds.height))
        }
        // A colour edit while floating must arrive through the original ground owner.
        let green = wash("#00FF00")
        source.apply(green, duration: 0)
        XCTAssertEqual(copy.base.colors as? [CGColor], source.base.colors as? [CGColor])
        source.apply(ThemeWash.space(space, fallback: store.profile, profiles: ProfileManager.shared.profiles,
                                     systemDark: true), duration: 0)
        if let directory = ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("floating-sidebar.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    func testRepeatedDestinationDoesNotInterruptColourBlend() async throws {
        TestEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = ThemeWashSurface()
        window.contentView = surface
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let destination = wash("#0000FF")
        surface.apply(wash("#FF0000"), duration: 0)
        surface.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        surface.apply(destination, duration: 0.5)
        try await Task.sleep(for: .milliseconds(100))
        let animation = try XCTUnwrap(surface.base.animation(forKey: "colors"))
        surface.apply(destination, duration: 0)
        XCTAssertNotNil(surface.base.animation(forKey: "colors"),
                        "The quarter-point page update must not replace a blend with its endpoint")
        XCTAssertEqual(surface.base.animation(forKey: "colors")?.duration, animation.duration)
        let shown = try XCTUnwrap(surface.base.presentation()?.colors?.first) as! CGColor
        let target = try XCTUnwrap(surface.base.colors?.first) as! CGColor
        XCTAssertNotEqual(shown.components, target.components, "The background must still be between colours")
        surface.finishAnimations()
        XCTAssertNil(surface.base.animation(forKey: "colors"), "Reduce Motion must finish immediately")
    }
}
