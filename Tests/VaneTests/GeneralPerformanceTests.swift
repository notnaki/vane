import AppKit
import XCTest
@testable import vane

@MainActor final class GeneralPerformanceTests: XCTestCase {
    func testRepeatedAccessibleTabLookupCosts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_ACCESS_PERFORMANCE"] == "1",
                          "Opt-in optimized accessibility lookup measurements")
        try XCTSkipIf(_isDebugAssertConfiguration(), "Use an optimized build (-Xswiftc -O)")
        TestEnvironment.prepare()
        let profile = UUID()
        let store = TabStore(profileID: profile, session: [])
        store.sharingReady = false
        defer {
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            Store.forget(profile)
        }
        store.tabs = (0..<1000).map { _ in Tab(profileID: profile) }
        store.syncShapes()
        for protected in [false, true] {
            var folder = Folder(name: "Protection fixture")
            folder.requiresAuthentication = protected
            store.todayShape = Pins(entries: [.init(row: .folder(folder), parent: nil)]
                + store.tabs.enumerated().map { index, tab in
                    .init(row: .tab(tab.id.uuidString), parent: index == 0 ? folder.id : nil)
                })
            let start = ContinuousClock.now
            for _ in 0..<200 {
                XCTAssertEqual(store.accessibleTabs.count, protected ? 999 : 1000)
            }
            let duration = start.duration(to: .now)
            print("ACCESS_PERFORMANCE protected=\(protected) tabs=1000 repeats=200 duration=\(duration)")
            XCTAssertLessThan(duration, .milliseconds(100), "Repeated lookups must reuse unchanged protection topology")
            let membershipStart = ContinuousClock.now
            var lockedCount = 0
            for _ in 0..<10 {
                for tab in store.tabs where store.isTabLocked(tab.id) { lockedCount += 1 }
            }
            let membershipDuration = membershipStart.duration(to: .now)
            XCTAssertEqual(lockedCount, protected ? 10 : 0)
            print("ACCESS_MEMBERSHIP protected=\(protected) tabs=1000 repeats=10 duration=\(membershipDuration)")
            XCTAssertLessThan(membershipDuration, .milliseconds(100), "Unblocked rows must not rescan all folder entries")
        }
        XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil })
    }

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
