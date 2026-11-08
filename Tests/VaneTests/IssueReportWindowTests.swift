import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class IssueReportWindowTests: XCTestCase {
    private var fixtureProfiles = Set<UUID>()

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        IssueReportWindow.close()
    }

    override func tearDown() async throws {
        IssueReportWindow.close()
        try await NativeFixtureProfileCleanup.release(fixtureProfiles)
        fixtureProfiles.removeAll()
    }

    private func publicTab() -> Tab {
        let profileID = UUID()
        fixtureProfiles.insert(profileID)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return Tab(popup: configuration, isPrivate: false, profileID: profileID)
    }

    func testRepeatedPresentationKeepsDraftButReopeningResetsConsentAndSnapshot() throws {
        IssueReportWindow.show(in: nil)
        let window = try XCTUnwrap(IssueReportWindow.window)
        let session = try XCTUnwrap(IssueReportWindow.session)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(session.draft.includeLogs)
        session.draft.title = "Keep this draft"
        session.draft.details = "Description"
        session.draft.includeLogs = true
        IssueReportWindow.show(in: nil)
        XCTAssertTrue(IssueReportWindow.window === window)
        XCTAssertEqual(IssueReportWindow.session?.draft.title, "Keep this draft")
        XCTAssertTrue(IssueReportWindow.session?.draft.includeLogs == true)
        window.orderOut(nil)
        IssueReportWindow.show(in: nil)
        XCTAssertTrue(IssueReportWindow.window === window, "A hidden draft must be brought back, not replaced")
        XCTAssertTrue(IssueReportWindow.session === session)
        IssueReportWindow.close()
        XCTAssertFalse(window.isVisible)
        IssueReportWindow.show(in: nil)
        let reopened = try XCTUnwrap(IssueReportWindow.session)
        XCTAssertFalse(reopened === session)
        XCTAssertEqual(reopened.draft.title, "")
        XCTAssertFalse(reopened.draft.includeLogs)
        XCTAssertGreaterThanOrEqual(reopened.draft.snapshot.capturedAt, session.draft.snapshot.capturedAt)
    }

    func testCopyAndOpenUseTheReviewedTextAndReportOpenFailure() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = []
        let session = IssueReportSession(snapshot: DiagnosticLog().snapshot(), openURL: { url in
            opened.append(url)
            return false
        })
        session.draft.title = "A failure"
        session.draft.details = "Steps and expected behavior"
        XCTAssertTrue(session.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), session.draft.markdown)
        session.openGitHub(pasteboard: pasteboard)
        XCTAssertEqual(opened, [session.draft.handoff.url])
        XCTAssertTrue(session.isError)
        XCTAssertTrue(session.status.contains("Could not open GitHub"))
    }

    func testOversizeActionCopiesFullReportBeforeOpening() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var bodyAtOpen: String?
        let session = IssueReportSession(snapshot: DiagnosticLog().snapshot(), openURL: { _ in
            bodyAtOpen = pasteboard.string(forType: .string)
            return true
        })
        session.draft.title = "Long report"
        session.draft.details = String(repeating: "A detailed reproduction\n", count: 2_000)
        session.openGitHub(pasteboard: pasteboard)
        XCTAssertEqual(bodyAtOpen, session.draft.markdown)
        XCTAssertFalse(session.isError)
        XCTAssertTrue(session.status.contains("Command-V"))
    }

    func testWebContentTerminationInstrumentationExcludesPrivateTabs() {
        // Exercise the actual delegate entry point for public and private tabs.
        let marker = Date.now
        let publicTab = publicTab()
        let privateTab = Tab(isPrivate: true)
        defer { publicTab.tearDown(); privateTab.tearDown() }
        for tab in [publicTab, privateTab] {
            let web = tab.web
            tab.webViewWebContentProcessDidTerminate(web)
        }
        let events = DiagnosticLog.shared.snapshot().events.filter { $0.timestamp >= marker }
        XCTAssertEqual(events.filter { $0.kind == .webContentTerminated }.count, 1)
    }

    func testRealNavigationFailureRecordsOnlyTypedEventsAndNumericCode() async throws {
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let tab = publicTab()
        let web = tab.web
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.center()
        var loop: NativeFixtureApplicationLoop?
        var server: NavigationHTTPFixture?
        var failure: (any Error)?
        do {
            let admitted = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory,
                beforeHeartbeat: {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }, launchReadiness: {
                    NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window
                        && window.isVisible && window.isKeyWindow && !window.isMiniaturized
                        && web.window === window && web.bounds.width > 0 && web.bounds.height > 0
                })
            loop = admitted
            try await compatibilityWait { try admitted.isReadyForInteraction() }
            XCTAssertTrue(NSApp.isRunning, "Navigation fixture must own an admitted AppKit loop")
            XCTAssertTrue(web.window === window, "Navigation fixture must mount the exact document before loading")

            let listener = try NavigationHTTPFixture()
            server = listener
            try await compatibilityWait { listener.port != nil }
            // Prove this document can navigate before exercising a failure. A
            // reserved fixed port can be rejected before WebKit claims a load.
            let readyURL = try listener.url("/triage-ready")
            tab.navigate(to: readyURL)
            try await compatibilityWait {
                web.url == readyURL && tab.title == "Page /triage-ready" && !web.isLoading && !tab.loading
            }
            let url = try listener.url("/private-path?secret=do-not-capture")
            listener.stop()
            // cancel() is a request; connection refusal requires terminal shutdown.
            try await compatibilityWait { listener.listenerCancelled }
            let marker = Date.now
            tab.navigate(to: url)
            try await compatibilityWait {
                DiagnosticLog.shared.snapshot().events.contains {
                    $0.timestamp >= marker && $0.kind == .provisionalNavigationFailed
                }
            }
            let snapshot = DiagnosticLog.shared.snapshot()
            let event = try XCTUnwrap(snapshot.events.first {
                $0.timestamp >= marker && $0.kind == .provisionalNavigationFailed
            })
            XCTAssertEqual(event.code, URLError.Code.cannotConnectToHost.rawValue)
            var draft = IssueReportDraft(snapshot: snapshot, environment: "fixture")
            draft.includeLogs = true
            XCTAssertFalse(draft.markdown.contains("private-path"))
            XCTAssertFalse(draft.markdown.contains("do-not-capture"))
            XCTAssertFalse(draft.markdown.contains("127.0.0.1"))
        } catch {
            print("ISSUE_REPORT_NAVIGATION_FIXTURE running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(window.isKeyWindow) mounted=\(web.window === window) loading=\(tab.loading) webLoading=\(web.isLoading) listenerCancelled=\(server?.listenerCancelled == true)")
            failure = error
        }
        server?.stop()
        tab.tearDown()
        window.contentView = nil
        window.close()
        if let loop {
            do { try await loop.close() }
            catch {
                if failure == nil { failure = error }
                else { XCTFail("Report fixture AppKit loop cleanup also failed: \(error)") }
            }
        }
        if let failure { throw failure }
    }

    func testReportWindowRendersAtMinimumSizeWithLogs() async throws {
        IssueReportWindow.show(in: nil)
        let window = try XCTUnwrap(IssueReportWindow.window)
        let session = try XCTUnwrap(IssueReportWindow.session)
        session.draft.title = "A page stopped loading"
        session.draft.details = "1. Open a page.\n2. Reload it.\nExpected the page to load; it stayed blank."
        session.draft.includeLogs = true
        window.setContentSize(NSSize(width: 580, height: 560))
        let host = try XCTUnwrap(window.contentView)
        try await compatibilityWait { window.isVisible && host.window === window && host.bounds.width >= 580 }
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 580)
        XCTAssertGreaterThanOrEqual(host.bounds.height, 560)
        if let directory = ProcessInfo.processInfo.environment["VANE_TRIAGE_CAPTURE_DIR"] {
            for (name, appearance, size) in [
                ("light", NSAppearance.Name.aqua, NSSize(width: 680, height: 760)),
                ("dark", .darkAqua, NSSize(width: 580, height: 560))
            ] {
                window.setContentSize(size)
                window.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                await Task.yield()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("report-\(name).png"))
            }
        }
    }
}
