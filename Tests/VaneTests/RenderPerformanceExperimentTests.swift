import AppKit
import Combine
import SwiftUI
import XCTest
@testable import vane

@MainActor final class RenderPerformanceExperimentTests: XCTestCase {
    private func tab() -> vane.Tab {
        TestEnvironment.prepare()
        let tab = Tab(isPrivate: true, profileID: Profile.incognito.id)
        addTeardownBlock { @MainActor in tab.tearDown() }
        return tab
    }

    func testIsolatedSignalsNotifyTheirConsumersWithoutInvalidatingWholeTab() {
        for isolated in [false, true] {
            let tab = tab(), signals = TabRenderSignals(owner: tab, isolated: isolated)
            var tabUpdates = 0, signalUpdates = 0
            let outer = tab.objectWillChange.sink { tabUpdates += 1 }
            let inner = signals.objectWillChange.sink { signalUpdates += 1 }
            for index in 0..<100 {
                signals.progress = Double(index) / 100
                signals.hoveredLink = .init(url: "https://example.invalid/\(index)", target: .main)
            }
            XCTAssertEqual(signalUpdates, 200)
            XCTAssertEqual(tabUpdates, isolated ? 0 : 200)
            XCTAssertEqual(signals.progress, 0.99)
            XCTAssertEqual(signals.hoveredLink?.url, "https://example.invalid/99")
            XCTAssertNil(tab.existingWeb)
            print("RENDER_SIGNALS isolated=\(isolated) source_updates=\(signalUpdates) whole_tab_updates=\(tabUpdates)")
            tab.title = "Real metadata"
            tab.objectWillChange.send() // Manual name/mute notifications must survive.
            XCTAssertEqual(tabUpdates, (isolated ? 0 : 200) + 2)
            withExtendedLifetime([outer, inner]) {}
        }
    }

    func testTabAccessorsStillDeliverProgressAndHoverToLeafConsumers() {
        let tab = tab()
        var updates = 0
        let subscription = tab.renderSignals.objectWillChange.sink { updates += 1 }
        tab.progress = 0.4
        tab.hoveredLink = .init(url: "https://example.invalid/link", target: .main)
        XCTAssertEqual(tab.renderSignals.progress, 0.4)
        XCTAssertEqual(tab.renderSignals.hoveredLink, tab.hoveredLink)
        XCTAssertEqual(updates, 2)
        withExtendedLifetime(subscription) {}
    }

    func testCacheHitAndStructuralChangesHaveParityInBothModes() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        defer {
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        store.tabs = (0..<100).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        let legacy = Feel02SidebarRowsCache(reuseKeyWithoutAllocations: false)
        let experiment = Feel02SidebarRowsCache(reuseKeyWithoutAllocations: true)
        func compare() {
            let expected = legacy.resolve(in: store, shape: store.todayShape)
            let actual = experiment.resolve(in: store, shape: store.todayShape)
            XCTAssertEqual(actual.rows.map(\.id), expected.rows.map(\.id))
            XCTAssertEqual(actual.rows.map(\.visible.depth), expected.rows.map(\.visible.depth))
            XCTAssertEqual(actual.todayCount, expected.todayCount)
            XCTAssertTrue(zip(actual.rows, expected.rows).allSatisfy { $0.tab === $1.tab })
            XCTAssertTrue(actual === experiment.resolve(in: store, shape: store.todayShape))
        }
        compare()
        store.tabs.swapAt(0, 1); compare()
        store.tabs[0].kind = .pinned; compare()
        store.splits = [Split(tabs: [store.tabs[2].id, store.tabs[3].id])!]; compare()
        store.todayShape = Pins(entries: Array(store.todayShape.entries.reversed())); compare()
        store.tabs[5] = Tab(id: store.tabs[5].id, isPrivate: true, profileID: store.profileID); compare()
    }

