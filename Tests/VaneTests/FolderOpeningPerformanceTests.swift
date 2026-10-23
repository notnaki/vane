import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Opt-in diagnostics include deferred layout and animation work, not just the toggle.
@MainActor final class FolderOpeningPerformanceTests: XCTestCase {
    func testUnprotectedFolderAccessibilityScalesWithTheStrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        store.tabs = (0..<3_000).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        let folder = Folder(name: "Documents")
        store.pins = Pins(entries: [.init(row: .folder(folder))] + store.tabs.map {
            .init(row: .tab($0.id.uuidString), parent: folder.id)
        })
        defer {
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(store.accessibleTabs.count, 3_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("FOLDER_ACCESSIBILITY count=3000 ms=\(elapsed * 1000)")
        XCTAssertLessThan(elapsed, 0.1, "Unprotected tabs must not each scan the whole strip for locks")
    }

    func testPopulatedFolderOpening() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        print("FOLDER_POLICY reduceMotion=\(Motion.reduced)")
        for (kind, count) in [(TabKind.pinned, 20), (.pinned, 300), (.today, 20), (.today, 300)] {
            let shape: ReferenceWritableKeyPath<TabStore, Pins> = kind == .pinned ? \.pins : \.todayShape
            let profile = ProfileManager.shared.create(name: "Folder timing").id
            let space = Space(name: "Folder timing", profileID: profile)
            XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
            let store = TabStore(profileID: profile, space: space, session: [])
            store.sharingReady = false
            store.palette = nil
            let folder = Folder(name: "Documents", collapsed: true)
            let tabs = (0..<count).map { index in
                let tab = Tab(profileID: profile)
                tab.kind = kind
                tab.park(url: URL(string: "about:blank#folder-\(index)")!, Parked(title: "Document \(index)"))
                return tab
            }
            store.tabs = tabs
            store[keyPath: shape] = Pins(entries: [.init(row: .folder(folder))] + tabs.map {
                .init(row: .tab($0.id.uuidString), parent: folder.id)
            })
            let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            store.window = window
            let host = NSHostingView(rootView: BrowserWindow().environmentObject(store)
                .environmentObject(ProfileManager.shared))
            window.contentView = host
            defer {
                store.spaceGesture.monitor.remove()
                window.contentView = nil
                store.window = nil
                window.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
                _ = ProfileManager.shared.delete(profile)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            // Forced native layout is useful even on a desktop where XCTest windows
            // remain occluded. Report visibility; these are not displayed frame timings.
            let visible = window.occlusionState.contains(.visible)
            for _ in 0..<3 {
                var gaps: [Double] = []
                var last = ProcessInfo.processInfo.systemUptime
                let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = ProcessInfo.processInfo.systemUptime
                        gaps.append((now - last) * 1000)
                        last = now
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                let start = ProcessInfo.processInfo.systemUptime
                store.toggleFolder(folder.id, in: shape)
                let toggle = (ProcessInfo.processInfo.systemUptime - start) * 1000
                host.layoutSubtreeIfNeeded()
                let layout = (ProcessInfo.processInfo.systemUptime - start) * 1000
                func mountedRows(in view: NSView) -> Int {
                    let own = (view as? TabTooltipAnchorView)?.title.hasPrefix("Document ") == true ? 1 : 0
                    return own + view.subviews.reduce(0) { $0 + mountedRows(in: $1) }
                }
                let mounted = mountedRows(in: host)
                try await Task.sleep(for: .milliseconds(500))
                timer.invalidate()
                XCTAssertFalse(store[keyPath: shape].folder(folder.id)!.collapsed)
                XCTAssertEqual(store[keyPath: shape].visible.count, count + 1)
                XCTAssertGreaterThan(mounted, 0)
                XCTAssertTrue(tabs.allSatisfy { $0.existingWeb == nil })
                print("FOLDER_OPEN kind=\(kind) count=\(count) visible=\(visible) mounted=\(mounted) toggle_ms=\(toggle) layout_ms=\(layout) max_gap_ms=\(gaps.max() ?? 0)")
                if count == 300 { XCTAssertLessThan(mounted, 60) }
                let closeStart = ProcessInfo.processInfo.systemUptime
                store.toggleFolder(folder.id, in: shape)
                host.layoutSubtreeIfNeeded()
                let closeLayout = (ProcessInfo.processInfo.systemUptime - closeStart) * 1000
                try await Task.sleep(for: .milliseconds(500))
                print("FOLDER_CLOSE kind=\(kind) count=\(count) layout_ms=\(closeLayout)")
            }
        }
    }
}
