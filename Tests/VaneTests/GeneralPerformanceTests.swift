import AppKit
import XCTest
@testable import vane

@MainActor final class GeneralPerformanceTests: XCTestCase {
    func testPopulatedSessionCosts() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID(), space = Space(name: "Benchmark", profileID: profile)
        let store = TabStore(profileID: profile, space: space)
        let window = NSWindow()
        store.window = window
        defer {
            store.window = nil
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile)
        }
        for count in [100, 500, 1000] {
            store.tabs = (0..<count).map { _ in Tab(profileID: profile) }
            for tab in store.tabs { tab.presentationOwner = store.windowID }
            store.syncShapes()
            SharedTabs.flush()
            let refresh = ContinuousClock.now
            for _ in 0..<10 { SharedTabs.refreshPresentation() }
            let refreshDuration = refresh.duration(to: .now)
            print("GENERAL_PERFORMANCE \(count) TABS 10_OWNER_REFRESH: \(refreshDuration)")
            // Generous CI budget: the old quadratic pass took over a second locally.
            if count == 1000 { XCTAssertLessThan(refreshDuration, .milliseconds(500)) }
            let rows = ContinuousClock.now
            for _ in 0..<10 {
                let rows = SidebarRows(tabs: store.tabs, splits: store.splits, shape: store.todayShape).rows
                XCTAssertEqual(rows.count, count)
            }
            let rowsDuration = rows.duration(to: .now)
            print("GENERAL_PERFORMANCE \(count) TABS 10_SIDEBAR_ROWS: \(rowsDuration)")
            if count == 1000 { XCTAssertLessThan(rowsDuration, .milliseconds(500)) }
            XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil })
        }
    }
}
