import AppKit
import SwiftUI
import XCTest
@testable import vane

/// ImageRenderer omits AppKit-backed scroll contents. Capture the hosted sidebar so
/// comparisons include the same native viewport users see during and after a swipe.
@MainActor enum SidebarSnapshot {
    private static var count = 0

    static func pixels<V: View>(_ view: V, width: CGFloat = 250, height: CGFloat = 400, appearance: NSAppearance.Name = .darkAqua) throws -> Data {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: width, height: height)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .background(Color(white: 0.25)))
        host.frame = bounds
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        host.layoutSubtreeIfNeeded()
        return try pixels(in: host)
    }

    static func pixels(in host: NSView) throws -> Data {
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] {
            count += 1
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(count).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
