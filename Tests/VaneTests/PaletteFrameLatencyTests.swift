import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

/// Opt-in: per palette interaction, input to the first main-thread display callback and
/// the longest interval between callbacks while it settles (stalls and dropped frames).
/// No CI budget.
@MainActor final class PaletteFrameLatencyTests: XCTestCase {
    func testInteractionFrames() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let suggestionsEnabled = SearchSuggestions.enabled
        SearchSuggestions.enabled = false
        defer { SearchSuggestions.enabled = suggestionsEnabled }
        for count in [28, 300] {
            let profile = ProfileManager.shared.create(name: "Palette frame fixture").id
            let spaces = ["Search", "Neighbour"].map { Space(name: $0, profileID: profile) }
            XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
            let history = Store.store(for: profile)
            _ = history.record((0..<5_000).map { n in
                (URL(string: "https://fixture.invalid/search/\(n)")!, "Search history \(n)",
                 Date(timeIntervalSince1970: 1_791_400_000 - Double(n)))
            })
            let archive = Archive.shared(for: profile)
            // A full archive in the large case: every keystroke searches all of it.
            archive.add((0..<(count == 300 ? Archive.limit : 47)).map { n in
                Archive.Entry(url: "https://fixture.invalid/archived/\(n)", title: "Archived search \(n)",
                              at: Date(timeIntervalSince1970: 1_791_400_000 - Double(n)), space: nil, littleArc: nil)
            })
            let store = TabStore(profileID: profile, space: spaces[0], session: [])
            store.sharingReady = false
            store.palette = nil
            store.tabs = (0..<count).map { i in
                let tab = Tab(profileID: profile)
                tab.park(url: URL(string: "about:blank#fixture-\(i)")!,
                         Parked(title: "Search fixture \(i)", needsRecovery: true))
                return tab
            }
            store.syncShapes()
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            let host = BrowserWindowHost(shown: ShownStore(store))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer {
                archive.clear()
                store.clearSuggestions()
                store.spaceGesture.monitor.remove()
                store.librarySwipeMonitor.remove()
                store.window = nil
                window.contentView = nil
                window.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
                Store.forget(profile)
                ProfileManager.shared.delete(profile)
            }
            try await Task.sleep(for: .milliseconds(300))
            try XCTSkipUnless(window.occlusionState.contains(.visible),
                              "Timing requires a visible window on an unlocked desktop")
            let clock = FrameClock()
            clock.start(on: try XCTUnwrap(window.screen))
            defer { clock.stop() }
            let settle = 0.25, key = 0.16
            func editor() throws -> NSTextView { try XCTUnwrap(window.firstResponder as? NSTextView) }
            // VANE_PALETTE_PROFILE=open|key|arrow repeats one phase for `sample`.
            if let phase = ProcessInfo.processInfo.environment["VANE_PALETTE_PROFILE"] {
                guard count == 300 else { continue }
                if let path = ProcessInfo.processInfo.environment["VANE_PALETTE_PID_FILE"] {
                    try "\(getpid())".write(toFile: path, atomically: true, encoding: .utf8)
                }
                let end = ContinuousClock.now + .seconds(20)
                if phase != "open" { store.palette = .newTab; try await Task.sleep(for: .milliseconds(250)) }
                var n = 0
                while ContinuousClock.now < end {
                    n += 1
                    switch phase {
                    case "open":
                        store.palette = .newTab
                        try await Task.sleep(for: .milliseconds(200))
                        store.palette = nil
                        try await Task.sleep(for: .milliseconds(200))
                    case "arrow":
                        try editor().doCommand(by: n % 6 < 3 ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:)))
                        try await Task.sleep(for: .milliseconds(60))
                    default:
                        let field = try editor()
                        let text = String("search fixture 2".prefix(n % 16 + 1))
                        field.insertText(text, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
                        try await Task.sleep(for: .milliseconds(60))
                    }
                }
                store.palette = nil
                continue
            }
            for iteration in 0..<4 {
                let tag = "tabs=\(count) iteration=\(iteration)"
                var mark = clock.now()
                store.palette = .newTab
                try await Task.sleep(for: .milliseconds(250))
                clock.report("open \(tag)", since: mark, within: settle)
                for text in ["s", "se", "sea", "sear", "search", "search fixture 2"] {
                    let field = try editor()
                    mark = clock.now()
                    field.insertText(text, replacementRange: NSRange(location: 0, length: field.string.utf16.count))
                    // Long enough for history's debounced answer to land inside the window.
                    try await Task.sleep(for: .milliseconds(160))
                    clock.report("key \(tag) text=\(text.count)", since: mark, within: key)
                }
                for _ in 0..<3 {
                    let field = try editor()
                    mark = clock.now()
                    field.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    try await Task.sleep(for: .milliseconds(160))
                    clock.report("arrow \(tag)", since: mark, within: key)
                }
                // Back to the strong tab match, then choose it: close plus Switch to Tab.
                let field = try editor()
                field.insertText("search fixture 2", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
                try await Task.sleep(for: .milliseconds(200))
                mark = clock.now()
                field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                try await Task.sleep(for: .milliseconds(250))
                clock.report("choose \(tag)", since: mark, within: settle)
                XCTAssertNil(store.palette)
                // Escape close from the resting bar.
                store.palette = .newTab
                try await Task.sleep(for: .milliseconds(250))
                let resting = try editor()
                mark = clock.now()
                resting.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                try await Task.sleep(for: .milliseconds(250))
                clock.report("close \(tag)", since: mark, within: settle)
                XCTAssertNil(store.palette)
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

/// Main-thread display-callback times; a stand-in for "a frame could be produced".
@MainActor private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var ticks: [CFTimeInterval] = []
    private(set) var budget = 1.0 / 120
    func now() -> CFTimeInterval { CACurrentMediaTime() }
    func start(on screen: NSScreen) {
        let rate = Float(screen.maximumFramesPerSecond)
        budget = 1 / Double(rate)
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) { ticks.append(CACurrentMediaTime()) }
    func report(_ phase: String, since mark: CFTimeInterval, within window: Double) {
        let inside = ticks.filter { $0 > mark && $0 <= mark + window }
        ticks.removeAll(keepingCapacity: true)
        guard let first = inside.first else { print("PALETTE_FRAME \(phase) callbacks=0"); return }
        var gap = first - mark
        for (a, b) in zip(inside, inside.dropFirst()) { gap = max(gap, b - a) }
        let ms = { (s: Double) in String(format: "%.1f", s * 1000) }
        print("PALETTE_FRAME \(phase) first_ms=\(ms(first - mark)) max_gap_ms=\(ms(gap)) frames=\(inside.count) budget_ms=\(ms(budget)) dropped=\(max(0, Int(gap / budget) - 1))")
    }
    func stop() { link?.invalidate(); link = nil }
}
