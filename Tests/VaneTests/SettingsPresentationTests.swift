import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SettingsPresentationTests: XCTestCase {
    func testLandingPanesFitMinimumWindowInBothThemes() throws {
        TestEnvironment.prepare()
        for id in ["general", "advanced"] {
            let tab = try XCTUnwrap(SettingsTab.all.first { $0.id == id })
            for dark in [false, true] {
                let host = NSHostingView(rootView: tab.pane(SettingsSelection())
                    .font(Look.text).controlSize(.small).toggleStyle(.switch).defaultAppStorage(.vane)
                    .frame(width: 632)
                    .background(.windowBackground)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let size = host.fittingSize
                XCTAssertEqual(size.width, 632, accuracy: 1)
                XCTAssertLessThan(size.height, 410,
                    "The landing pane should fit below the toolbar at the minimum window size")
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                if let path = ProcessInfo.processInfo.environment["VANE_SETTINGS_SNAPSHOTS"] {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("\(id)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func testNativeDisclosureExpandsAndCollapsesItsControls() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire()
        do {
            try await exerciseDisclosure()
        } catch {
            try await loop.close()
            throw error
        }
        try await loop.close()
    }

    private func exerciseDisclosure() async throws {
        let host = NSHostingView(rootView: SettingsDisclosure("Windows and Tabs",
            summary: "Startup and homepage", icon: "macwindow", tint: .green) {
                SettingsCard {
                    SettingsRow("Homepage", icon: "house.fill", tint: .green) {
                        Text("example.test")
                    }
                }
            }
            .padding(20).frame(width: 632)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 632, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await compatibilityWait { window.isVisible && host.window === window }
        host.layoutSubtreeIfNeeded()
        let collapsedHeight = host.fittingSize.height
        // The native header moves upward as its centered content grows.
        func trianglePoint() -> NSPoint {
            host.layoutSubtreeIfNeeded()
            let offset = host.fittingSize.height / 2 - 20 - Look.settingsRow / 2
            let y = host.bounds.midY + (host.isFlipped ? -offset : offset)
            return host.convert(NSPoint(x: 25, y: y), to: nil)
        }
        try click(trianglePoint(), in: window)
        try await compatibilityWait { host.fittingSize.height > collapsedHeight + 30 }
        try click(trianglePoint(), in: window)
        try await compatibilityWait { abs(host.fittingSize.height - collapsedHeight) < 1 }
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}
