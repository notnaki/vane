import XCTest
@testable import vane

@MainActor final class HistorySearchTests: XCTestCase {
    func testDateRangeIsInclusiveAtStartAndExclusiveAtEnd() async throws {
        TestEnvironment.prepare()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(path: dir.appendingPathComponent("history.db").path)
        let page = URL(string: "https://example.com")!
        store.record([("Before", 99.0), ("Start", 100.0), ("Inside", 199.0), ("End", 200.0)].map {
            (page, $0.0, Date(timeIntervalSince1970: $0.1))
        })
        let range = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let visits = await store.historyAsync(interval: range)
        XCTAssertEqual(visits.map(\.title), ["Inside", "Start"])
        XCTAssertEqual(store.history(matching: "start", interval: range).map(\.title), ["Start"])
        XCTAssertTrue(store.history(matching: "end", interval: range).isEmpty)
        XCTAssertTrue(store.history(limit: 0).isEmpty)
    }

    func testYesterdayUsesCalendarDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let yesterday = try XCTUnwrap(HistoryPeriod.yesterday.interval(now: now, calendar: calendar))
        XCTAssertEqual(yesterday.duration, 23 * 3600)
        XCTAssertEqual(calendar.component(.day, from: yesterday.start), 8)
        XCTAssertEqual(calendar.component(.day, from: yesterday.end), 9)
        XCTAssertNil(HistoryPeriod.all.interval(now: now, calendar: calendar))
    }

    func testIndependentTitleRankingAndStableTies() {
        let pages = [("Swift", "https://long.example/swift"), ("Swift resources", "https://a.example"),
                     ("Swift", "https://other.example")]
        XCTAssertEqual(Palette.rankPages("swift", pages, title: { $0.0 }, url: { $0.1 }).map { $0.1 },
                       ["https://long.example/swift", "https://other.example", "https://a.example"])
        XCTAssertTrue(Palette.rankPages("ab", [("a", "b")], title: { $0.0 }, url: { $0.1 }).isEmpty)
    }

    func testTabSourcesCannotCrossProfilesOrPrivateWindows() {
        let profile = UUID(), other = UUID()
        func allowed(_ source: UUID, privateWindow: Bool = false, own: Bool = false,
                     requestingPrivate: Bool = false, little: Bool = false) -> Bool {
            Palette.tabSourceAllowed(profileID: profile, isPrivate: requestingPrivate, ownWindow: own,
                                     sourceProfileID: source, sourcePrivate: privateWindow, sourceLittle: little)
        }
        XCTAssertTrue(allowed(profile))
        XCTAssertFalse(allowed(other))
        XCTAssertFalse(allowed(profile, privateWindow: true))
        XCTAssertFalse(allowed(profile, requestingPrivate: true))
        XCTAssertFalse(allowed(profile, little: true))
        XCTAssertTrue(allowed(profile, privateWindow: true, own: true, requestingPrivate: true))
    }

    func testHistoryReadsStayInTheRequestedProfile() async {
        TestEnvironment.prepare()
        let first = UUID(), second = UUID()
        defer { Store.forget(first); Store.forget(second) }
        Store.store(for: first).record(URL(string: "https://first.example")!, title: "Shared phrase first")
        Store.store(for: second).record(URL(string: "https://second.example")!, title: "Shared phrase second")
        let visits = await Store.store(for: first).historyAsync(matching: "shared phrase")
        XCTAssertEqual(visits.map(\.url), ["https://first.example"])
        let privateVisits = await Store.store(for: Profile.incognito.id).historyAsync(matching: "shared phrase")
        XCTAssertTrue(privateVisits.isEmpty)
    }
}