    func testNativeHighlightReusesLayerAndHonorsMotionChanges() throws {
        let view = RowHighlightLayerView()
        view.frame = CGRect(x: 0, y: 0, width: 240, height: Look.rowHeight)
        view.layout()
        view.apply(opacity: 0, color: .white, radius: Look.pillRadius, reduced: false)
        XCTAssertNil(view.highlight.animation(forKey: "opacity"), "First mounting must not flash")
        view.apply(opacity: 0.1, color: .white, radius: Look.pillRadius, reduced: false)
        XCTAssertEqual(try XCTUnwrap(view.highlight.animation(forKey: "opacity")).duration, 0.12)
        XCTAssertEqual(view.highlight.frame, view.bounds)
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
        XCTAssertEqual(view.layer?.sublayers?.count, 1)
        view.apply(opacity: 0, color: .white, radius: Look.pillRadius, reduced: false)
        XCTAssertEqual(try XCTUnwrap(view.highlight.animation(forKey: "opacity")).duration, 0.08)
        view.apply(opacity: 0, color: .white, radius: Look.pillRadius, reduced: true)
        XCTAssertNil(view.highlight.animation(forKey: "opacity"))
    }

    func testNativeProgressUsesBoundedLayersAndCutsResetOrReducedMotion() throws {
        let view = LoadingTrackLayerView()
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 2)
        view.apply(progress: 0, reduced: false, track: .gray)
        view.apply(progress: 0.5, reduced: false, track: .gray)
        XCTAssertEqual(view.fill.bounds.width, 60)
        XCTAssertEqual(try XCTUnwrap(view.fill.animation(forKey: "bounds")).duration, 0.25)
        view.apply(progress: 0.5, reduced: true, track: .gray)
        XCTAssertNil(view.fill.animation(forKey: "bounds"))
        view.apply(progress: 0.8, reduced: false, track: .gray)
        view.apply(progress: 0, reduced: false, track: .gray)
        XCTAssertNil(view.fill.animation(forKey: "bounds"), "A new navigation must not sweep backwards")
        XCTAssertEqual(view.fill.bounds.width, 0)
        view.apply(progress: .infinity, reduced: true, track: .gray)
        XCTAssertEqual(view.fill.bounds.width, 0)
        view.apply(progress: 2, reduced: true, track: .gray)
        XCTAssertEqual(view.fill.bounds.width, 120)
        XCTAssertEqual(view.layer?.sublayers?.count, 2)
        XCTAssertNil(view.hitTest(CGPoint(x: 10, y: 1)))
    }

    func testNativeDecorationFollowsAppearanceWithoutAnotherModelUpdate() throws {
        let highlight = RowHighlightLayerView(), loading = LoadingTrackLayerView()
        let ink = Look.nsInk(1)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        highlight.appearance = light
        loading.appearance = light
        highlight.apply(opacity: 0.1, color: ink, radius: 8, reduced: true)
        loading.apply(progress: 0.5, reduced: true, track: ink)
        func brightness(_ color: CGColor?) throws -> CGFloat {
            let color = try XCTUnwrap(color)
            return try XCTUnwrap(NSColor(cgColor: color)?.usingColorSpace(.deviceRGB)).redComponent
        }
        XCTAssertEqual(try brightness(highlight.highlight.backgroundColor), 0, accuracy: 0.01)
        XCTAssertEqual(try brightness(loading.track.backgroundColor), 0, accuracy: 0.01)
        highlight.appearance = dark
        loading.appearance = dark
        // Explicit callback keeps this test independent of a visible desktop.
        highlight.viewDidChangeEffectiveAppearance()
        loading.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(try brightness(highlight.highlight.backgroundColor), 1, accuracy: 0.01)
        XCTAssertEqual(try brightness(loading.track.backgroundColor), 1, accuracy: 0.01)
        XCTAssertEqual(highlight.highlight.opacity, 0.1)
        XCTAssertEqual(loading.fill.bounds.width, 0, "An unattached zero-sized view has no fill width")
    }

    func testTopologyDiagnostic() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_RENDER_BENCHMARK"] == "1",
                          "Opt-in release diagnostic; no machine-dependent timing assertion")
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        defer {
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        for count in [28, 300, 1_000] {
            SharedTabs.release(store.tabs)
            store.tabs = (0..<count).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
            store.syncShapes()
            for fast in [false, true] {
                let cache = Feel02SidebarRowsCache(reuseKeyWithoutAllocations: fast)
                let first = cache.resolve(in: store, shape: store.todayShape)
                for repeatIndex in 0..<5 {
                    let start = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<1_000 { XCTAssertTrue(cache.resolve(in: store, shape: store.todayShape) === first) }
                    print("RENDER_TOPOLOGY tabs=\(count) allocation_free=\(fast) repeat=\(repeatIndex) hits=1000 ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
                }
            }
        }
    }
}
