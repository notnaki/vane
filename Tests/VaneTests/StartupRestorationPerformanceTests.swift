import AppKit
import XCTest
@testable import vane

/// Opt-in measurements, deliberately without wall-clock assertions in routine CI.
@MainActor final class StartupRestorationPerformanceTests: XCTestCase {
    func testRestorationPhases() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STARTUP_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = ProfileManager.shared.active
        let space = Space(name: "Startup benchmark", profileID: profile.id)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
        let file = ProfileManager.sessionURL(for: profile.id, in: Store.directory)
        for count in [10, 100, 500, 1000] {
            let entries = (0..<count).map { index in
                Session.Entry(id: UUID().uuidString, url: "http://127.0.0.1:9/fixture/\(index)",
                              title: "Synthetic tab \(index)",
                              state: Data(repeating: 65, count: 4096).base64EncodedString(),
                              kind: .pinned)
            }
            let data = try XCTUnwrap(Session.encode([entries], spaces: [space.id.uuidString]))
            try data.write(to: file)
            for run in 0..<3 {
                func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = try work()
                    print("STARTUP_PHASE count=\(count) run=\(run) phase=\(label) ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
                    return result
                }
                _ = try timed("disk-read") { try Data(contentsOf: file) }
                _ = timed("one-decode") { Session.decode(data) }
                let rows = timed("restore-input") { () -> [Session.Entry] in
                    #if VANE_STARTUP_LEGACY_PIPELINE
                    // Copy this opt-in fixture to the baseline checkout with this flag.
                    // This is the input pipeline used before the single-snapshot reader.
                    let read = RecoverySnapshots.read(file, valid: Session.readable)!
                    _ = (try? Data(contentsOf: file)).map(Session.readable)
                    _ = Session.decodeSplits(read)
                    _ = ProfileManager.shared.ensureSpaces(for: profile, sessionTabs: Session.urls(for: profile.id))
                    _ = Session.decodeSpaces(read)
                    _ = Session.decodeSelected(read)
                    _ = Session.decode(read) // The old version probe also decoded the whole document.
                    return Session.decode(read)[0]
                    #else
                    let loaded = Session.load(file)!
                    _ = ProfileManager.shared.ensureSpaces(for: profile, sessionTabs: loaded.snapshot.urls)
                    return loaded.snapshot.windows[0]
                    #endif
                }
                let store = timed("parked-tab-construction") {
                    TabStore(profileID: profile.id, space: space, session: rows)
                }
                XCTAssertEqual(store.tabs.count, count)
                XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil })
                let blank = timed("new-blank-tab") { store.newBlankTab(focus: false) }
                XCTAssertNil(blank.existingWeb)
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
                await Task.yield()
            }
        }
    }
    func testFirstPageAndSleepingActivation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STARTUP_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let oldHTTPS = HTTPSOnly.enabled
        HTTPSOnly.enabled = false
        defer { HTTPSOnly.enabled = oldHTTPS }
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        for count in [10, 100, 500] {
            let profile = ProfileManager.shared.active
            let space = Space(name: "Page readiness benchmark", profileID: profile.id)
            XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile.id))
            let entries = try (0..<count).map { index in
                Session.Entry(id: UUID().uuidString, url: try server.url("/tab-\(index)").absoluteString,
                              title: "Synthetic tab \(index)", kind: .pinned)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let store = Windows.open(profile: profile, space: space, session: entries)
            let presented = ProcessInfo.processInfo.systemUptime
            let tab = try XCTUnwrap(store.tabs.last)
            let activate = ProcessInfo.processInfo.systemUptime
            store.current = tab.id
            let created = ProcessInfo.processInfo.systemUptime
            try await compatibilityWait { !tab.web.isLoading && tab.web.title == "Page /tab-\(count - 1)" }
            let ready = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(store.tabs.dropLast().allSatisfy { $0.existingWeb == nil })
            print("STARTUP_PAGE count=\(count) presentation_ms=\((presented-start)*1000) parked_activation_ms=\((created-activate)*1000) first_page_ready_ms=\((ready-start)*1000) background_metadata_complete_ms=\((presented-start)*1000)")
            tab.suspend()
            XCTAssertNil(tab.existingWeb)
            let wake = ProcessInfo.processInfo.systemUptime
            tab.resume()
            let woke = ProcessInfo.processInfo.systemUptime
            try await compatibilityWait { !tab.web.isLoading && tab.web.url?.path == "/tab-\(count - 1)" }
            print("STARTUP_SLEEP count=\(count) resume_ms=\((woke-wake)*1000) ready_ms=\((ProcessInfo.processInfo.systemUptime-wake)*1000)")
            store.window?.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
            await Task.yield()
        }
    }

    func testWebViewCreation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STARTUP_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = ProfileManager.shared.active.id
        for run in 0..<5 {
            let tab = Tab(profileID: profile)
            let started = ProcessInfo.processInfo.systemUptime
            _ = tab.web
            print("WEBVIEW_CREATION run=\(run) ms=\((ProcessInfo.processInfo.systemUptime-started)*1000)")
            tab.tearDown()
        }
    }

}
