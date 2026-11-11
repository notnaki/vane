import AppKit
import XCTest
import SwiftUI
@testable import vane

@MainActor final class GlobalUpdatePillTests: XCTestCase {
    func testUpdatePillRemainsActionableAcrossProfilesWithRetainedSearch() async throws {
        try await run(savingBattery: false, sidebarShown: true)
    }

    func testHiddenSidebarUpdatePillSurvivesProfileHopsWithBatterySaver() async throws {
        try await run(savingBattery: true, sidebarShown: false)
    }

    private func run(savingBattery: Bool, sidebarShown: Bool) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        var ownedProfiles = Set<UUID>()
        do {
            try await exerciseProfileHops(savingBattery: savingBattery, sidebarShown: sidebarShown,
                                         ownedProfiles: &ownedProfiles)
        }
        catch { failure = error }
        do { try await NativeFixtureProfileCleanup.release(ownedProfiles) } catch {
            if failure == nil { failure = error } else { XCTFail("Profile cleanup failed: \(error)") }
        }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Loop cleanup failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseProfileHops(savingBattery: Bool, sidebarShown: Bool,
                                     ownedProfiles: inout Set<UUID>) async throws {
        let manager = ProfileManager.shared
        let previous = manager.active
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(savingBattery ? .alwaysOn : .off)
        let width = SidebarWidth.shared.width
        SidebarWidth.shared.width = 228
        let firstProfile = manager.create(name: "Update source")
        let secondProfile = manager.create(name: "Update destination")
        ownedProfiles.formUnion([firstProfile.id, secondProfile.id])
        let first = manager.createSpace(name: "First", in: firstProfile.id)
        let second = manager.createSpace(name: "Second", in: secondProfile.id)
        let source = Windows.open(profile: firstProfile, space: first, focus: false)
        let window = try XCTUnwrap(source.window)
        let host = try XCTUnwrap(window.contentView)
        let toasts = Toasts.shared
        toasts.showing.forEach { toasts.dismiss($0) }
        defer {
            toasts.showing.forEach { toasts.dismiss($0) }
            window.close()
            _ = manager.delete(firstProfile.id)
            _ = manager.delete(secondProfile.id)
            manager.active = previous
            BatterySaver.shared.setMode(mode)
            SidebarWidth.shared.width = width
        }
        source.sidebarShown = sidebarShown
        source.palette = nil
        // Warm both roots before the update arrives. Parked roots receive the
        // same app-wide notices while their native hosting view is hidden.
        try await admit(source, host: host, window: window)
        let sourceBefore = try pixels(host)
        let warmed = try XCTUnwrap(Windows.hop(source, to: second))
        warmed.palette = .address
        try await admit(warmed, host: host, window: window)
        let targetBefore = try pixels(host)
        _ = try XCTUnwrap(Windows.hop(warmed, to: first))
        try await admit(source, host: host, window: window)
        let id = UUID()
        var actions = 0
        Toasts.stick("Downloading… 42%", id: id)
        try await admit(source, host: host, window: window)
        try await assertPill(in: host, baseline: sourceBefore)
        let sourceProgress = try pixels(host)
        let target = try XCTUnwrap(Windows.hop(source, to: second))
        try await admit(target, host: host, window: window)
        try await assertPill(in: host, baseline: targetBefore)
        let targetProgress = try pixels(host)
        Toasts.stick("Update ready — global regression fixture", id: id, action: ("Restart", { actions += 1 }))
        let ready = try XCTUnwrap(toasts.queue.sticky)
        for destination in [first, second] {
            let current = try XCTUnwrap(TabStore.all.first { $0.window === window })
            let arriving = try XCTUnwrap(Windows.hop(current, to: destination))
            try await admit(arriving, host: host, window: window)
            try await assertPill(in: host, baseline: destination.id == first.id ? sourceProgress : targetProgress)
            XCTAssertEqual(toasts.queue.sticky?.actionGeneration, ready.actionGeneration)
        }
        let label = ImageRenderer(content: Text("Restart").font(Look.Typography.shortcut.font).fixedSize())
        let actionWidth = try XCTUnwrap(label.nsImage).size.width + Look.inset
        let leading: CGFloat = sidebarShown ? 0 : 16 - Look.inset
        let dismissLeft = leading + SidebarWidth.shared.width - Look.inset - Look.inset / 2 - Look.rowTarget
        let pill = ImageRenderer(content: ToastPill(toast: ready, tint: .clear)
            .frame(width: SidebarWidth.shared.width - 2 * Look.inset))
        let height = try XCTUnwrap(pill.nsImage).size.height
        let point = CGPoint(x: dismissLeft - Look.inset / 2 - actionWidth / 2,
                            y: (sidebarShown ? Look.footer + Look.footerInset + 2 * Look.inset : 16) + height / 2)
        try await admit(target, host: host, window: window)
        _ = try pixels(host)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            // Match the native event cadence used by ToastPresentationTests.
            try await Task.sleep(for: .milliseconds(30))
        }
        try await compatibilityWait { actions == 1 }
        XCTAssertEqual(actions, 1)
        XCTAssertNil(toasts.queue.sticky)
    }

    private func admit(_ store: TabStore, host: NSView, window: NSWindow) async throws {
        try await compatibilityWait {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                && window.isVisible && window.contentView === host && host.window === window
                && store.window === window && store.profileVisible
        }
        // Allow the submitted SwiftUI graph to complete its display turn.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func assertPill(in host: NSView, baseline: Data) async throws {
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            guard let current = try? pixels(host) else { return false }
            return zip(current, baseline).filter { abs(Int($0) - Int($1)) > 20 }.count > 500
        }
    }

    private func pixels(_ host: NSView) throws -> Data {
        let rect = CGRect(x: 0, y: 0, width: SidebarWidth.shared.width + 16, height: 160)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let file = URL(fileURLWithPath: directory).appendingPathComponent("\(UUID()).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: file)
        }
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

}
