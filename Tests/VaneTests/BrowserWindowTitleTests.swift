import AppKit
import XCTest
@testable import vane

@MainActor final class BrowserWindowTitleTests: XCTestCase {
    private final class WeakTab {
        weak var value: Tab?
        init(_ value: Tab?) { self.value = value }
    }
    private var windows: [NSWindow] = []
    private var profiles: [UUID] = []
    private var server: CompatibilityServer!
    private var oldHTTPS = false
    private var oldPageTitlePreference: Any?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        oldHTTPS = HTTPSOnly.enabled
        HTTPSOnly.enabled = false
        oldPageTitlePreference = UserDefaults.vane.object(forKey: "pageTitlesInWindows")
        UserDefaults.vane.removeObject(forKey: "pageTitlesInWindows")
        server = try CompatibilityServer()
        try await compatibilityWait { self.server.port != nil }
    }

    override func tearDown() async throws {
        for window in windows {
            window.close()
            window.contentView = nil
        }
        windows = []
        try await NativeFixtureProfileCleanup.release(Set(profiles))
        for id in profiles { _ = ProfileManager.shared.delete(id) }
        profiles = []
        server.stop()
        server = nil
        HTTPSOnly.enabled = oldHTTPS
        UserDefaults.vane.set(oldPageTitlePreference, forKey: "pageTitlesInWindows")
    }

    private func profile(_ name: String) -> Profile {
        let made = ProfileManager.shared.create(name: name)
        profiles.append(made.id)
        return made
    }

    private func browser(profile: Profile? = nil, isPrivate: Bool = false) throws -> TabStore {
        let made = Windows.open(isPrivate: isPrivate, profile: profile, focus: false, session: [])
        windows.append(try XCTUnwrap(made.window))
        return made
    }

    private func load(_ path: String, in tab: Tab) async throws {
        let url = try server.url(path)
        tab.navigate(to: url)
        try await compatibilityWait { !tab.web.isLoading && tab.web.url == url && tab.title == "Page \(path)" }
    }

    private func title(_ expected: String, in store: TabStore,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        // Pump SwiftUI updates before asserting the externally visible AppKit title.
        try await Task.sleep(for: .milliseconds(20))
        let deadline = Date.now.addingTimeInterval(2)
        while store.window?.title != expected, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.window?.title, expected, file: file, line: line)
    }

    func testNormalWindowFollowsNavigationAndLiveDocumentTitle() async throws {
        let store = try browser(profile: ProfileManager.shared.profiles.first { $0.isDefault })
        let tab = store.newBlankTab()
        try await load("/login", in: tab)
        try await title("Page /login — Vane", in: store)
        try await load("/account", in: tab)
        try await title("Page /account — Vane", in: store)
        _ = try await tab.web.evaluateJavaScript("document.title = 'Account settings'")
        try await title("Account settings — Vane", in: store)
    }

    func testSelectionSameTitleAndLateInactiveUpdatesFollowOnlyActiveTab() async throws {
        let store = try browser(profile: profile("Work"))
        let first = store.newBlankTab()
        try await load("/first", in: first)
        let second = store.newBlankTab()
        try await load("/second", in: second)
        first.title = "Same title"
        second.title = "Same title"
        try await title("Same title — Vane — Work", in: store)
        store.current = first.id
        try await title("Same title — Vane — Work", in: store)
        second.title = "Late inactive title"
        first.title = "Selected title"
        try await title("Selected title — Vane — Work", in: store)
        store.close(first.id)
        try await title("Late inactive title — Vane — Work", in: store)
        first.title = "Closed tab title"
        try await title("Late inactive title — Vane — Work", in: store)
        store.close(second.id)
        try await title("Vane — Work", in: store)
    }

    func testBlankAndEmptyTitlesUseGenericWindowTitleWithoutExposingURL() async throws {
        let store = try browser(profile: profile("Work"))
        try await title("Vane — Work", in: store)
        let tab = store.newBlankTab()
        tab.title = "New Tab"
        try await title("Vane — Work", in: store)
        try await load("/secret?token=hidden", in: tab)
        tab.title = "  \n  "
        try await title("Vane — Work", in: store)
    }

    func testProfileRenameAndHopRetargetTheWindowTitle() async throws {
        let firstProfile = profile("Work"), secondProfile = profile("Personal")
        let store = try browser(profile: firstProfile)
        let first = store.newBlankTab()
        try await load("/work", in: first)
        try await title("Page /work — Vane — Work", in: store)
        ProfileManager.shared.rename(firstProfile.id, to: "Renamed")
        try await title("Page /work — Vane — Renamed", in: store)
        let space = try XCTUnwrap(ProfileManager.shared.ensureSpaces(for: secondProfile).first)
        let arriving = try XCTUnwrap(Windows.hop(store, to: space))
        let second = arriving.newBlankTab()
        try await load("/personal", in: second)
        try await title("Page /personal — Vane — Personal", in: arriving)
        first.title = "Late parked profile title"
        try await title("Page /personal — Vane — Personal", in: arriving)
        let originalSpace = try XCTUnwrap(store.currentSpace)
        let returned = try XCTUnwrap(Windows.hop(arriving, to: originalSpace))
        try await title("Late parked profile title — Vane — Renamed", in: returned)
    }

    func testLittleWindowKeepsPageTitleAndPrivateLittleWindowStaysGeneric() async throws {
        let regular = LittleArc.open(nil, profileID: profile("Little").id)
        windows.append(try XCTUnwrap(regular.window))
        let tab = regular.newBlankTab()
        regular.palette = nil
        try await load("/little", in: tab)
        try await title("Page /little", in: regular)
        let secret = LittleArc.open(nil, isPrivate: true)
        windows.append(try XCTUnwrap(secret.window))
        let privateTab = secret.newBlankTab()
        secret.palette = nil
        try await load("/little-private", in: privateTab)
        try await title("Little Vane — Incognito", in: secret)
        privateTab.title = "Private little account"
        try await title("Little Vane — Incognito", in: secret)
    }

    func testOptOutImmediatelyRemovesPageTitlesAndStaysOffAcrossTabChanges() async throws {
        let store = try browser(profile: profile("Work"))
        let first = store.newBlankTab()
        try await load("/login", in: first)
        try await title("Page /login — Vane — Work", in: store)
        UserDefaults.vane.set(false, forKey: "pageTitlesInWindows")
        try await title("Vane — Work", in: store)
        let second = store.newBlankTab()
        try await load("/account", in: second)
        try await title("Vane — Work", in: store)
        UserDefaults.vane.set(true, forKey: "pageTitlesInWindows")
        try await title("Page /account — Vane — Work", in: store)
    }

    func testTitleSynchronizationReleasesClosedTab() async throws {
        let app = NSApplication.shared, policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkTitleSynchronizationReleasesClosedTab(loop: loop) }
        catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Title fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkTitleSynchronizationReleasesClosedTab(loop: NativeFixtureApplicationLoop) async throws {
        let store = try browser(profile: profile("Work"))
        let window = try XCTUnwrap(store.window)
        defer {
            window.close()
            window.contentView = nil
            store.window = nil
        }
        window.makeKeyAndOrderFront(nil)
        // Explicit activation matches the native fixtures; cooperative activate()
        // may be declined for the command-line XCTest host.
        NSApp.activate(ignoringOtherApps: true)
        // An occluded, inactive host without an AppKit loop cannot establish
        // whether an outgoing SwiftUI observation has finished its display work.
        do {
            try await compatibilityWait {
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return try loop.isReadyForInteraction() && NSApp.isActive && NSApp.keyWindow === window
                    && window.isVisible && window.occlusionState.contains(.visible)
                    && window.contentView?.window === window && NSApp.modalWindow == nil
                    && window.attachedSheet == nil
            }
        } catch {
            print("TITLE_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(NSApp.keyWindow === window) visible=\(window.isVisible) unoccluded=\(window.occlusionState.contains(.visible)) owner=\(window.contentView?.window === window) modal=\(NSApp.modalWindow != nil) sheet=\(window.attachedSheet != nil) loop=\(String(describing: try? loop.isReadyForInteraction())) front=\(String(describing: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))")
            throw error
        }
        // The async helper releases its strong Tab reference before the lifetime check.
        let retired = try await closeTitleFixture(in: store)
        try await title("Vane — Work", in: store)
        let deadline = Date.now.addingTimeInterval(2)
        while retired.value != nil, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(retired.value, "Window title observation must not retain the closed page")
    }

    private func closeTitleFixture(in store: TabStore) async throws -> WeakTab {
        let tab = store.newBlankTab()
        try await load("/released", in: tab)
        try await title("Page /released — Vane — Work", in: store)
        let retired = WeakTab(tab)
        store.close(tab.id)
        return retired
    }

    func testPrivateWindowNeverPublishesPageTitleOrURL() async throws {
        let store = try browser(isPrivate: true)
        let tab = store.newBlankTab()
        try await load("/private", in: tab)
        try await title("Vane — Incognito", in: store)
        _ = try await tab.web.evaluateJavaScript("document.title = 'Private account'")
        try await compatibilityWait { tab.title == "Private account" }
        try await title("Vane — Incognito", in: store)
        store.close(tab.id)
        try await title("Vane — Incognito", in: store)
    }
}
