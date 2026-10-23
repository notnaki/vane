import XCTest
@testable import vane

@MainActor final class BoostPersistenceWorkerTests: XCTestCase {
    func testDebouncedEditsFlushLatestValueAndKeepProfilesIsolated() async throws {
        let suite = "boost-worker-\(UUID())", profile = UUID(), other = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SiteBoostStore(defaults: defaults, background: true)
        await store.prepare(profiles: [profile, other])
        var boost = SiteBoost()
        for number in 0..<100 {
            boost.css = "body { --revision: \(number) }"
            store.set(boost, origin: "https://example.com", profile: profile)
        }
        XCTAssertEqual(store.get(origin: "https://example.com", profile: profile), boost)
        XCTAssertEqual(store.get(origin: "https://example.com", profile: other), SiteBoost())
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let reopened = SiteBoostStore(defaults: defaults)
        XCTAssertEqual(reopened.get(origin: "https://example.com", profile: profile), boost)
        store.forget(profile: profile)
        let forgotten = await store.flush()
        XCTAssertTrue(forgotten)
        XCTAssertNil(defaults.data(forKey: SiteBoostStore.key(profile)))
        XCTAssertTrue(store.records(profile: profile).isEmpty)
    }

    func testCachedRecordsInvalidateWhenPreferencesAreReplaced() async throws {
        let suite = "boost-cache-\(UUID())", profile = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SiteBoostStore(defaults: defaults, background: true)
        await store.prepare(profiles: [profile])
        var first = SiteBoost(); first.css = String(repeating: "p{}", count: 10_000)
        store.set(first, origin: "https://example.com", profile: profile)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        for _ in 0..<3 { XCTAssertEqual(store.get(origin: "https://example.com", profile: profile), first) }
        var replacement = SiteBoost(); replacement.font = "Georgia"
        defaults.set(try JSONEncoder().encode(["https://example.com": replacement]), forKey: SiteBoostStore.key(profile))
        XCTAssertEqual(store.get(origin: "https://example.com", profile: profile), replacement)
        defaults.set(Data("damaged".utf8), forKey: SiteBoostStore.key(profile))
        XCTAssertTrue(store.records(profile: profile).isEmpty)
    }
}
